require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/deploy'

class BaseChronyTest < Minitest::Test
  SCRIPT = File.expand_path('../actions/system/base/chrony.sh', __dir__)

  def setup
    @dir = Dir.mktmpdir('base-chrony-')
    @conf = File.join(@dir, 'chrony.conf')
    File.write(@conf, "pool example.test iburst\n")
    @script = File.join(@dir, 'chrony.sh')
    File.write(@script, in_fixture(File.read(SCRIPT)))
    @log = File.join(@dir, 'calls')
    @env = { 'PATH' => "#{@dir}:#{ENV.fetch('PATH')}", 'CALLS' => @log, 'CONF' => @conf, 'SYNC' => 'ok' }
    stub('systemctl', <<~'SH')
      case "$1" in
        is-active) exit "${SERVICE_STATUS:-0}";;
        enable) exit "${ENABLE_STATUS:-0}";;
        restart) cp "$CONF" "$CONF.loaded";;
        *) exit 2;;
      esac
    SH
    stub('chronyc', <<~'SH')
      case "$*" in
        '-n sources') echo 'source diagnostic';;
        '-n waitsync '*)
          case "$SYNC" in
            ok) exit 0;;
            new-source) grep -Fqx 'server new.test iburst' "$CONF.loaded";;
            hang) exec sleep 30;;
            fallback) grep -q '^# BEGIN BASE FALLBACK NTP SERVERS$' "$CONF";;
            *) exit 1;;
          esac;;
        'burst 4/4') exit 0;;
        *) exit 2;;
      esac
    SH

    registry = Deploy::Actions::Registry.new
    Deploy::Actions::Loader.new(File.dirname(SCRIPT), registry).load_all
    @action = registry.fetch(:base)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def in_fixture(command)
    command.gsub('/etc/chrony', "#{@dir}/chrony").gsub('/var/lib/server-base/chrony', "#{@dir}/state")
           .gsub('/tmp/base-install-ruby.sh', "#{@dir}/install-ruby.sh")
           .gsub('/root/.bashrc', "#{@dir}/bashrc").gsub('/etc/modules', "#{@dir}/modules")
  end

  def stub(name, body)
    path = File.join(@dir, name)
    File.write(path, "#!/bin/sh\necho \"#{name} $*\" >> \"$CALLS\"\n#{body}\n")
    File.chmod(0o700, path)
  end

  def invoke(sync, *args)
    Open3.capture3(@env.merge('SYNC' => sync), 'bash', @script, *args)
  end

  def test_check_confirms_sync_and_bounds_a_hung_probe
    assert_equal "synchronized\n", invoke('ok', 'check').first
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = invoke('hang', 'check')
    assert status.success?
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 15
    assert_equal "unsynchronized\n", out
    assert_includes err, 'source diagnostic'
    @env['SERVICE_STATUS'] = '3'
    assert_equal "inactive\n", invoke('ok', 'check').first
  end

  # Run the action with healthy unrelated probes. Package tests also execute full apply in the fixture.
  def run_base(*servers, **params)
    package_test = @env.key?('DPKG_ADMINDIR')
    context = Object.new
    fixture_command = lambda do |command|
      out, err, status = Open3.capture3(@env, 'bash', '-c', in_fixture(command))
      raise "chrony command failed (#{status.exitstatus}): #{err}" unless status.success?
      out
    end
    context.define_singleton_method(:distro) { 'ubuntu' }
    context.define_singleton_method(:capture) do |command|
      if command.start_with?('bash -s -- check') || (package_test && command.include?('dpkg'))
        fixture_command.call(command)
      else
        "ok\n"
      end
    end
    context.define_singleton_method(:remote) do |command|
      raise 'Unexpected full host maintenance' unless package_test || command.start_with?('bash -s -- apply')
      fixture_command.call(command)
    end

    capture_io { @action.run(context, **params, ntp_servers: servers) }.first
  end

  def test_ubuntu_reinstalls_config_files_only_package_before_repairing_chrony
    skip 'requires dpkg-query' unless system('dpkg-query', '--version', out: File::NULL)
    @env['DPKG_ADMINDIR'] = @dir
    @env['SERVICE_STATUS'] = '3'
    packages = { 'chrony' => 'deinstall ok config-files', 'jq' => 'hold ok installed' }
    records = packages.map do |name, status|
      <<~ENTRY
        Package: #{name}
        Status: #{status}
        Architecture: all
        Version: 1
        Maintainer: Fixture <test@example.org>
        Description: fixture package
      ENTRY
    end
    File.write(File.join(@dir, 'status'), records.join("\n"))
    stub('lsmod', 'echo ip_vs')
    stub('apt-get', <<~'SH')
      case "$*" in
        'update -y') ;;
        'install -y chrony') sed -i 's/deinstall ok config-files/install ok installed/' "$DPKG_ADMINDIR/status";;
        *) exit 1;;
      esac
    SH
    params = { skip_ruby: true, skip_packages: %w[curl mc htop screen gdu swapspace rsync yq] }
    assert_includes run_base(**params), 'missing packages: chrony'
    @env.delete('SERVICE_STATUS')
    assert_includes run_base(**params), '[action base] skip'
    calls = File.readlines(@log, chomp: true).grep(/^(apt-get |systemctl restart )/)
    assert_equal ['apt-get update -y', 'apt-get install -y chrony', 'systemctl restart chronyd'], calls
  end

  def test_profile_change_applies_once_on_a_synchronized_host
    prefix = "pool manual.example.test iburst\n# Keep this comment\n"
    suffix = "# BEGIN BASE FALLBACK NTP SERVERS\nserver backup.test iburst\n# END BASE FALLBACK NTP SERVERS\nmakestep 1 3"
    original = prefix + "# BEGIN BASE NTP SERVERS\nserver old.test iburst\n# END BASE NTP SERVERS\n" + suffix
    File.write(@conf, original)
    servers = ['new.test, other.test', 'new.test']
    first = run_base(*servers)
    assert_includes first, '[action base] apply'
    assert_equal original.sub('server old.test iburst', "server new.test iburst\nserver other.test iburst"), File.read(@conf)
    inode = File.stat(@conf).ino
    second = run_base(*servers)
    assert_includes second, '[action base] skip'
    assert_equal inode, File.stat(@conf).ino
    assert_equal 1, File.readlines(@log).count { |line| line.start_with?('systemctl restart ') }
  end

  def test_interrupted_update_restarts_before_reporting_success
    FileUtils.cp(@conf, "#{@conf}.loaded")
    @env['ENABLE_STATUS'] = '1'
    error = assert_raises(RuntimeError) { run_base('new.test') }
    assert_match(/chrony command failed/, error.message)
    assert_includes File.read(@conf), 'server new.test iburst'
    refute_includes File.read("#{@conf}.loaded"), 'server new.test iburst'
    assert_equal "restart-pending\n", invoke('ok', 'check', 'new.test').first

    @env.delete('ENABLE_STATUS')
    assert_includes run_base('new.test'), '[action base] apply'
    assert_equal File.read(@conf), File.read("#{@conf}.loaded")
    assert_includes run_base('new.test'), '[action base] skip'
    assert_equal 1, File.readlines(@log).count { |line| line.start_with?('systemctl restart ') }
  end

  def test_replacing_an_unreachable_source_repairs_only_chrony
    File.write(@conf, "# BEGIN BASE NTP SERVERS\nserver old.test iburst\n# END BASE NTP SERVERS\n")
    FileUtils.cp(@conf, "#{@conf}.loaded")
    @env['SYNC'] = 'new-source'
    assert_equal "unsynchronized\n", invoke('new-source', 'check').first
    assert_includes run_base('new.test'), '[action base] apply'
    assert_includes File.read("#{@conf}.loaded"), 'server new.test iburst'
    assert_includes run_base('new.test'), '[action base] skip'
    assert_equal 1, File.readlines(@log).count { |line| line.start_with?('systemctl restart ') }
  end

  def test_first_deployment_after_upgrade_loads_a_matching_legacy_block_once
    FileUtils.cp(@conf, "#{@conf}.loaded")
    File.write(@conf, "# BEGIN BASE NTP SERVERS\nserver new.test iburst\n# END BASE NTP SERVERS\n")
    inode = File.stat(@conf).ino
    assert_equal "synchronized\n", invoke('ok', 'check').first
    assert_equal "sources-unverified\n", invoke('ok', 'check', 'new.test').first
    FileUtils.mkdir_p(File.join(@dir, 'state'))
    FileUtils.touch(File.join(@dir, 'state/sources-verified'))
    assert_equal "sources-unverified\n", invoke('ok', 'check', 'new.test').first
    @env['ENABLE_STATUS'] = '1'
    assert_raises(RuntimeError) { run_base('new.test') }
    assert_equal "sources-unverified\n", invoke('ok', 'check', 'new.test').first
    @env.delete('ENABLE_STATUS')
    assert_includes run_base('new.test'), '[action base] apply'
    assert_equal File.read(@conf), File.read("#{@conf}.loaded")
    assert_includes run_base('new.test'), '[action base] skip'
    assert_equal inode, File.stat(@conf).ino
    assert_equal 1, File.readlines(@log).count { |line| line.start_with?('systemctl restart ') }
  end

  def test_rollback_write_cannot_reuse_verification_for_a_different_list
    run_base('old.test')
    verified = File.join(@dir, 'state/sources-verified')
    # An older deployer wrote the replacement list but stopped before restart.
    File.write(@conf, File.read(@conf).sub('server old.test iburst', "server new.test iburst\nserver backup.test iburst"))
    servers = %w[new.test backup.test]
    assert_includes File.read("#{@conf}.loaded"), 'server old.test iburst'
    assert_equal "sources-unverified\n", invoke('ok', 'check', *servers).first
    stub('mv', 'exit 1') # The configuration already matches; only publication of the verified list needs a rename.
    assert_raises(RuntimeError) { run_base(*servers) }
    assert_equal ['old.test'], File.readlines(verified, chomp: true)
    assert_equal "restart-pending\n", invoke('ok', 'check', *servers).first

    File.unlink(File.join(@dir, 'mv'))
    assert_includes run_base(*servers), '[action base] apply'
    assert_equal File.read(@conf), File.read("#{@conf}.loaded")
    assert_equal servers, File.readlines(verified, chomp: true)
    assert_equal 0o600, File.stat(verified).mode & 0o777
    assert_includes run_base(*servers), '[action base] skip'
  end

  def test_checks_only_explicit_sources_in_the_managed_block
    File.write(@conf, "server ntp.test iburst\n# BEGIN BASE FALLBACK NTP SERVERS\nserver ntp.test iburst\n# END BASE FALLBACK NTP SERVERS\n")
    assert_equal "sources-drift\n", invoke('ok', 'check', 'ntp.test').first
    assert_equal "synchronized\n", invoke('ok', 'check').first
    refute File.read(@log).include?('systemctl restart')
  end

  def test_unclosed_block_cannot_overwrite_operator_settings
    contents = "pool manual.test iburst\n# BEGIN BASE NTP SERVERS\nserver old.test iburst\nmakestep 1 3\n"
    File.write(@conf, contents)
    %w[check apply].each do |mode|
      _, err, status = invoke('ok', mode, 'new.test')
      refute status.success?
      assert_includes err, 'Malformed managed NTP source markers'
    end
    assert_equal contents, File.read(@conf)
  end

  def test_apply_uses_configured_source_then_confirms_fallback
    assert invoke('ok', 'apply', 'ntp.example.test').last.success?
    assert_includes File.read(@conf), "server ntp.example.test iburst\n"
    refute_includes File.read(@conf), 'BASE FALLBACK NTP SERVERS'
    assert invoke('fallback', 'apply', 'ntp.example.test').last.success?
    assert_equal 1, File.read(@conf).scan(/^server ntp.example.test iburst$/).size
    assert_includes File.read(@conf), "pool example.test iburst\n"
  end

  def test_apply_reports_failure_if_neither_source_synchronizes
    _, err, status = invoke('unavailable', 'apply')
    refute status.success?
    assert_includes err, 'source diagnostic'
    assert_equal 2, File.read(@log).lines.count { |line| line.include?(' waitsync ') }
    assert_equal "restart-pending\n", invoke('ok', 'check').first
  end
end
