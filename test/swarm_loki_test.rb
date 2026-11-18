require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../lib/deploy'

class SwarmLokiTest < Minitest::Test
  class Context
    def initialize(env) = @env = env

    def capture(command)
      out, err, status = Open3.capture3(@env, 'bash', '-c', command)
      raise "Fixture command failed: #{err}" unless status.success?

      out
    end

    def remote(script) = capture(script)
  end

  def setup
    @root = Dir.mktmpdir('swarm-loki-test-')
    @state_path = File.join(@root, 'state.json')
    docker = File.join(@root, 'docker')
    File.write(docker, <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      path = ENV.fetch('SWARM_TEST_STATE')
      state = JSON.parse(File.read(path))
      state['calls'] << ARGV
      output = ''
      code = 0
      case ARGV.take(2)
      when ['info', '--format']
        output = case ARGV.last
                 when /ControlAvailable/ then state.fetch('manager', 'true')
                 when /Swarm.Error/ then state.fetch('swarm_error', '')
                 else state.fetch('swarm', 'active')
                 end
      when ['swarm', 'init']
        state['swarm'] = 'active'
      when ['plugin', 'ls']
        code = 1 if state['plugin_error']
        output = state['plugins'].map { |name, enabled| "\#{name} \#{enabled}" }.join("\n")
      when ['plugin', 'install']
        abort 'Unexpected plugin alias' unless ARGV[ARGV.index('--alias') + 1] == 'loki'
        state['plugins'] << ['loki:latest', 'true']
      when ['network', 'ls']
        output = state['networks'].join("\n")
      when ['network', 'create']
        state['networks'] << ARGV.last
      else
        abort "Unexpected Docker command: \#{ARGV.inspect}"
      end
      File.write(path, JSON.generate(state))
      puts output
      exit code
    RUBY
    File.chmod(0o700, docker)
    @context = Context.new('PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'SWARM_TEST_STATE' => @state_path,
                           'BASH_ENV' => nil, 'ENV' => nil)
    registry = Deploy::Actions::Registry.new
    Deploy::Actions::Loader.new(File.expand_path('../actions/system/swarm', __dir__), registry).load_all
    @action = registry.fetch(:swarm)
  end

  def teardown = FileUtils.remove_entry(@root)

  def prepare(plugins, missing_network: false, plugin_error: false, **extra)
    networks = %w[ingress-routing grafana-network nats-network]
    networks.pop if missing_network
    File.write(@state_path, JSON.generate('plugins' => plugins, 'networks' => networks,
                                          'calls' => [], 'plugin_error' => plugin_error, **extra.transform_keys(&:to_s)))
  end

  def run_action(**options)
    capture_io { @action.run(@context, { block_ports: false }.merge(options)) }
  end

  def state = JSON.parse(File.read(@state_path))
  def installs = state['calls'].select { |args| args.take(2) == %w[plugin install] }

  def test_default_alias_satisfies_readiness_without_reinstalling
    %w[loki loki:latest].each do |name|
      prepare([[name, 'true'], ['loki:custom', 'false']])
      run_action
      assert_empty installs
      assert_equal 1, state['calls'].count { |args| args.take(2) == %w[plugin ls] }
    end
  end

  def test_custom_alias_does_not_replace_the_default_driver
    prepare([['loki:custom', 'true']])
    run_action
    assert_equal 1, installs.size
    assert_includes state['plugins'], ['loki:custom', 'true']
    assert_includes state['plugins'], ['loki:latest', 'true']
    run_action
    assert_equal 1, installs.size
  end

  def test_disabled_default_is_not_hidden_by_enabled_custom_alias
    prepare([['loki:latest', 'false'], ['loki:custom', 'true']])
    error = assert_raises(RuntimeError) { run_action }
    assert_match(/disabled/, error.message)
    assert_empty installs
    assert_includes state['plugins'], ['loki:latest', 'false']
  end

  def test_multiple_aliases_do_not_block_network_repair
    prepare([['loki:latest', 'true'], ['loki:custom', 'true']], missing_network: true)
    run_action
    assert_empty installs
    assert_includes state['networks'], 'nats-network'
    assert_equal 1, state['calls'].count { |args| args.take(2) == %w[network create] }
  end

  def test_inactive_worker_stops_before_changing_membership
    ['192.0.2.1', nil, ''].each do |manager|
      prepare([], swarm: 'inactive')
      error = assert_raises(RuntimeError) { run_action(manager_ip: manager) }
      assert_includes error.message, 'Join the existing Swarm'
      assert state['calls'].all? { |args| args.take(2) == %w[info --format] }
    end
  end

  def test_inactive_standalone_node_still_initializes_once
    prepare([['loki:latest', 'true']], swarm: 'inactive')
    2.times { run_action(advertise_addr: '192.0.2.2') }
    assert_equal [%w[swarm init --advertise-addr 192.0.2.2]], state['calls'].select { |args| args.first == 'swarm' }
  end

  def test_active_worker_skips_manager_network_operations
    prepare([['loki:latest', 'true']], manager: 'false')
    run_action(manager_ip: '192.0.2.1')
    assert_empty state['calls'].select { |args| %w[swarm network].include?(args.first) }
  end

  def test_broken_swarm_reports_docker_error_without_changing_membership
    prepare([['loki:latest', 'true']], swarm: 'error', swarm_error: 'node certificate has expired')
    error = assert_raises(RuntimeError) { run_action }
    assert_includes error.message, 'node certificate has expired'
    assert state['calls'].all? { |args| args.take(2) == %w[info --format] }
  end

  def test_plugin_read_failure_aborts_without_installing
    prepare([], plugin_error: true)
    assert_raises(RuntimeError) { run_action }
    assert_empty installs
  end
end
