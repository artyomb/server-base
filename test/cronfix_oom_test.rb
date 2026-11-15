require 'minitest/autorun'
require 'tmpdir'
require 'rbconfig'
require_relative '../actions/system/cronfix/cronfix/fixes_processor'

class CronfixOomTest < Minitest::Test
  NOW = 1_700_000_000
  CaptureFixture = Struct.new(:config, :result) do
    def capture(*) = result
  end

  class JournalRunner < Cronfix::Runner
    attr_reader :calls

    def initialize(config, fixture, journal, mode)
      super(config)
      @fixture, @journal, @mode, @calls = fixture, journal, mode, []
    end

    def capture(*argv)
      raise "Unexpected command: #{argv.inspect}" unless argv.first == 'journalctl'

      @calls << argv
      super(RbConfig.ruby, @fixture, @journal, @mode, *argv.drop(1))
    end
  end

  class Delivery
    attr_accessor :ok
    attr_reader :messages

    def initialize
      @ok, @messages = true, []
    end

    def deliver(message, **)
      @messages << message if @ok
      @ok
    end
  end

  def setup
    @tmp = Dir.mktmpdir('cronfix-oom-')
    @root = File.join(@tmp, 'state')
    @journal = File.join(@tmp, 'journal.jsonl')
    @fixture = File.join(@tmp, 'journal.rb')
    @mode = 'success'
    @delivery = Delivery.new
    @config = Cronfix::Config::DEFAULTS.merge('tasks' => ['oom_checker'], 'oom_include_message' => true)
    File.write(@fixture, <<~'RUBY')
      require 'json'
      path, mode = ARGV.shift(2)
      lines = File.readlines(path)
      if (index = ARGV.index('--cursor'))
        cursor = ARGV[index + 1]
        start = lines.index { |line| JSON.parse(line)['__CURSOR'] == cursor rescue false }
        lines = lines.drop(start || 0)
      elsif (index = ARGV.index('--since'))
        since = Integer(ARGV[index + 1].delete_prefix('@')) * 1_000_000
        lines = lines.drop_while { |line| Integer(JSON.parse(line)['__REALTIME_TIMESTAMP']) < since rescue false }
      end
      STDOUT.write(lines.join)
      STDOUT.flush
      case mode
      when 'timeout' then sleep 30
      when 'failure' then exit 7
      end
    RUBY
  end

  def teardown = FileUtils.remove_entry(@tmp)

  def row(index, message = "ordinary record #{index}")
    { '__CURSOR' => "cursor-#{index}", '__REALTIME_TIMESTAMP' => ((NOW - 100) * 1_000_000 + index).to_s, 'MESSAGE' => message }
  end

  def write_rows(rows)
    File.write(@journal, rows.map { |entry| JSON.generate(entry) + "\n" }.join)
  end

  def seed(cursor = 'cursor-0', observations: {})
    FileUtils.mkdir_p(@root)
    Cronfix.atomic_json(File.join(@root, 'state.json'), {
      'version' => 1, 'checkpoints' => { 'oom_checker' => { 'since' => NOW - 600, 'cursor' => cursor } },
      'observations' => observations, 'outbox' => [], 'sequence' => 0
    })
  end

  def state = JSON.parse(File.read(File.join(@root, 'state.json')))
  def checkpoint = state['checkpoints']['oom_checker']
  def oom_messages = @delivery.messages.grep(/^Kernel OOM record/)

  def process(now = NOW)
    @runner = JournalRunner.new(@config, @fixture, @journal, @mode)
    status = nil
    capture_io do
      status = Cronfix::Processor.new(@config, root: @root, notifier: @delivery, runner: @runner, clock: -> { now }).run
    end
    status
  end

  def drain(max_passes = 30)
    max_passes.times do
      process
      return if state.dig('observations', 'oom_checker/check', 'status') == 'healthy'
    end
    flunk 'Journal did not drain within the pass limit'
  end

  def test_backlog_larger_than_four_mib_advances_and_delivers_boundary_events_once
    rows = Array.new(6000) { |index| row(index, 'x' * 1024) }
    bytes = 0
    boundary = rows.index { |entry| (bytes += JSON.generate(entry).bytesize + 1) > @config['max_output_bytes'] }
    events = [0, boundary - 1, boundary, rows.size - 1]
    events.each { |index| rows[index]['MESSAGE'] = "Killed process #{index} ".ljust(1024, 'x') }
    write_rows(rows)
    assert_operator File.size(@journal), :>, 4 * 1024 * 1024

    assert_equal 0, process
    assert_equal "cursor-#{boundary - 1}", checkpoint['cursor']
    assert_equal 'pending', state.dig('observations', 'oom_checker/check', 'status')
    assert_equal 2, oom_messages.size
    drain
    assert_equal 'cursor-5999', checkpoint['cursor']
    assert_equal events.size, oom_messages.size
    events.each { |index| assert_equal 1, oom_messages.count { |message| message.include?("Killed process #{index} ") } }
    assert_equal ['journalctl', '--no-pager', '--output=json', '--all', '_TRANSPORT=kernel', '--cursor', "cursor-#{boundary - 1}"], @runner.calls.first
    process
    assert_equal events.size, oom_messages.size
  end

  def test_a_split_record_is_retried_from_the_inclusive_cursor
    rows = [row(0), row(1, 'Killed process 1'), row(2, 'Killed process 2 ' + 'Ж' * 80)]
    write_rows(rows)
    prefix = rows.first(2).sum { |entry| JSON.generate(entry).bytesize + 1 }
    @config['max_output_bytes'] = prefix + 81
    assert_equal 0, process
    assert_equal 'cursor-1', checkpoint['cursor']
    assert_equal 1, oom_messages.size
    @config['max_output_bytes'] = 1024
    assert_equal 0, process
    assert_equal 'cursor-2', checkpoint['cursor']
    assert_equal 2, oom_messages.size
    assert_includes oom_messages.last, 'Ж' * 80
  end

  def test_binary_messages_are_decoded_and_do_not_block_following_oom
    write_rows([row(0, [0, 255, *'invoked oom-killer'.bytes, 10]), row(1, []), row(2, 'Killed process 2')])
    assert_equal 0, process
    assert_equal 'cursor-2', checkpoint['cursor']
    assert_equal 2, oom_messages.size
    assert_includes oom_messages.first, "�invoked oom-killer"
    assert oom_messages.all?(&:valid_encoding?)
    refute_match(/[\x00-\x1f]/, oom_messages.first)
  end

  def test_malformed_message_arrays_fail_without_advancing_or_delivering_events
    [[-1], [256], [1.5], ['text'], [nil], [true], {}, nil].each do |message|
      seed
      write_rows([row(0), row(1, message), row(2, 'Killed process 2')])
      assert_equal 1, process
      assert_equal 'cursor-0', checkpoint['cursor']
      assert_equal 'unknown', state.dig('observations', 'oom_checker/check', 'status')
      assert_empty oom_messages
    end
  end

  def test_failed_delivery_keeps_checkpoint_and_outbox_durable_across_pages
    rows = Array.new(12) { |index| row(index, "Killed process #{index} " + 'x' * 130) }
    write_rows(rows)
    @config['max_output_bytes'] = 1024
    @delivery.ok = false
    assert_equal 1, process
    last = Integer(checkpoint['cursor'].delete_prefix('cursor-'))
    assert_operator last, :>=, 1
    assert_equal last + 1, state['outbox'].size
    assert state['outbox'].all? { |event| event['id'].start_with?('oom:') }
    assert_empty oom_messages

    @delivery.ok = true
    drain
    assert_equal 'cursor-11', checkpoint['cursor']
    assert_empty state['outbox']
    assert_equal 12, oom_messages.size
    rows.each_index { |index| assert_equal 1, oom_messages.count { |message| message.include?("Killed process #{index} ") } }
  end

  def test_missing_cursor_never_silently_skips_journal_records
    [[], [row(1, 'Killed process 1')]].each do |rows|
      seed
      write_rows(rows)
      assert_equal 1, process
      assert_equal 'cursor-0', checkpoint['cursor']
      assert_empty oom_messages
      assert_includes @delivery.messages.last, 'continuity cannot be verified'
    end
  end

  def test_timeout_and_failed_exit_discard_even_complete_output
    seed
    write_rows([row(0), row(1, 'Killed process 1')])
    @config['command_timeout'] = 0.2
    %w[timeout failure].each do |mode|
      @mode = mode
      started = SafeExec.monotonic
      assert_equal 1, process
      assert_operator SafeExec.monotonic - started, :<, 2
      assert_equal 'cursor-0', checkpoint['cursor']
      assert_empty oom_messages
    end
    @mode = 'success'
    assert_equal 0, process
    assert_equal 'cursor-1', checkpoint['cursor']
    assert_equal 1, oom_messages.size
  end

  def test_capped_output_without_forward_progress_fails_explicitly
    @config['max_output_bytes'] = 1024
    [[row(0, 'x' * 2048), row(1)], [row(0), row(1, 'x' * 2048)]].each do |rows|
      seed
      write_rows(rows)
      assert_equal 1, process
      assert_equal 'cursor-0', checkpoint['cursor']
      assert_includes @delivery.messages.last, 'Journal record exceeds the command output limit'
    end
  end

  def test_duplicate_anchor_and_malformed_json_fail_before_checkpoint_update
    seed
    [[row(0), row(0, 'Killed process 0')], [row(0), row(1, 'Killed process 1')]].each_with_index do |rows, index|
      write_rows(rows)
      File.open(@journal, 'a') { |file| file.puts('{broken') } if index == 1
      assert_equal 1, process
      assert_equal 'cursor-0', checkpoint['cursor']
      assert_empty oom_messages
    end
  end

  def test_initial_boundary_does_not_slide_after_failure_or_an_empty_scan
    write_rows([])
    @mode = 'failure'
    assert_equal 1, process
    assert_equal({ 'since' => NOW - 600 }, checkpoint)
    @mode = 'success'
    assert_equal 0, process(NOW + 900)
    assert_equal({ 'since' => NOW - 600 }, checkpoint)
    write_rows([row(1, 'Killed process 1')])
    assert_equal 0, process(NOW + 1800)
    assert_equal 1, oom_messages.size
    assert_equal "@#{NOW - 600}", @runner.calls.first.last
  end

  def test_pending_backlog_does_not_recover_an_unknown_check
    seed(observations: { 'oom_checker/check' => { 'status' => 'unknown' } })
    write_rows(Array.new(20) { |index| row(index, 'x' * 100) })
    @config['max_output_bytes'] = 1024
    assert_equal 1, process
    assert_equal 'unknown', state.dig('observations', 'oom_checker/check', 'status')
    assert_empty @delivery.messages
    drain
    assert_equal ['RECOVERED: oom_checker: healthy'], @delivery.messages
  end

  def test_capture_keeps_exact_prefix_under_a_combined_stdout_stderr_cap
    result = SafeExec.capture(RbConfig.ruby, '-e', 'STDOUT.write("a" * 2000); STDERR.write("b" * 2000)', max_output: 1024)
    assert_instance_of SafeExec::OutputLimitError, result.exception
    assert_equal 1024, result.stdout.bytesize + result.stderr.bytesize
    assert_match(/\Aa*\z/, result.stdout)
    assert_match(/\Ab*\z/, result.stderr)
  end

  def test_a_known_nonzero_exit_is_not_accepted_even_when_output_exceeds_the_cap
    result = SafeExec.capture(RbConfig.ruby, '-e', 'exit 7')
    result.stdout = JSON.generate(row(1, 'Killed process 1')) + "\n"
    result.exception = SafeExec::OutputLimitError.new('Command output limit exceeded')
    checkpoint = { 'since' => NOW - 600 }
    assert_raises(RuntimeError) { Cronfix::OomChecker.check(CaptureFixture.new(@config, result), checkpoint, NOW) }
    assert_equal({ 'since' => NOW - 600 }, checkpoint)
  end
end
