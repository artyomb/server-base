require 'base64'
require 'digest'
require 'fileutils'
require 'rbconfig'
require 'tempfile'
require_relative 'config'
require_relative 'safe_exec'

module Cronfix
  class Bundle
    FILES = %w[config.rb safe_exec.rb notify.rb fixes_processor.rb bundle.rb install.sh cron.sh
               tasks/inode_usage.rb tasks/oom_checker.rb tasks/swarm_service_replicas.rb].freeze
    MARKER = '# server-base-cronfix'.freeze

    def self.package(directory, settings = {})
      raise 'Settings must be an object' unless settings.is_a?(Hash)
      unknown = settings.keys - Config::DEFAULTS.keys
      raise "Unknown cronfix settings: #{unknown.join(', ')}" unless unknown.empty?

      { 'settings' => settings, 'files' => FILES.to_h do |name|
        path = File.join(directory, name)
        raise "Invalid source file #{name}" unless File.file?(path) && !File.symlink?(path)

        [name, Base64.strict_encode64(File.binread(path))]
      end }
    end

    def initialize(root, package)
      @root = File.expand_path(root)
      raise 'Install root must be an absolute path without shell/cron metacharacters' unless root == @root && root.match?(%r{\A/[A-Za-z0-9_./-]+\z}) && root != '/'
      raise 'Invalid package' unless package.is_a?(Hash) && package['files'].is_a?(Hash) && package['files'].keys.sort == FILES.sort

      @files = package['files'].transform_values { |value| Base64.strict_decode64(value) }
      @settings = package.fetch('settings')
      raise 'Invalid settings' unless @settings.is_a?(Hash) && (@settings.keys - Config::DEFAULTS.keys).empty?

      @manifest = @files.to_h { |name, content| [name, { 'sha256' => Digest::SHA256.hexdigest(content), 'mode' => mode(name) }] }
    end

    def run(install:)
      raise 'Ruby 3.1 or newer is required' if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.1')

      safe_path(@root)
      return false if !install && !File.directory?(@root)

      FileUtils.mkdir_p(@root, mode: 0o700)
      safe_path(File.join(@root, 'state'))
      FileUtils.mkdir_p(File.join(@root, 'state'), mode: 0o700)
      File.open(File.join(@root, 'state', 'run.lock'), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise 'cronfix is running; retry preparation later' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        prepare(install)
      end
    end

    private

    def mode(name) = name.end_with?('.sh') ? 0o700 : 0o600

    def safe_path(path)
      current = path
      until current == '/'
        raise 'Symlink in managed path' if File.symlink?(current)

        current = File.dirname(current)
      end
    end

    def read(name)
      path = File.join(@root, name)
      safe_path(path)
      File.exist?(path) ? File.binread(path) : nil
    end

    def write(name, content, permissions)
      path = File.join(@root, name)
      safe_path(path)
      return if File.file?(path) && File.binread(path) == content && (File.stat(path).mode & 0o777) == permissions

      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      Tempfile.create(['.bundle-', '.tmp'], File.dirname(path)) do |file|
        file.chmod(permissions)
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end

    def command(*argv)
      result = SafeExec.capture(*argv, timeout: 20)
      raise "Prerequisite failed: #{argv.first}" unless result.success?

      result.stdout
    end

    def crontab
      result = SafeExec.capture('crontab', '-l', timeout: 20)
      return result.stdout if result.success?
      return '' if result.exitstatus == 1 && result.stderr.strip.match?(/\Ano crontab for \S+\z/)

      raise 'Cannot read crontab; refusing to replace it'
    end

    def prepare(install)
      old_text = read('.manifest.json')
      old = old_text ? JSON.parse(old_text) : {}
      raise 'Invalid ownership manifest' unless old.is_a?(Hash) && (old.keys - FILES).empty?

      unless old_text
        %w[.ruby-path last-run.log state/state.json].each do |name|
          raise "Unmanaged runtime file collision: #{name}" if read(name)
        end
      end
      safe_path(File.join(@root, 'last-run.log'))

      @files.each_key do |name|
        existing = read(name)
        if existing && !old.key?(name) && existing != @files[name]
          raise "Unmanaged file collision: #{name}"
        end
      end
      config_text = read('config.json')
      config = Config.read(File.join(@root, 'config.json'), @settings)
      raise 'Set telegram_credentials before enabling cronfix' unless config['telegram_credentials']

      %w[bash curl crontab flock].each { |binary| command('sh', '-c', 'command -v "$1" >/dev/null', 'cronfix', binary) }
      command('sh', '-c', 'command -v df >/dev/null') if config['tasks'].include?('inode_usage')
      command('sh', '-c', 'command -v journalctl >/dev/null') if config['tasks'].include?('oom_checker')
      if config['tasks'].include?('swarm_service_replicas') || (config['tasks'].include?('inode_usage') && config['inode_docker_root'])
        command('sh', '-c', 'command -v docker >/dev/null')
      end
      # Check availability only; enabling/installing the scheduler is an operator action.
      active = %w[cron crond].any? { |service| SafeExec.capture('systemctl', 'is-active', '--quiet', service, timeout: 10).success? }
      raise 'An active cron/crond service is required' unless active

      current = crontab
      desired_line = "*/#{config['interval_minutes']} * * * * #{@root}/cron.sh > #{@root}/last-run.log 2>&1 #{MARKER}"
      lines = current.lines
      managed = lines.select { |line| line.rstrip.end_with?(MARKER) }
      if lines.any? { |line| !line.lstrip.start_with?('#') && line.include?("#{@root}/cron.sh") && !line.rstrip.end_with?(MARKER) }
        raise 'Unmanaged cron entry for this bundle; resolve ownership before installation'
      end
      schedule_ok = managed.size == 1 && managed.first.chomp == desired_line
      config_ok = config_text && Config.read(File.join(@root, 'config.json')) == config && (File.stat(File.join(@root, 'config.json')).mode & 0o777) == 0o600
      ruby_path = "#{File.realpath(RbConfig.ruby)}\n"
      files_ok = old == @manifest && @files.all? do |name, content|
        read(name) == content && (File.stat(File.join(@root, name)).mode & 0o777) == mode(name)
      end
      metadata_ok = %w[.ruby-path .manifest.json last-run.log].all? do |name|
        path = File.join(@root, name)
        File.file?(path) && (File.stat(path).mode & 0o777) == 0o600
      end
      return files_ok && config_ok && metadata_ok && read('.ruby-path') == ruby_path && schedule_ok unless install

      # All validations precede any replacement. Foreign files and .env are untouched.
      @files.each { |name, content| write(name, content, mode(name)) }
      write('config.json', JSON.pretty_generate(config) + "\n", 0o600) unless config_ok
      write('.ruby-path', ruby_path, 0o600)
      write('.manifest.json', JSON.pretty_generate(@manifest) + "\n", 0o600)
      log_path = File.join(@root, 'last-run.log')
      write('last-run.log', '', 0o600) unless File.exist?(log_path)
      File.chmod(0o600, log_path) unless (File.stat(log_path).mode & 0o777) == 0o600
      unless schedule_ok
        preserved = lines.reject { |line| line.rstrip.end_with?(MARKER) }.join
        preserved += "\n" unless preserved.empty? || preserved.end_with?("\n")
        result = SafeExec.capture('crontab', '-', stdin_data: preserved + desired_line + "\n", timeout: 20)
        raise 'Cannot install managed cron entry' unless result.success?
      end
      true
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    mode, root, package_file = ARGV
    raise 'Usage: bundle.rb check|install ROOT PACKAGE.json' unless %w[check install].include?(mode) && root && package_file

    ok = Cronfix::Bundle.new(root, JSON.parse(File.read(package_file))).run(install: mode == 'install')
    puts(ok ? 'ready' : 'drift')
    exit(ok ? 0 : 1)
  rescue StandardError => e
    warn "cronfix preparation failed: #{e.class}: #{e.message}"
    exit 2
  end
end
