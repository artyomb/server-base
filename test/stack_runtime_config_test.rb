require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require 'json'
require_relative '../lib/deploy'

class StackRuntimeConfigTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  NODE = 'test-swarm-node'

  def render(stack, files)
    source_dir = File.join(ROOT, 'actions/stacks', stack)
    env = ENV.keys.grep(/\A(?:TLS_|GRAFANA_|TRAEFIK_|TELEGRAM_|NATS|GITLAB_)/).to_h { |key| [key, nil] }
    env.merge!('BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile'), 'TRAEFIK_BASIC_AUTH' => 'test:dummy:salt',
               'GITLAB_RUNNER_NODE_ID' => NODE)
    Dir.mktmpdir('stack-runtime-test-') do |dir|
      Dir.children(source_dir).reject { |name| name.include?('.config.') || name == '.knowledge' }.each do |name|
        File.symlink(File.join(source_dir, name), File.join(dir, name))
      end
      out, err, status = Open3.capture3(env, 'bundle', 'exec', 'dry-stack', 'to_compose',
                                       stdin_data: files.map { |file| File.read(File.join(source_dir, file)) }.join("\n"), chdir: dir)
      assert status.success?, err
      checked, error, valid = Open3.capture3('docker', 'stack', 'config', '-c', '-', stdin_data: out, chdir: dir)
      assert valid.success?, error
      compose = YAML.safe_load(checked)
      configs = compose.fetch('configs', {}).transform_values { |config| File.read(config.fetch('file')) }
      [compose, configs]
    end
  end

  def test_application_and_monitoring_logs_use_the_driver_batch_default
    { 'grafana' => %w[grafana.drs], 'insight' => %w[otlp.drs insight.drs],
      'registry_listener' => %w[otlp.drs registry-listener.drs] }.each do |stack, files|
      compose, = render(stack, files)
      if stack == 'grafana'
        assert_includes compose.fetch('services').fetch('vmagent').fetch('command'),
                        '-remoteWrite.maxDiskUsagePerURL=536871040'
      end
      loggers = compose.fetch('services').values.filter_map { |service| service['logging'] }.select { |logger| logger['driver'] == 'loki' }
      refute_empty loggers, stack
      loggers.each do |logger|
        refute logger.fetch('options').key?('loki-batch-size'), stack
        assert_equal 'http://localhost:3100/loki/api/v1/push', logger.dig('options', 'loki-url')
      end
    end
  end

  def test_job_ssh_socket_uses_the_agent_volume_on_the_same_node
    compose, configs = render('runner', %w[runner.drs])
    agent = compose.fetch('services').fetch('ssh_agent')
    runner = compose.fetch('services').fetch('runner')
    agent_mount = agent.fetch('volumes').find { |mount| mount['target'] == '/.ssh-agent' }
    volume_name = compose.fetch('volumes').fetch(agent_mount.fetch('source')).fetch('name')
    toml = configs.fetch(runner.fetch('configs').first.fetch('source'))
    job_mounts = JSON.parse(toml.match(/^\s*volumes = (\[.*\])$/)[1])
    assert_includes job_mounts, "#{volume_name}:/run/ssh-agent:ro"
    assert_includes toml, 'CI_SSH_AUTH_SOCK=/run/ssh-agent/proxy-socket'
    [agent, runner].each { |service| assert_equal ["node.id == #{NODE}"], service.dig('deploy', 'placement', 'constraints') }
  end

  def test_actions_select_the_target_node_and_reject_inactive_swarm
    registry = Deploy::Actions::Registry.new
    Deploy::Actions::Loader.new(File.join(ROOT, 'actions'), registry).load_all
    { runner: 'GITLAB_RUNNER_NODE_ID' }.each do |name, key|
      [NODE, ''].each do |node|
        calls = []
        context = Object.new
        context.define_singleton_method(:capture) { |_command| node }
        context.define_singleton_method(:config) { Struct.new(:main_domain, :tls_domain).new('example.test', nil) }
        context.define_singleton_method(:deploy_drs) { |path, env| calls << [path, env] }
        capture_io do
          if node.empty?
            assert_raises(RuntimeError) { registry.fetch(name).run(context) }
          else
            registry.fetch(name).run(context)
            assert_equal node, calls.first.last.fetch(key)
          end
        end
      end
    end
  end
end
