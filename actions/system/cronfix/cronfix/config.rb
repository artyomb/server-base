require 'json'

module Cronfix
  TASKS = %w[inode_usage oom_checker swarm_service_replicas].freeze

  module Config
    DEFAULTS = {
      'tasks' => TASKS, 'interval_minutes' => 5,
      'inode_paths' => ['/'], 'inode_docker_root' => true, 'inode_percent' => 90,
      'oom_initial_minutes' => 10, 'oom_include_message' => false,
      'swarm_grace_seconds' => 300, 'command_timeout' => 20,
      'run_timeout' => 240, 'max_output_bytes' => 4 * 1024 * 1024,
      'telegram_credentials' => nil
    }.freeze

    def self.read(path, overrides = {})
      current = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      raise 'Config must be a JSON object' unless current.is_a?(Hash) && overrides.is_a?(Hash)

      validate(DEFAULTS.merge(current).merge(overrides))
    rescue JSON::ParserError
      raise 'Invalid config JSON'
    end

    def self.validate(config)
      tasks = config['tasks']
      raise 'Invalid task selection' unless tasks.is_a?(Array) && !tasks.empty? && tasks.uniq == tasks && (tasks - TASKS).empty?

      { 'interval_minutes' => 1..59, 'inode_percent' => 1..100, 'oom_initial_minutes' => 1..1440,
        'swarm_grace_seconds' => 0..86400, 'command_timeout' => 1..600,
        'run_timeout' => 1..3600, 'max_output_bytes' => 1024..64 * 1024 * 1024 }.each do |key, range|
        value = config[key]
        raise "Invalid #{key}" unless value.is_a?(Integer) && range.cover?(value)
      end
      raise 'run_timeout must exceed command_timeout' unless config['run_timeout'] > config['command_timeout']

      paths = config['inode_paths']
      unless paths.is_a?(Array) && !paths.empty? && paths.all? { |p| p.is_a?(String) && p.start_with?('/') && !p.match?(/[\x00-\x1f]/) }
        raise 'inode_paths must contain absolute paths'
      end
      %w[inode_docker_root oom_include_message].each do |key|
        raise "Invalid #{key}" unless [true, false].include?(config[key])
      end
      credentials = config['telegram_credentials']
      unless credentials.nil? || (credentials.is_a?(String) && credentials.match?(/\A-?\d+:\d+:[A-Za-z0-9_-]+\z/))
        raise 'Invalid telegram_credentials (expected chat_id:bot_id:token)'
      end
      config
    end
  end
end
