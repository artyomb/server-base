require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'yaml'

class TraefikDashboardTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  ACTION = File.join(ROOT, 'actions/stacks/traefik')
  ROUTERS = %w[simple-ingress_traefik-0 simple-ingress_traefik-1].freeze

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
      labels = service.fetch('deploy').fetch('labels').to_h { |label| label.split('=', 2) }
      [compose, service, labels.transform_values { |value| value.gsub('$$', '$') }]
    end
  end

  def test_dashboard_and_compatibility_routes_require_oauth_and_use_the_internal_backend
    [nil, 'example.test'].each do |domain|
      compose, service, labels = render('TLS_DOMAIN' => domain)
      path, host = ROUTERS.map { |name| "traefik.http.routers.#{name}" }
      assert_equal ROUTERS, labels.keys.filter_map { |key| key[/\Atraefik\.http\.routers\.(.+)\.service\z/, 1] }
      assert_equal '(Path(`/traefik`) || PathPrefix(`/traefik/`))', labels["#{path}.rule"]
      assert_equal 'HostRegexp(`{name:traefik\..*}`)', labels["#{host}.rule"]
      assert_equal '100', labels["#{path}.priority"]
      assert_equal '99', labels["#{host}.priority"]
      assert_operator labels["#{path}.priority"].to_i, :>, 'HostRegexp(`{name:application\.example\.test}`)'.length
      assert_operator labels["#{path}.priority"].to_i, :<, 999
      ROUTERS.each_with_index do |name, index|
        assert_equal 'api@internal', labels["traefik.http.routers.#{name}.service"]
        middlewares = ["#{name}_oauth_provider", "#{name}-mount-redirect"]
        middlewares << "#{name}-target" if index == 1
        assert_equal middlewares.join(','), labels["traefik.http.routers.#{name}.middlewares"]
        oauth = "traefik.http.middlewares.#{name}_oauth_provider.forwardauth"
        assert_equal 'http://oauth2_oauth2_slim:7000/auth', labels["#{oauth}.address"]
        assert_equal '^X-', labels["#{oauth}.authResponseHeadersRegex"]
        refute labels.key?("#{oauth}.trustForwardHeader")
      end
      assert_equal '/traefik', labels["traefik.http.middlewares.#{ROUTERS[1]}-target.addprefix.prefix"]
      refute labels.keys.any? { |key| key.include?('stripprefix') || key.include?('basicauth') }
      assert_equal({ 'traefik.http.services.simple-ingress_traefik-unused.loadbalancer.server.port' => '9999' },
                   labels.select { |key, _| key.start_with?('traefik.http.services.') })
      refute service.fetch('configs').any? { |config| config['target'] == '/etc/traefik_dynamic/dashboard.yml' }

      assert_includes service.fetch('command'), '--api.basePath=/traefik'
      refute service['command'].any? { |arg| arg.start_with?('--api.insecure', '--entrypoints.traefik.') }
      assert_equal 'true', labels['traefik.enable']
      assert service.fetch('networks').key?('ingress_routing')
      assert_equal({ 'external' => true, 'name' => 'ingress-routing' }, compose['networks']['ingress_routing'])
      assert service['networks'].key?('grafana_network')
    end
  end

  def test_tls_domains_are_preserved_and_plain_http_has_no_tls_routes
    _compose, _service, labels = render('TLS_DOMAIN' => 'example.test')
    expected = ROUTERS.zip(%w[example.test traefik.example.test]).to_h
    expected.each do |name, domain|
      prefix = "traefik.http.routers.#{name}.tls"
      assert_equal 'true', labels[prefix]
      assert_equal 'le', labels["#{prefix}.certresolver"]
      assert_equal domain, labels["#{prefix}.domains[0].main"]
    end
    _compose, _service, plain = render
    refute plain.keys.any? { |key| key.start_with?('traefik.http.routers.') && key.include?('.tls') }
  end

  def test_canonical_root_redirect_covers_both_slash_forms_without_matching_api_or_assets
    _compose, _service, labels = render
    prefix = "traefik.http.middlewares.#{ROUTERS[0]}-mount-redirect.redirectregex"
    assert_equal '${1}/traefik/dashboard/${2}', labels["#{prefix}.replacement"]
    assert_equal 'false', labels["#{prefix}.permanent"]
    regex = Regexp.new(labels.fetch("#{prefix}.regex"))
    %w[http https].product(['', '/'], ['', '?test=value']).each do |scheme, slash, query|
      match = regex.match("#{scheme}://example.test:18443/traefik#{slash}#{query}")
      refute_nil match
      assert_equal "#{scheme}://example.test:18443", match[1]
      assert_equal query, match[2].to_s
    end
    %w[/traefikevil /traefik/dashboard/ /traefik/api/overview /traefik/dashboard/assets/index.js].each do |path|
      refute_match regex, "https://example.test#{path}"
    end

    prefix = "traefik.http.middlewares.#{ROUTERS[1]}-mount-redirect.redirectregex"
    assert_equal '${1}/traefik/dashboard/${2}', labels["#{prefix}.replacement"]
    regex = Regexp.new(labels.fetch("#{prefix}.regex"))
    match = regex.match('https://traefik.example.test/?next=%2Fapi&x=1')
    refute_nil match
    assert_equal 'https://traefik.example.test', match[1]
    assert_equal '?next=%2Fapi&x=1', match[2]
    %w[/dashboard/ /api/overview /traefik /traefik/].each do |path|
      refute_match regex, "https://traefik.example.test#{path}"
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
      refute ports.any? { |port| [8080, 9999].include?(port['target']) }
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
