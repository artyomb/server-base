require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'

class BaseChronyTest < Minitest::Test
  SCRIPT = File.expand_path('../actions/system/base/chrony.sh', __dir__)

  def setup
    @dir = Dir.mktmpdir('base-chrony-')
    @conf = File.join(@dir, 'chrony.conf')
    File.write(@conf, "pool example.test iburst\n")
    @script = File.join(@dir, 'chrony.sh')
    File.write(@script, File.read(SCRIPT).gsub('/etc/chrony', "#{@dir}/chrony"))
    @log = File.join(@dir, 'calls')
    @env = { 'PATH' => "#{@dir}:#{ENV.fetch('PATH')}", 'CALLS' => @log, 'CONF' => @conf }
    stub('systemctl', 'exit ${SERVICE_STATUS:-0}')
    stub('chronyc', <<~'SH')
      case "$*" in
        '-n sources') echo 'source diagnostic';;
        '-n waitsync '*)
          case "$SYNC" in
            ok) exit 0;;
            hang) exec sleep 30;;
            fallback) grep -q '^# BEGIN BASE FALLBACK NTP SERVERS$' "$CONF";;
            *) exit 1;;
          esac;;
        'burst 4/4') exit 0;;
        *) exit 2;;
      esac
    SH
  end

  def teardown = FileUtils.remove_entry(@dir)

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
  end
end
