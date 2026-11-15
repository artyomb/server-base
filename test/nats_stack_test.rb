require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require 'json'
require_relative '../lib/deploy'

class NatsStackTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SOURCE = File.join(ROOT, 'actions/stacks/nats/nats.drs')
  TOKEN = 'test_' + 'a' * 32

  def render(overrides = {})
    env = ENV.keys.grep(/\A(?:NATS_|TLS_|CI_)/).to_h { |key| [key, nil] }
    env.merge!('BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile'), 'NATS_TOKEN' => TOKEN,
               'TLS_DOMAIN' => 'example.test')
    Dir.mktmpdir('nats-stack-test-') do |dir|
      out, err, status = Open3.capture3(env.merge(overrides), 'bundle', 'exec', 'dry-stack', 'to_compose',
                                       stdin_data: File.read(SOURCE), chdir: dir)
      return [nil, {}, out + err] unless status.success?

      _checked, error, valid = Open3.capture3('docker', 'stack', 'config', '--compose-file', '-', stdin_data: out, chdir: dir)
      assert valid.success?, error
      compose = YAML.safe_load(out)
      configs = compose.fetch('services').values.flat_map { |service| service.fetch('configs', []) }.to_h do |mount|
        path = compose.fetch('configs').fetch(mount.fetch('source')).fetch('file')
        [mount.fetch('target'), File.read(File.expand_path(path, dir))]
      end
      [compose, configs, err]
    end
  end

  def labels(service)
    service.fetch('deploy').fetch('labels').to_h { |label| label.split('=', 2) }
  end

  def test_only_selected_services_run_with_persistent_data_and_bounded_resources
    compose, configs, err = render
    refute_nil compose, err
    services = compose.fetch('services')
    assert_equal %w[nats_nui nats_single prometheus_nats_exporter], services.keys.sort
    services.each_value do |service|
      assert_empty service.fetch('ports', [])
      assert service.fetch('networks').key?('default')
      limits = service.fetch('deploy').fetch('resources').fetch('limits')
      assert_operator limits.fetch('cpus').to_f, :>, 0
      refute_empty limits.fetch('memory')
      assert_equal({ 'max-size' => '10m', 'max-file' => '3' }, service.fetch('logging').fetch('options'))
    end
    server = services.fetch('nats_single')
    data = server.fetch('volumes').find { |mount| mount['target'] == '/data' }
    assert_equal 'nats_data', compose.fetch('volumes').fetch(data.fetch('source')).fetch('name')
    assert_equal TOKEN, server.fetch('environment').fetch('NATS_TOKEN')
    refute_includes server.fetch('command').to_s, TOKEN
    refute_includes configs.fetch('/etc/nats/nats.conf'), TOKEN
    assert_includes configs.fetch('/etc/nats/nats.conf'), 'authorization { token: $NATS_TOKEN }'
    assert_includes configs.fetch('/etc/nats/nats.conf'), 'max_memory_store: 134217728'
    assert_includes configs.fetch('/etc/nats/nats.conf'), 'max_file_store: 2147483648'
    assert_equal 'false', labels(server)['traefik.enable']
    assert server.fetch('networks').key?('nats_network')
    refute server.fetch('networks').key?('ingress_routing')
    exporter = services.fetch('prometheus_nats_exporter')
    assert exporter.fetch('networks').key?('grafana_network')
    assert_includes exporter.fetch('command'), '-jsz=consumers'
    refute labels(exporter).key?('metrics_port'), 'Existing static scrape must not be duplicated'
    nui = services.fetch('nats_nui')
    data = nui.fetch('volumes').find { |mount| mount['target'] == '/db' }
    assert_equal 'nats_nui_db', compose.fetch('volumes').fetch(data.fetch('source')).fetch('name')
    context = nui.fetch('configs').find { |mount| mount['target'] == '/nats-cli-contexts/server.json' }
    assert_equal({ 'url' => 'nats://nats_single:4222', 'token' => TOKEN }, JSON.parse(configs.fetch(context['target'])))
  end

  def test_mount_uses_one_oauth_protected_router_for_http_and_https
    [nil, 'example.test'].each do |domain|
      compose, _configs, err = render('TLS_DOMAIN' => domain)
      refute_nil compose, err
      values = labels(compose.fetch('services').fetch('nats_nui'))
      prefix = 'traefik.http.routers.nats_nats_nui-0'
      oauth = 'nats_nats_nui-0_oauth_provider'
      rules = values.select { |key, _value| key.start_with?('traefik.http.routers.') && key.end_with?('.rule') }
      assert_equal({ "#{prefix}.rule" => '(Path(`/map/nats`) || PathPrefix(`/map/nats/`))' }, rules)
      assert_equal '100', values["#{prefix}.priority"]
      assert_equal 'nats_nats_nui-0', values["#{prefix}.service"]
      assert_equal "#{oauth},nats_nats_nui-0-mount-redirect,nats_nats_nui-0-mount-strip", values["#{prefix}.middlewares"]
      assert_equal 'http://oauth2_oauth2_slim:7000/auth', values["traefik.http.middlewares.#{oauth}.forwardauth.address"]
      assert_equal '/map/nats', values['traefik.http.middlewares.nats_nats_nui-0-mount-strip.stripprefix.prefixes']
      assert_equal !!domain, values.key?("#{prefix}.tls")
    end
  end

  def test_rejects_missing_credentials_and_invalid_resource_budgets
    [ { 'NATS_TOKEN' => nil }, { 'NATS_TOKEN' => 'short' }, { 'NATS_TOKEN' => 'x' * 32 + "\n" },
      { 'NATS_MEMORY_MIB' => '0' }, { 'NATS_JS_MEMORY_MIB' => '257' },
      { 'NATS_JS_FILE_MIB' => '0' }, { 'NATS_CPU_LIMIT' => '-1' } ].each do |env|
      compose, _configs, err = render(env)
      assert_nil compose, "Expected rejection for #{env.keys.join(', ')}"
      refute_empty err
    end
  end

  def test_resource_overrides_leave_headroom_for_the_server
    compose, configs, err = render('NATS_MEMORY_MIB' => '1024', 'NATS_JS_MEMORY_MIB' => '256',
                                    'NATS_JS_FILE_MIB' => '4096', 'NATS_CPU_LIMIT' => '2')
    refute_nil compose, err
    server = compose.fetch('services').fetch('nats_single')
    assert_equal '1024M', server.dig('deploy', 'resources', 'limits', 'memory')
    assert_equal '2.0', server.dig('deploy', 'resources', 'limits', 'cpus')
    assert_equal '819MiB', server.dig('environment', 'GOMEMLIMIT')
    assert_includes configs.fetch('/etc/nats/nats.conf'), 'max_memory_store: 268435456'
    assert_includes configs.fetch('/etc/nats/nats.conf'), 'max_file_store: 4294967296'
  end

  def test_action_deploys_with_private_generated_files_and_restores_umask_on_failure
    registry = Deploy::Actions::Registry.new
    Deploy::Actions::Loader.new(File.join(ROOT, 'actions'), registry).load_all
    action = registry.fetch(:nats)
    assert_includes action.depends, :swarm
    original_umask = File.umask
    [false, true].each do |fail|
      calls = []
      context = Object.new
      context.define_singleton_method(:deploy_drs) do |path|
        calls << [path, File.umask]
        raise 'Deployment failed' if fail
      end
      capture_io do
        if fail
          assert_raises(RuntimeError) { action.run(context) }
        else
          action.run(context)
        end
      end
      assert_equal [['nats.drs', 0o077]], calls
      assert_equal original_umask, File.umask
    end
  end
end
