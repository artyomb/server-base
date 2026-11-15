module Cronfix
  class InodeUsage
    def self.check(runner, state, _now)
      paths = runner.config['inode_paths'].dup
      if runner.config['inode_docker_root']
        root = JSON.parse(runner.command('docker', 'info', '--format', '{{json .DockerRootDir}}'))
        raise 'Invalid Docker data-root' unless root.is_a?(String) && root.start_with?('/') && !root.match?(/[\x00-\x1f]/)

        paths << root
      end
      mounts = {}
      paths.uniq.each do |path|
        lines = runner.command('df', '-Pi', '--', path).lines.map(&:strip).reject(&:empty?)
        raise 'Invalid df inode output' unless lines.size == 2

        match = lines.last.match(/\A(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\/.*)\z/)
        raise 'Unsupported or malformed inode statistics' unless match

        total, used, free, percent = match.captures[1, 4].map { |n| Integer(n, 10) }
        raise 'Inconsistent inode statistics' unless total.positive? && used <= total && free <= total && percent.between?(0, 100) && used + free == total
        raise 'Inconsistent inode percentage' unless percent == (100 * used + total - 1) / total

        mount = match[6]
        mounts[mount] = { key: mount, status: percent >= runner.config['inode_percent'] ? 'problem' : 'healthy',
                          message: "Inodes at #{mount}: #{percent}% (threshold #{runner.config['inode_percent']}%)" }
      end
      { observations: mounts.values, checkpoint: state, complete: true }
    end
  end
end
