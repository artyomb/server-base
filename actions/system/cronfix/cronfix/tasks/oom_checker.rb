require 'digest'

module Cronfix
  class OomChecker
    PATTERN = /out of memory|oom-kill|invoked oom-killer|killed process|memory cgroup out of memory/i

    def self.initial_checkpoint(config, now)
      { 'since' => now - config['oom_initial_minutes'] * 60 }
    end

    def self.check(runner, state, now)
      args = ['journalctl', '--no-pager', '--output=json', '--all', '_TRANSPORT=kernel']
      if state['cursor']
        # Including the previous entry proves the cursor still exists after rotation.
        args += ['--cursor', state['cursor']]
      else
        state['since'] ||= now - runner.config['oom_initial_minutes'] * 60
        args += ['--since', "@#{state['since']}"]
      end
      result = runner.capture(*args)
      complete = result.success?
      output = result.stdout.b
      unless complete
        unless result.exception.is_a?(SafeExec::OutputLimitError) && [nil, 0].include?(result.exitstatus)
          raise "journalctl: #{result.exception ? result.exception.class : "exit #{result.exitstatus}"}"
        end

        # The cap may split a record. Resume from the last complete JSON line.
        ending = output.rindex("\n")
        raise 'Journal record exceeds the command output limit' unless ending

        output = output[0..ending]
      end
      rows = output.force_encoding('UTF-8').lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
      rows.each do |row|
        unless row.is_a?(Hash) && row['__CURSOR'].is_a?(String) && !row['__CURSOR'].empty? &&
               row['__REALTIME_TIMESTAMP'].to_s.match?(/\A\d+\z/)
          raise 'Invalid journal JSON entry'
        end
        message = row['MESSAGE']
        if message.is_a?(Array) && message.all? { |byte| byte.is_a?(Integer) && byte.between?(0, 255) }
          message = message.pack('C*').force_encoding('UTF-8').scrub
        end
        raise 'Invalid journal MESSAGE' unless message.is_a?(String)

        row['MESSAGE'] = message
      end
      raise 'Duplicate journal cursor' unless rows.map { |row| row['__CURSOR'] }.uniq.size == rows.size

      if state['cursor']
        raise 'Journal cursor is unavailable; continuity cannot be verified' unless rows.first && rows.first['__CURSOR'] == state['cursor']

        rows.shift
      end
      raise 'Journal record exceeds the command output limit' if !complete && rows.empty?

      events = rows.filter_map do |row|
        next unless row['MESSAGE'].match?(PATTERN)

        summary = "Kernel OOM record at #{Time.at(Integer(row['__REALTIME_TIMESTAMP'], 10) / 1_000_000.0).utc.iso8601}"
        summary += ": #{row['MESSAGE'].gsub(/[\x00-\x1f]/, ' ')[0, 500]}" if runner.config['oom_include_message']
        { id: "oom:#{Digest::SHA256.hexdigest(row['__CURSOR'])}", message: summary }
      end
      state['cursor'] = rows.last['__CURSOR'] unless rows.empty?
      observations = complete ? [] : [{ key: 'check', status: 'pending', message: 'Kernel journal backlog remains' }]
      { observations: observations, events: events, checkpoint: state, complete: complete }
    end
  end
end
