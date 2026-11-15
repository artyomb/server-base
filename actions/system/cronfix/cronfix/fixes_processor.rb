require 'json'
require 'time'
require 'fileutils'
require 'tempfile'
require_relative 'config'
require_relative 'safe_exec'
require_relative 'notify'
require_relative 'tasks/inode_usage'
require_relative 'tasks/oom_checker'
require_relative 'tasks/swarm_service_replicas'

module Cronfix
  class Runner
    attr_reader :config, :deadline

    def initialize(config)
      @config = config
      @deadline = SafeExec.monotonic + config['run_timeout']
    end

    def remaining = deadline - SafeExec.monotonic

    def capture(*argv)
      available = remaining - [20, config['run_timeout'] / 4.0].min
      raise 'Diagnostic deadline exceeded' unless available.positive?

      SafeExec.capture(*argv, timeout: [config['command_timeout'], available].min, max_output: config['max_output_bytes'])
    end

    def command(*argv)
      result = capture(*argv)
      raise "#{argv.first}: #{result.exception ? result.exception.class : "exit #{result.exitstatus}"}" unless result.success?

      result.stdout.force_encoding('UTF-8')
    end
  end

  def self.atomic_json(path, value)
    Tempfile.create(['.cronfix-', '.tmp'], File.dirname(path)) do |file|
      file.chmod(0o600)
      file.write(JSON.pretty_generate(value) + "\n")
      file.flush
      file.fsync
      File.rename(file.path, path)
    end
    File.open(File.dirname(path)) { |dir| dir.fsync }
  end

  class Processor
    IMPLEMENTATIONS = { 'inode_usage' => InodeUsage, 'oom_checker' => OomChecker,
                        'swarm_service_replicas' => SwarmServiceReplicas }.freeze

    def initialize(config, root:, notifier: Notifier.new(config), runner: Runner.new(config), clock: -> { Time.now.to_i })
      @config, @root, @notifier, @runner, @clock = config, root, notifier, runner, clock
      @path = File.join(root, 'state.json')
    end

    def run(locked: false)
      FileUtils.mkdir_p(@root, mode: 0o700)
      raise 'State directory must not be a symlink' if File.symlink?(@root)

      File.open(File.join(@root, 'run.lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        return 0 unless locked || lock.flock(File::LOCK_EX | File::LOCK_NB)

        @state = read_state
        @config['tasks'].each do |name|
          implementation = IMPLEMENTATIONS.fetch(name)
          if !@state['checkpoints'].key?(name) && implementation.respond_to?(:initial_checkpoint)
            @state['checkpoints'][name] = implementation.initial_checkpoint(@config, @clock.call)
            persist
          end
          previous = @state['checkpoints'].fetch(name, {})
          working = JSON.parse(JSON.generate(previous))
          begin
            result = implementation.check(@runner, working, @clock.call)
            validate_result(result)
            @state['checkpoints'][name] = result.fetch(:checkpoint)
          rescue StandardError => e
            detail = e.is_a?(JSON::ParserError) ? 'Malformed command response' : e.message
            result = { observations: [{ key: 'check', status: 'unknown', message: "#{name}: #{e.class}: #{detail}" }], complete: false }
          end
          observations = result[:observations]
          unless observations.any? { |o| o[:key] == 'check' }
            status = result[:complete] ? 'healthy' : 'not_applicable'
            observations = observations + [{ key: 'check', status: status, message: "#{name}: #{status}" }]
          end
          keys = observations.map { |o| "#{name}/#{o[:key]}" }
          observations.each do |observation|
            transition("#{name}/#{observation[:key]}", observation)
            puts "#{name}: #{observation[:status]}"
          end
          if result[:complete]
            @state['observations'].keys.grep(/^#{Regexp.escape(name)}\//).each do |key|
              next if keys.include?(key)

              transition(key, { status: 'healthy', message: "#{key}: resource no longer present" })
              @state['observations'].delete(key)
            end
          end
          Array(result[:events]).each { |event| enqueue(event[:id], event[:message]) }
          # Checkpoints and pending events become durable together, before delivery.
          persist
        end
        delivered = flush
        unresolved = @state['observations'].any? do |key, value|
          @config['tasks'].include?(key.split('/').first) && %w[unknown problem].include?(value['status'])
        end
        unresolved || !delivered ? 1 : 0
      end
    end

    private

    def read_state
      raise 'State file must not be a symlink' if File.symlink?(@path)
      return { 'version' => 1, 'checkpoints' => {}, 'observations' => {}, 'outbox' => [], 'sequence' => 0 } unless File.exist?(@path)

      state = JSON.parse(File.read(@path))
      unless state.is_a?(Hash) && state['version'] == 1 && state['checkpoints'].is_a?(Hash) && state['observations'].is_a?(Hash) &&
             state['outbox'].is_a?(Array) && state['sequence'].is_a?(Integer) && state['outbox'].all? { |e| e.is_a?(Hash) && e['id'].is_a?(String) && e['message'].is_a?(String) }
        raise 'Invalid state; refusing to reset notification history'
      end
      state
    end

    def validate_result(result)
      unless result.is_a?(Hash) && result[:observations].is_a?(Array) && result[:checkpoint].is_a?(Hash) && [true, false].include?(result[:complete])
        raise 'Invalid diagnostic result'
      end

      result[:observations].each do |o|
        unless o.is_a?(Hash) && o[:key].is_a?(String) && o[:message].is_a?(String) && %w[healthy problem unknown pending not_applicable].include?(o[:status])
          raise 'Invalid observation'
        end
      end
      Array(result[:events]).each do |event|
        raise 'Invalid event' unless event.is_a?(Hash) && event[:id].is_a?(String) && event[:message].is_a?(String)
      end
    end

    def transition(key, observation)
      old = @state['observations'][key]
      status = observation[:status]
      return if %w[pending not_applicable].include?(status) && old && %w[problem unknown].include?(old['status'])

      if %w[problem unknown].include?(status) && old&.fetch('status') != status
        @state['sequence'] += 1
        enqueue("transition:#{@state['sequence']}", "#{status.upcase}: #{observation[:message]}")
      elsif status == 'healthy' && old && %w[problem unknown].include?(old['status'])
        @state['sequence'] += 1
        enqueue("transition:#{@state['sequence']}", "RECOVERED: #{observation[:message]}")
      end
      @state['observations'][key] = { 'status' => status }
    end

    def enqueue(id, message)
      return if @state['outbox'].any? { |entry| entry['id'] == id }

      @state['outbox'] << { 'id' => id, 'message' => message }
    end

    def persist = Cronfix.atomic_json(@path, @state)

    def flush
      until @state['outbox'].empty?
        break unless @runner.remaining > 0.3
        break unless @notifier.deliver(@state['outbox'].first['message'], timeout: [20, @runner.remaining - 0.2].min)

        @state['outbox'].shift
        persist
      end
      warn 'Notification delivery pending' unless @state['outbox'].empty?
      @state['outbox'].empty?
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise 'Ruby 3.1 or newer is required' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.1')

    root = File.expand_path(__dir__)
    config = Cronfix::Config.read(File.join(root, 'config.json'))
    raise 'Unexpected processor arguments' unless ARGV.empty? || ARGV == ['--locked']

    exit Cronfix::Processor.new(config, root: File.join(root, 'state')).run(locked: ARGV == ['--locked'])
  rescue StandardError => e
    warn "cronfix failed: #{e.class}: #{e.message}"
    exit 2
  end
end
