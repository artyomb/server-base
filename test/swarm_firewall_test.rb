require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../lib/deploy'

class SwarmFirewallTest < Minitest::Test
  SCRIPT = File.expand_path('../actions/system/swarm/block_ports.sh', __dir__)

  def test_uploaded_files_satisfy_readiness_but_content_drift_does_not
    Dir.mktmpdir('swarm-firewall-upload-') do |dir|
      ssh = Object.new
      ssh.define_singleton_method(:script!) do |script|
        _out, err, status = Open3.capture3('bash', stdin_data: script)
        raise "Fixture upload failed: #{err}" unless status.success?
      end
      context = Deploy::ActionContext.new(nil, ssh, {})
      files = {
        '/usr/local/sbin/swarm-block-ports' => File.join(dir, 'block_ports.sh'),
        '/etc/systemd/system/swarm-block-ports.service' => File.join(dir, 'swarm-block-ports.service')
      }
      files.each_value do |path|
        context.write_file(path, File.read(File.join(File.dirname(SCRIPT), File.basename(path))))
      end
      context.define_singleton_method(:read_file) { |path, default:| File.read(files.fetch(path)) }
      context.define_singleton_method(:capture) do |command|
        case command
        when /Swarm.LocalNodeState/ then "active\n"
        when /Swarm.ControlAvailable/ then "true\n"
        when /docker plugin ls/ then "loki:latest true\n"
        when /docker network ls/ then "ingress-routing\ngrafana-network\nnats-network\n"
        when /systemctl is-enabled/ then "ok\n"
        else raise "Unexpected fixture command: #{command}"
        end
      end
      registry = Deploy::Actions::Registry.new
      Deploy::Actions::Loader.new(File.dirname(SCRIPT), registry).load_all
      check = registry.fetch(:swarm).instance_variable_get(:@check)
      assert context.instance_exec({}, &check)
      files.each_value do |path|
        original = File.read(path)
        File.write(path, original.sub(/Swarm/, 'Changed'))
        refute context.instance_exec({}, &check)
        File.write(path, original)
      end
      assert context.instance_exec({}, &check)
    end
  end

  def test_dual_stack_policy_is_idempotent_and_detects_missing_rules
    Dir.mktmpdir('swarm-firewall-test-') do |dir|
      state_path = File.join(dir, 'state.json')
      ssh_rule = %w[-p tcp --dport 22 -j ACCEPT]
      forward_rule = %w[-i private0 -j ACCEPT]
      File.write(state_path, JSON.generate('iptables' => { 'INPUT' => [ssh_rule], 'FORWARD' => [], 'DOCKER-USER' => [forward_rule] },
                                           'ip6tables' => { 'INPUT' => [ssh_rule], 'FORWARD' => [forward_rule] }))
      %w[iptables ip6tables].each do |name|
        path = File.join(dir, name)
        File.write(path, <<~RUBY)
          #!#{RbConfig.ruby}
          require 'json'
          path = ENV.fetch('FIREWALL_TEST_STATE')
          state = JSON.parse(File.read(path))
          chains = state.fetch(File.basename($PROGRAM_NAME))
          args = ARGV.reject { |arg| arg == '-w' }
          operation, chain = args.shift(2)
          code = 0
          case operation
          when '-S'
            if chains.key?(chain)
              puts %w[INPUT FORWARD].include?(chain) ? "-P \#{chain} ACCEPT" : "-N \#{chain}"
              chains[chain].each { |rule| puts "-A \#{chain} \#{rule.join(' ')}" }
            else
              code = 1
            end
          when '-N'
            chains.key?(chain) ? code = 1 : chains[chain] = []
          else
            if !chains.key?(chain)
              code = 1
            else
              case operation
              when '-F' then chains[chain] = []
              when '-A' then chains[chain] << args
              when '-I' then chains[chain].insert(args.shift.to_i - 1, args)
              when '-C' then code = chains[chain].include?(args) ? 0 : 1
              when '-D'
                index = chains[chain].index(args)
                index ? chains[chain].delete_at(index) : code = 1
              else abort "Unexpected operation: \#{operation}"
              end
            end
          end
          File.write(path, JSON.generate(state))
          exit code
        RUBY
        File.chmod(0o700, path)
      end
      env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'FIREWALL_TEST_STATE' => state_path, 'EXT_IF' => 'wan0 wan1' }
      run = lambda do |mode, expected = true|
        _out, err, status = Open3.capture3(env, 'sh', SCRIPT, mode)
        assert_equal expected, status.success?, "#{mode}: #{err}"
      end
      run.call('--check', false)
      run.call('--apply')
      run.call('--check')
      first = JSON.parse(File.read(state_path))
      run.call('--apply')
      run.call('--check')
      assert_equal first, JSON.parse(File.read(state_path))
      families = File.exist?('/proc/net/if_inet6') ? %w[iptables ip6tables] : %w[iptables]
      families.each do |family|
        chains = first.fetch(family)
        assert_equal ['-j', 'SWARM-BLOCK-INPUT'], chains.fetch('INPUT').first
        assert_equal ssh_rule, chains.fetch('INPUT').last
        parent = chains.key?('DOCKER-USER') ? 'DOCKER-USER' : 'FORWARD'
        assert_equal ['-j', 'SWARM-BLOCK-PUBLISHED'], chains.fetch(parent).first
        assert_equal forward_rule, chains.fetch(parent).last
        rules = chains.fetch('SWARM-BLOCK-PUBLISHED')
        assert_equal 3, rules.size
        rules.take(2).each do |rule|
          assert_equal '3100', rule[rule.index('--ctorigdstport') + 1]
          assert_equal 'ORIGINAL', rule[rule.index('--ctdir') + 1]
        end
        input = chains.fetch('SWARM-BLOCK-INPUT')
        assert_equal ['-j', 'RETURN'], input.last
        assert_equal 11, input.size
        %w[wan0 wan1].each do |interface|
          rules = input.take(10).select { |rule| rule[rule.index('-i') + 1] == interface }
          ports = rules.map { |rule| [rule[rule.index('-p') + 1], rule[rule.index('--dport') + 1]] }
          assert_equal [%w[tcp 3100], %w[tcp 2377], %w[tcp 7946], %w[udp 7946], %w[udp 4789]], ports
          rules.each do |rule|
            assert_equal 'REJECT', rule[rule.index('-j') + 1]
            assert_includes rule, 'tcp-reset' if rule[rule.index('-p') + 1] == 'tcp'
          end
        end
      end
      damaged = Marshal.load(Marshal.dump(first))
      damaged.fetch('iptables').fetch('SWARM-BLOCK-PUBLISHED').shift
      File.write(state_path, JSON.generate(damaged))
      run.call('--check', false)
      run.call('--apply')
      run.call('--check')
      repaired = JSON.parse(File.read(state_path))
      repaired.fetch('iptables').fetch('SWARM-BLOCK-INPUT').reject! { |rule| rule.include?('udp') && rule.include?('7946') }
      File.write(state_path, JSON.generate(repaired))
      run.call('--check', false)
      run.call('--apply')
      run.call('--check')
      assert_equal first, JSON.parse(File.read(state_path))
    end
  end
end
