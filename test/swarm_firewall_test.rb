require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'

class SwarmFirewallTest < Minitest::Test
  SCRIPT = File.expand_path('../actions/system/swarm/block_ports.sh', __dir__)

  def test_dual_stack_policy_is_idempotent_and_detects_missing_rules
    Dir.mktmpdir('swarm-firewall-test-') do |dir|
      state_path = File.join(dir, 'state.json')
      File.write(state_path, JSON.generate('iptables' => { 'INPUT' => [], 'FORWARD' => [], 'DOCKER-USER' => [] },
                                           'ip6tables' => { 'INPUT' => [], 'FORWARD' => [] }))
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
        parent = chains.key?('DOCKER-USER') ? 'DOCKER-USER' : 'FORWARD'
        assert_equal ['-j', 'SWARM-BLOCK-PUBLISHED'], chains.fetch(parent).first
        rules = chains.fetch('SWARM-BLOCK-PUBLISHED')
        assert_equal 3, rules.size
        rules.take(2).each do |rule|
          assert_equal '3100', rule[rule.index('--ctorigdstport') + 1]
          assert_equal 'ORIGINAL', rule[rule.index('--ctdir') + 1]
        end
      end
      first.fetch('iptables').fetch('SWARM-BLOCK-PUBLISHED').shift
      File.write(state_path, JSON.generate(first))
      run.call('--check', false)
      run.call('--apply')
      run.call('--check')
    end
  end
end
