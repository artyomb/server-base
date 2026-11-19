require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'tmpdir'

class DeploymentLockTest < Minitest::Test
  DEPLOY = File.expand_path('../bin/deploy', __dir__)

  def setup
    @dir = Dir.mktmpdir('deployment-lock-')
    @env = { 'PATH' => "#{@dir}:#{ENV.fetch('PATH')}", 'FIXTURE' => @dir }
    %w[alpha beta].each do |host|
      FileUtils.mkdir_p(File.join(@dir, host))
      File.write(File.join(@dir, "#{host}.rb"), "Server(:#{host}) { host '#{host}'; main_domain '#{host}.test' }")
    end
    File.write(File.join(@dir, 'action.rb'), <<~'RUBY')
      Action :probe, default: true do
        apply do
          exec('fixture-operation')
        end
      end
    RUBY
    ssh = File.join(@dir, 'ssh')
    File.write(ssh, <<~'RUBY')
      #!/usr/bin/env ruby
      host, cmd = ARGV.last(2)
      Dir.chdir(File.join(ENV.fetch('FIXTURE'), host.delete_prefix('root@')))
      case cmd
      when %r{/run/server-base-deploy.lock}
        cmd = cmd.sub('/run/server-base-deploy.lock', 'deploy.lock')
        case ENV['MODE']
        when 'lost-session'
          system('bash', '-c', cmd, in: File::NULL)
          exit 255
        when 'slow-close'
          system('bash', '-c', cmd)
          STDOUT.reopen(File::NULL, 'w')
          sleep 4
          exit $?.exitstatus
        end
        exec('bash', '-c', cmd)
      when /command -v rsync/
        exit 1
      when 'fixture-operation'
        File.write('entered', '')
        case ENV['MODE']
        when 'hold'
          sleep 0.02 until File.exist?('finish')
          File.write('finished', '')
        when 'failure' then exit 7
        end
      else
        exec('bash', '-c', cmd)
      end
    RUBY
    hostname = File.join(@dir, 'hostname')
    File.write(hostname, "#!/bin/sh\necho preflight >> preflights\necho fixture\n")
    File.chmod(0o700, ssh, hostname)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def command(host)
    [RbConfig.ruby, DEPLOY, '--server', host, '--servers-dir', @dir, '--actions-dir', @dir]
  end

  def deploy(host = 'alpha', mode = nil)
    Open3.capture2e(@env.merge('MODE' => mode), *command(host))
  end

  def test_excludes_a_second_client_before_preflight_while_another_host_deploys
    Open3.popen2e(@env.merge('MODE' => 'hold'), *command('alpha')) do |_stdin, output, process|
      begin
        Timeout.timeout(10) { sleep 0.02 until File.exist?(File.join(@dir, 'alpha/entered')) }
        message, status = deploy('alpha', 'slow-close')
        refute status.success?
        assert_includes message, 'Deployment already running'
        assert_equal 1, File.readlines(File.join(@dir, 'alpha/preflights')).size
        message, status = deploy('beta')
        assert status.success?, message
      ensure
        FileUtils.touch(File.join(@dir, 'alpha/finish'))
      end
      assert process.value.success?, output.read
    end
    message, status = deploy
    assert status.success?, message
  end

  def test_failed_action_releases_the_lock_for_a_retry
    message, status = deploy('alpha', 'failure')
    refute status.success?
    assert_includes message, 'Remote command failed'
    message, status = deploy
    assert status.success?, message
  end

  def test_accepts_delayed_successful_ssh_exit
    message, status = deploy('alpha', 'slow-close')
    assert status.success?, message
    assert File.exist?(File.join(@dir, 'alpha/entered'))
  end

  def test_killed_runner_releases_the_lock_while_its_independent_command_finishes
    Open3.popen2e(@env.merge('MODE' => 'hold'), *command('alpha')) do |_stdin, _output, process|
      begin
        Timeout.timeout(10) { sleep 0.02 until File.exist?(File.join(@dir, 'alpha/entered')) }
        Process.kill('KILL', process.pid)
        assert process.value.signaled?
        message, status = deploy
        assert status.success?, message
        refute File.exist?(File.join(@dir, 'alpha/finished'))
      ensure
        FileUtils.touch(File.join(@dir, 'alpha/finish'))
      end
      Timeout.timeout(10) { sleep 0.02 until File.exist?(File.join(@dir, 'alpha/finished')) }
    end
  end

  def test_reports_failed_main_channel_when_the_deployment_finishes
    message, status = deploy('alpha', 'lost-session')
    refute status.success?
    assert_includes message, 'Main SSH session lost'
    message, status = deploy
    assert status.success?, message
  end

  def test_tar_fallback_copies_the_requested_file
    File.write(File.join(@dir, 'alpha.rb'), <<~'RUBY')
      Server(:alpha) do
        host 'alpha'
        main_domain 'alpha.test'
        rsync source: 'payload.txt', target: 'incoming'
      end
    RUBY
    File.write(File.join(@dir, 'payload.txt'), "test payload\n")
    message, status = deploy
    assert status.success?, message
    assert_equal "test payload\n", File.read(File.join(@dir, 'alpha/incoming/payload.txt'))
  end
end
