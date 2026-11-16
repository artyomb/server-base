#!/usr/bin/env ruby
# frozen_string_literal: true

require 'etc'
require 'open3'
require 'pathname'
require 'timeout'

STDOUT.sync = true

ENV['SSH_AUTH_SOCK'] = ENV['CI_SSH_AUTH_SOCK'] if ENV['CI_SSH_AUTH_SOCK']&.strip&.yield_self { |v| !v.empty? }
puts "Using SSH_AUTH_SOCK: #{ENV['SSH_AUTH_SOCK']}" if ENV['SSH_AUTH_SOCK']

root = Pathname.new(__dir__)
config_root = Pathname.new(ARGV[0] || 'config/servers')
config_root = root.join(config_root) unless config_root.absolute?
config_name = ARGV[1]&.delete_suffix('.rb')
deploy_bin = root.join('bin', 'deploy')

abort 'bin/deploy is missing' unless deploy_bin.file?
abort "Directory #{config_root} does not exist." unless config_root.directory?

server_files = Dir.glob(config_root.join('**', '*.rb')).sort
server_files.select! { |f| File.basename(f, '.rb') == config_name } if config_name
abort "No server definition files found under #{config_root}" if server_files.empty?
puts "Found #{server_files.size} server files under #{config_root}"

Job = Struct.new(:id, :dir, :rel_dir, :name, keyword_init: true)
Result = Struct.new(:job, :status, :duration, keyword_init: true)
Status = Struct.new(:exitstatus, :success?, keyword_init: true)

def positive_integer(name, default)
  value = Integer(ENV.fetch(name, default).to_s, 10)
  abort "#{name} must be a positive integer" unless value.positive?
  value
rescue ArgumentError
  abort "#{name} must be a positive integer"
end

def signal_job(signal, pid)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  # The group may have exited before the signal was sent.
end

def stop_job(wait_thr)
  signal_job('TERM', wait_thr.pid)
  sleep 1
  # Descendants may survive TERM even after the direct child has exited.
  signal_job('KILL', wait_thr.pid)
  wait_thr.value
end

def run_job(cmd, prefix, timeout)
  Open3.popen2e(*cmd, pgroup: true) do |stdin, stdout_err, wait_thr|
    stdin.close
    begin
      Timeout.timeout(timeout) do
        stdout_err.each_line { |line| puts "#{prefix} #{line.delete("\r").rstrip}" }
        wait_thr.value
      end
    rescue Timeout::Error
      stop_job(wait_thr)
      puts "#{prefix} JOB_TIMEOUT #{timeout}s exceeded; local process group stopped. " \
           'Remote work may be partially applied or still running; inspect the server before retrying.'
      Status.new(exitstatus: 124, success?: false)
    rescue StandardError
      stop_job(wait_thr)
      raise
    end
  end
rescue StandardError => e
  warn "#{prefix} failed: #{e.class}: #{e.message}"
  Status.new(exitstatus: 1, success?: false)
end

jobs = server_files.map.with_index(1) do |file, idx|
  dir = File.dirname(file)
  rel_dir = Pathname.new(dir).relative_path_from(config_root).to_s
  rel_dir = '' if rel_dir == '.'
  Job.new(id: idx, dir: dir, rel_dir: rel_dir, name: File.basename(file, '.rb'))
end

max_workers = [positive_integer('JOBS', Etc.nprocessors), jobs.size].min
job_timeout = positive_integer('JOB_TIMEOUT', 300)
log_path = root.join('parallel.log')
File.write(log_path, "id\tserver\tdirectory\tstatus\tduration\n")

queue = Queue.new
jobs.each { |job| queue << job }
mutex = Mutex.new
results = []

workers = Array.new(max_workers) do
  Thread.new do
    while (job = queue.pop(true) rescue nil)
      cmd = ['ruby', deploy_bin.to_s, '--server', job.name, '--servers-dir', job.dir]
      prefix = "[#{job.id} #{job.name}]"
      puts "#{prefix} started"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = run_job(cmd, prefix, job_timeout)
      if status.respond_to?(:signaled?) && status.signaled?
        status = Status.new(exitstatus: 128 + status.termsig, success?: false)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      mutex.synchronize do
        File.open(log_path, 'a') { |f| f.puts "#{job.id}\t#{job.name}\t#{job.dir}\t#{status.exitstatus}\t#{elapsed.round(2)}" }
        puts "#{prefix} exit=#{status.exitstatus} time=#{elapsed.round(2)}s"
        results << Result.new(job: job, status: status, duration: elapsed)
      end
    end
  end
end

workers.each(&:join)

puts "\n=== Deployment summary ==="
results.sort_by! { |r| r.job.id }
results.each do |r|
  ok = r.status.success?
  state = ok ? 'OK' : 'FAIL'
  color = ok ? "\e[32m" : "\e[31m"
  reset = "\e[0m"
  name = r.job.rel_dir.empty? ? r.job.name : "#{r.job.rel_dir}/#{r.job.name}"
  puts format("%-6s %-48s %s%-6s%s %7.2fs", "[#{r.job.id}]", name, color, state, reset, r.duration)
end

failures = results.reject { |r| r.status.success? }
complete = results.size == jobs.size
warn "Incomplete batch: #{results.size}/#{jobs.size} jobs recorded" unless complete
puts "Completed #{results.size}/#{jobs.size} jobs; #{failures.size} failed"
exit(complete && failures.empty? ? 0 : 1)
