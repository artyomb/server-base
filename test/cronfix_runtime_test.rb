require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

class CronfixRuntimeTest < Minitest::Test
  def wrapper_path(path)
    Dir.mktmpdir('cronfix-path-test-') do |root|
      FileUtils.mkdir_p(File.join(root, 'state'))
      FileUtils.cp(File.expand_path('../actions/system/cronfix/cronfix/cron.sh', __dir__), root)
      File.write(File.join(root, '.ruby-path'), "#{File.realpath(RbConfig.ruby)}\n")
      File.write(File.join(root, 'fixes_processor.rb'), "puts ENV.fetch('PATH')\n")
      out, err, status = Open3.capture3({ 'PATH' => path, 'BASH_ENV' => nil, 'ENV' => nil },
                                      '/bin/bash', File.join(root, 'cron.sh'))
      assert status.success?, err
      out.strip.split(':')
    end
  end

  def test_minimal_cron_path_includes_static_docker_directory
    assert_equal %w[/usr/local/bin /usr/bin /bin], wrapper_path('/usr/bin:/bin')
  end

  def test_existing_path_order_is_preserved_without_duplicates
    paths = %w[/custom/bin /usr/local/bin /usr/bin /bin]
    assert_equal paths, wrapper_path(paths.join(':'))
  end

  def test_bundler_can_load_all_actions
    out, err, status = Open3.capture3('bundle', 'exec', 'ruby', '-Ilib', '-rdeploy', '-e',
                                     'r = Deploy::Actions::Registry.new; Deploy::Actions::Loader.new("actions", r).load_all; puts r.names',
                                     chdir: File.expand_path('..', __dir__))
    assert status.success?, err
    assert_includes out.lines.map(&:strip), 'cronfix'
  end
end
