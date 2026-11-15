module Cronfix
  class SwarmServiceReplicas
    def self.check(runner, state, now)
      swarm = JSON.parse(runner.command('docker', 'info', '--format', '{{json .Swarm}}'))
      raise 'Swarm is not active' unless swarm.is_a?(Hash) && swarm['LocalNodeState'] == 'active'
      raise 'Invalid Swarm manager state' unless [true, false].include?(swarm['ControlAvailable'])
      unless swarm['ControlAvailable']
        return { observations: [{ key: 'role', status: 'not_applicable', message: 'Worker: service diagnostics require a manager' }], checkpoint: state, complete: false }
      end

      services = runner.command('docker', 'service', 'ls', '--format', '{{json .}}').lines.map { |line| JSON.parse(line) }
      raise 'Duplicate service IDs' unless services.map { |row| row['ID'] }.uniq.size == services.size

      deficits = state.fetch('deficits', {})
      current = {}
      observations = services.map do |row|
        id, name, mode, replicas = row.values_at('ID', 'Name', 'Mode', 'Replicas')
        raise 'Invalid service identity' unless id.is_a?(String) && id.match?(/\A[a-z0-9]+\z/) && name.is_a?(String) && !name.empty?
        raise 'Unsupported service mode' unless %w[replicated global replicated-job global-job].include?(mode)

        pattern = mode.end_with?('-job') ? /\A(\d+)\/(\d+) \((\d+)\/(\d+) completed\)\z/ : /\A(\d+)\/(\d+)\z/
        match = replicas.is_a?(String) && replicas.match(pattern)
        raise 'Invalid service replica counts' unless match

        running, desired, completed, total = match.captures.map { |v| Integer(v, 10) }
        healthy = running >= desired
        healthy = completed >= total || (desired.positive? && running >= desired) if mode.end_with?('-job')
        message = "Service #{name} (#{mode}): #{replicas}"
        unless healthy
          details = JSON.parse(runner.command('docker', 'service', 'inspect', id))
          raise 'Invalid service inspect response' unless details.is_a?(Array) && details.size == 1 && details[0].is_a?(Hash)

          service = details.first
          # Regular on-failure/none services can be intentionally finite. Validate
          # every current slot, not just the last completed task in service history.
          healthy = completed_service?(runner, service, id, mode, desired) unless mode.end_with?('-job')
        end
        status = 'healthy'
        unless healthy
          since = deficits.fetch(id, now)
          current[id] = since
          status = now - since >= runner.config['swarm_grace_seconds'] ? 'problem' : 'pending'
          message += status == 'pending' ? ' (convergence grace)' : ' (replica deficit)'
        end
        { key: id, status: status, message: message }
      end
      state['deficits'] = current
      { observations: observations, checkpoint: state, complete: true }
    end

    def self.completed_service?(runner, service, id, mode, desired)
      return false unless mode == 'replicated' && desired.positive?
      return false unless %w[on-failure none].include?(service.dig('Spec', 'TaskTemplate', 'RestartPolicy', 'Condition'))

      task_ids = runner.command('docker', 'service', 'ps', '--no-trunc', '-q', id).lines.map(&:strip)
      return false if task_ids.empty?
      raise 'Invalid task IDs' unless task_ids.all? { |task| task.match?(/\A[a-z0-9]+\z/) }

      tasks = task_ids.each_slice(50).flat_map do |ids|
        parsed = JSON.parse(runner.command('docker', 'inspect', '--type', 'task', *ids))
        raise 'Invalid task inspect response' unless parsed.is_a?(Array) && parsed.size == ids.size

        parsed
      end
      latest = tasks.group_by { |task| task.fetch('Slot') }.values.map { |group| group.max_by { |task| Time.iso8601(task.fetch('CreatedAt')) } }
      return false unless latest.size == desired && latest.map { |task| task['Slot'] }.sort == (1..desired).to_a

      latest.all? do |task|
        # An old successful task must not hide a failure or a new service revision.
        next false unless task['Spec'] == service.dig('Spec', 'TaskTemplate') && task.dig('Status', 'Err').to_s.empty?

        (task.dig('Status', 'State') == 'running' && task['DesiredState'] == 'running') ||
          (task.dig('Status', 'State') == 'complete' && task.dig('Status', 'ContainerStatus', 'ExitCode') == 0)
      end
    end
  end
end
