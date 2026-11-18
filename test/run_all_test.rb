require 'minitest/autorun'
require 'fileutils'
require 'rbconfig'
require 'tmpdir'
require 'timeout'

class RunAllTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('run-all-test-')
    @config = File.join(@root, 'servers')
    FileUtils.mkdir_p([@config, File.join(@root, 'bin')])
    FileUtils.cp(File.expand_path('../run-all.rb', __dir__), @root)
    servers('alpha')
    deploy('exit 0')
  end

  def teardown
    stop_fixtures
    FileUtils.remove_entry(@root)
  end

  def servers(*names)
    names.each do |name|
      path = File.join(@config, "#{name}.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '# Test configuration; never evaluated.')
    end
  end

  def deploy(source)
    File.write(File.join(@root, 'bin', 'deploy'), <<~'RUBY' + source)
      root = File.expand_path('..', __dir__)
      name = ARGV.fetch(ARGV.index('--server') + 1)
      File.write(File.join(root, "#{name}-parent.pid"), Process.pid.to_s)
    RUBY
  end

  def run_batch(env = {}, *args)
    env = { 'JOBS' => '2', 'JOB_TIMEOUT' => '5', 'SSH_AUTH_SOCK' => nil,
            'CI_SSH_AUTH_SOCK' => nil }.merge(env)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = nil
    File.open(File.join(@root, 'output'), 'w') do |output|
      pid = Process.spawn(env, RbConfig.ruby, File.join(@root, 'run-all.rb'), @config, *args,
                          out: output, err: output, pgroup: true)
      begin
        Timeout.timeout(15) { _, status = Process.wait2(pid) }
      rescue Timeout::Error
        stop_fixtures
        Process.kill('KILL', -pid)
        Process.wait(pid)
        flunk 'Batch did not finish within 15 seconds'
      end
    end
    [File.read(File.join(@root, 'output')), status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def rows
    File.readlines(File.join(@root, 'parallel.log'), chomp: true).drop(1).map { |line| line.split("\t") }
  end

  def fixture_pids
    Dir.glob(File.join(@root, '*.pid')).map { |path| Integer(File.read(path)) }
  end

  def running?(pid)
    Process.kill(0, pid)
    !File.read("/proc/#{pid}/stat").split(') ', 2).last.start_with?('Z ')
  rescue Errno::ESRCH, Errno::ENOENT
    false
  end

  def stop_fixtures
    fixture_pids.each do |pid|
      next unless running?(pid)
      next unless File.read("/proc/#{pid}/cmdline").include?(File.join(@root, 'bin', 'deploy'))

      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::ENOENT
      next
    end
  end

  def test_rejects_invalid_limits_before_running_jobs_or_overwriting_log
    log = File.join(@root, 'parallel.log')
    File.write(log, 'previous results')
    %w[JOBS JOB_TIMEOUT].each do |name|
      ['0', '-1', '', 'bad', '1.5', '0x2'].each do |value|
        output, status = run_batch(name => value)
        refute status.success?, "#{name}=#{value.inspect}"
        assert_includes output, "#{name} must be a positive integer"
        assert_equal 'previous results', File.read(log)
        assert_empty fixture_pids
      end
    end
  end

  def test_success_records_every_job_and_closes_stdin
    servers('beta', 'nested/gamma')
    deploy('abort "Unexpected input" unless STDIN.read.empty?')
    output, status = run_batch('JOBS' => '20')
    assert status.success?, output
    assert_equal %w[alpha beta gamma], rows.map { |row| row[1] }.sort
    assert_equal %w[0 0 0], rows.map { |row| row[3] }
    assert_equal %w[1 2 3], rows.map(&:first).sort
    assert_includes output, 'Completed 3/3 jobs; 0 failed'
  end

  def test_selection_runs_only_the_named_server
    servers('nested/beta')
    output, status = run_batch({}, 'beta.rb')
    assert status.success?, output
    assert_equal ['beta'], rows.map { |row| row[1] }
    assert_includes output, 'Completed 1/1 jobs; 0 failed'
  end

  def test_failed_and_signaled_jobs_are_recorded_and_other_jobs_continue
    servers('beta', 'gamma')
    deploy(<<~'RUBY')
      exit 7 if name == 'alpha'
      Process.kill('TERM', Process.pid) if name == 'beta'
    RUBY
    output, status = run_batch('JOBS' => '1')
    assert_equal 1, status.exitstatus
    assert_equal({ 'alpha' => '7', 'beta' => '143', 'gamma' => '0' }, rows.to_h { |row| [row[1], row[3]] })
    assert_includes output, 'Completed 3/3 jobs; 2 failed'
  end

  def test_spawn_failures_are_recorded_for_every_job
    servers('beta')
    output, status = run_batch('JOBS' => '1', 'PATH' => @root)
    assert_equal 1, status.exitstatus
    assert_equal %w[1 1], rows.map { |row| row[3] }
    assert_includes output, 'Errno::ENOENT'
    assert_includes output, 'Completed 2/2 jobs; 2 failed'
  end

  def check_timeout(mode)
    deploy(<<~'RUBY')
      mode = ENV.fetch('FIXTURE_MODE')
      fork do
        trap('TERM', 'IGNORE')
        STDOUT.close if mode == 'streams_closed'
        STDERR.close if mode == 'streams_closed'
        File.write(File.join(root, "#{name}-child.pid"), Process.pid.to_s)
        sleep 60
      end
      sleep 0.01 until File.exist?(File.join(root, "#{name}-child.pid"))
      exit! 0 if mode == 'leader_exits'
      trap('TERM', 'IGNORE')
      STDOUT.close if mode == 'streams_closed'
      STDERR.close if mode == 'streams_closed'
      sleep 60
    RUBY
    output, status, duration = run_batch('JOB_TIMEOUT' => '1', 'FIXTURE_MODE' => mode)
    assert_equal 1, status.exitstatus
    assert_equal ['124'], rows.map { |row| row[3] }
    assert_includes output, 'local process group stopped'
    assert_includes output, 'Remote work may be partially applied or still running'
    assert_includes output, 'Completed 1/1 jobs; 1 failed'
    assert_operator duration, :<, 8
    assert_equal 2, fixture_pids.size
    fixture_pids.each { |pid| refute running?(pid), "Fixture process #{pid} survived timeout" }
    parent = Integer(File.read(File.join(@root, 'alpha-parent.pid')))
    assert_raises(Errno::ESRCH) { Process.kill(0, parent) }
  end

  def test_timeout_kills_term_resistant_parent_and_descendant
    check_timeout('term_ignored')
  end

  def test_timeout_kills_descendant_after_parent_has_exited
    check_timeout('leader_exits')
  end

  def test_timeout_covers_waiting_for_exit_after_output_is_closed
    check_timeout('streams_closed')
  end

  def test_queue_continues_after_timeout
    servers('beta', 'gamma')
    deploy('sleep 60 if name == "alpha"')
    output, status = run_batch('JOBS' => '1', 'JOB_TIMEOUT' => '1')
    assert_equal 1, status.exitstatus
    assert_equal({ 'alpha' => '124', 'beta' => '0', 'gamma' => '0' }, rows.to_h { |row| [row[1], row[3]] })
    assert_includes output, 'Completed 3/3 jobs; 1 failed'
    fixture_pids.each { |pid| refute running?(pid) }
  end
end
