require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'yaml'

class TraefikDashboardTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  ACTION = File.join(ROOT, 'actions/stacks/traefik')

  def render(overrides = {})
    env = ENV.keys.grep(/\A(?:TRAEFIK_|TLS_|ACME_|CI_)/).to_h { |key| [key, nil] }
    env.merge!('BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile'), 'MAIN_DOMAIN' => 'example.test',
               'SCHEME' => 'http', 'TRAEFIK_BASIC_AUTH' => nil, 'TLS_DOMAIN' => nil)
    env.merge!(overrides)
    Dir.mktmpdir('traefik-dashboard-test-') do |dir|
      FileUtils.cp_r(File.join(ACTION, 'add_header_plugin'), dir)
      out, err, status = Open3.capture3(env, 'bundle', 'exec', 'dry-stack', 'to_compose',
                                       stdin_data: File.read(File.join(ACTION, 'ingress.drs')), chdir: dir)
      assert status.success?, err
      compose = YAML.safe_load(out)
      service = compose.fetch('services').fetch('traefik')
      mounted = service.fetch('configs').find { |config| config['target'] == '/etc/traefik_dynamic/dashboard.yml' }
      refute_nil mounted, 'Dashboard file-provider config must be mounted'
      path = compose.fetch('configs').fetch(mounted.fetch('source')).fetch('file')
      dashboard = YAML.safe_load(File.read(File.expand_path(path, dir)))
      [compose, service, dashboard.fetch('http')]
    end
  end

  def test_dashboard_and_compatibility_routes_require_oauth_without_a_port_backend
    [nil, 'example.test'].each do |domain|
      compose, service, http = render('TLS_DOMAIN' => domain)
      routers = http.fetch('routers')
      assert_equal %w[dashboard-host dashboard-path], routers.keys.sort
      assert_equal 'Path(`/traefik`) || PathPrefix(`/traefik/`)', routers['dashboard-path']['rule']
      assert_equal 'HostRegexp(`{name:traefik\..*}`)', routers['dashboard-host']['rule']
      assert_equal %w[dashboard-oauth dashboard-root], routers['dashboard-path']['middlewares']
      assert_equal %w[dashboard-oauth dashboard-prefix dashboard-root], routers['dashboard-host']['middlewares']
      assert_operator routers['dashboard-path']['priority'], :>, routers['dashboard-host']['priority']
      assert_operator routers['dashboard-path']['priority'], :>, 'HostRegexp(`{name:application\.example\.test}`)'.length
      assert_operator routers['dashboard-path']['priority'], :<, 999
      routers.each_value do |router|
        assert_equal 'api@internal', router['service']
        assert_equal [domain ? 'https' : 'http'], router['entryPoints']
        assert_equal 'dashboard-oauth', router['middlewares'].first
      end

      oauth = http.fetch('middlewares').fetch('dashboard-oauth').fetch('forwardAuth')
      assert_equal 'http://oauth2_oauth2_slim:7000/auth', oauth['address']
      assert_equal '^X-', oauth['authResponseHeadersRegex']
      refute oauth.key?('trustForwardHeader')
      assert_equal({ 'addPrefix' => { 'prefix' => '/traefik' } }, http['middlewares']['dashboard-prefix'])
      refute http.key?('services'), 'Internal service routing needs no network backend'
      refute http.to_yaml.include?('basicAuth')

      assert_includes service.fetch('command'), '--api.basePath=/traefik'
      refute service['command'].any? { |arg| arg.start_with?('--api.insecure', '--entrypoints.traefik.') }
      labels = service.fetch('deploy').fetch('labels').to_h { |label| label.split('=', 2) }
      assert_equal 'false', labels['traefik.enable']
      refute labels.keys.any? { |key| key.start_with?('traefik.http.routers.') }
      assert service.fetch('networks').key?('ingress_routing')
      assert_equal({ 'external' => true, 'name' => 'ingress-routing' }, compose['networks']['ingress_routing'])
      assert service['networks'].key?('grafana_network')
    end
  end

  def test_tls_domains_are_preserved_and_plain_http_has_no_tls_routes
    _compose, _service, http = render('TLS_DOMAIN' => 'example.test')
    expected = { 'dashboard-path' => 'example.test', 'dashboard-host' => 'traefik.example.test' }
    expected.each do |name, domain|
      assert_equal({ 'certResolver' => 'le', 'domains' => [{ 'main' => domain }] }, http['routers'][name]['tls'])
    end
    _compose, _service, plain = render
    assert plain['routers'].values.none? { |router| router.key?('tls') }
  end

  def test_canonical_root_redirect_covers_both_slash_forms_without_matching_api_or_assets
    _compose, _service, http = render
    redirect = http.fetch('middlewares').fetch('dashboard-root').fetch('redirectRegex')
    assert_equal '${1}/dashboard/${2}', redirect['replacement']
    regex = Regexp.new(redirect.fetch('regex'))
    %w[http https].product(['', '/'], ['', '?test=value']).each do |scheme, slash, query|
      match = regex.match("#{scheme}://example.test:18443/traefik#{slash}#{query}")
      refute_nil match
      assert_equal "#{scheme}://example.test:18443/traefik", match[1]
      assert_equal query, match[2].to_s
    end
    %w[/traefikevil /traefik/dashboard/ /traefik/api/overview /traefik/dashboard/assets/index.js].each do |path|
      refute_match regex, "https://example.test#{path}"
    end
  end

  def test_existing_ports_metrics_and_certificate_storage_are_preserved
    [nil, 'example.test'].product([nil, '5432', '15432']).each do |domain, postgres|
      _compose, service, _http = render('TLS_DOMAIN' => domain, 'TRAEFIK_POSTGRES_PORT' => postgres,
                                        'TRAEFIK_HTTP_PORT' => '18080', 'TRAEFIK_HTTPS_PORT' => '18443',
                                        'TRAEFIK_OTLP_ENABLED' => 'true')
      ports = service.fetch('ports')
      expected = [{ 'target' => 80, 'published' => 18080, 'protocol' => 'tcp', 'mode' => domain ? 'ingress' : 'host' }]
      if domain
        expected += %w[tcp udp].map { |protocol| { 'target' => 443, 'published' => 18443, 'protocol' => protocol, 'mode' => 'ingress' } }
        assert_includes service['command'], '--entryPoints.https.http3.advertisedport=18443'
      end
      expected << { 'target' => 5432, 'published' => postgres.to_i, 'protocol' => 'tcp', 'mode' => 'ingress' } if postgres
      assert_equal expected, ports
      refute ports.any? { |port| port['target'] == 8080 }
      assert_equal !!postgres, service['command'].include?('--entrypoints.postgres.address=:5432')
      assert_includes service['command'], '--metrics.otlp=true'
      assert_includes service['command'], '--providers.file.directory=/etc/traefik_dynamic'
      assert_includes service['volumes'], 'traefik_data:/certificates'
      assert_includes service['volumes'], 'traefik_data:/letsencrypt'
      assert_includes service['volumes'], '/var/run/docker.sock:/var/run/docker.sock'
      assert service['configs'].any? { |config| config['target'] == '/plugins-local/src/add_header_plugin/main.go' }
    end
  end
end
