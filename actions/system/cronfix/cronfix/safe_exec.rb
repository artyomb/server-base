require 'json'

# Every invocation owns a process group. Only this code reaps its direct child.
module SafeExec
  class Error < StandardError; end
  class TimeoutError < Error; end
  class OutputLimitError < Error; end
  class ExitError < Error; end
  class SerializationError < Error; end

  CommandResult = Struct.new(:stdout, :stderr, :status, :timed_out, :exception, keyword_init: true) do
    def success? = !timed_out && exception.nil? && status&.success?
    def exitstatus = status&.exitstatus
    alias out stdout
    alias err stderr
  end
  StepResult = Struct.new(:result, :exception, :timed_out, keyword_init: true) do
    def success? = exception.nil? && !timed_out
    def timed_out? = timed_out
  end

  def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def self.signal_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def self.stop_group(pid, grace: 0.1)
    Process.kill(0, -pid)
    signal_group('TERM', pid)
    sleep grace if grace.positive?
    # The leader may already have exited while a descendant still holds a pipe.
    signal_group('KILL', pid)
  rescue Errno::ESRCH
    nil
  end

  def self.collect(pid, readers, timeout:, max_output:, writer: nil, input: '')
    deadline = monotonic + timeout
    buffers = readers.to_h { |io| [io, ''.b] }
    open_readers = readers.dup
    status = nil
    error = nil
    offset = 0
    size = 0
    begin
      loop do
        unless status
          waited = Process.waitpid2(pid, Process::WNOHANG)
          status = waited[1] if waited
        end
        if writer && offset >= input.bytesize
          writer.close
          writer = nil
        end
        break if status && open_readers.empty?
        raise TimeoutError, 'Command timed out' if monotonic >= deadline

        ready = IO.select(open_readers, writer ? [writer] : [], nil, [deadline - monotonic, 0.05].min.clamp(0, 0.05))
        next unless ready

        ready[0].each do |io|
          chunk = io.read_nonblock(16_384, exception: false)
          if chunk.nil?
            open_readers.delete(io)
            io.close
          elsif chunk != :wait_readable
            size += chunk.bytesize
            if size > max_output
              buffers[io] << chunk.byteslice(0, max_output - size + chunk.bytesize)
              raise OutputLimitError, 'Command output limit exceeded'
            end

            buffers[io] << chunk
          end
        end
        if writer && ready[1].include?(writer)
          begin
            written = writer.write_nonblock(input.byteslice(offset, 16_384), exception: false)
            offset += written if written.is_a?(Integer)
          rescue Errno::EPIPE
            writer.close
            writer = nil
          end
        end
      end
    rescue StandardError => e
      error = e
    ensure
      # If an outer supervisor terminates us, finish our child cleanup before its
      # KILL grace expires. Also clean descendants after a normal leader exit.
      stop_group(pid, grace: $!.is_a?(SignalException) ? 0 : 0.1)
      Process.waitpid2(pid).tap { |pair| status = pair[1] } unless status
      (readers + [writer]).compact.each { |io| io.close unless io.closed? }
    end
    [buffers.values, status, error]
  end

  def self.capture(*argv, timeout: 20, max_output: 4 * 1024 * 1024, stdin_data: '', env: {})
    raise ArgumentError, 'Use an argv array, not a shell command' if argv.empty? || argv.any? { |v| !v.is_a?(String) }

    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    in_r, in_w = IO.pipe
    pid = Process.spawn({ 'LC_ALL' => 'C' }.merge(env), [argv.first, argv.first], *argv.drop(1), in: in_r, out: out_w, err: err_w, pgroup: true)
    [out_w, err_w, in_r].each(&:close)
    output, status, error = collect(pid, [out_r, err_r], timeout: timeout, max_output: max_output, writer: in_w, input: stdin_data.b)
    CommandResult.new(stdout: output[0], stderr: output[1], status: status, timed_out: error.is_a?(TimeoutError), exception: error)
  rescue StandardError => e
    CommandResult.new(stdout: '', stderr: '', timed_out: false, exception: e)
  ensure
    [out_r, out_w, err_r, err_w, in_r, in_w].compact.each { |io| io.close unless io.closed? }
  end

  def self.call_result(timeout: 20, max_output: 4 * 1024 * 1024, &block)
    reader, writer = IO.pipe
    pid = fork do
      Process.setpgrp
      reader.close
      begin
        Marshal.dump({ result: block.call }, writer)
      rescue Exception => e # Serialize failures from this isolated child, never execute repairs.
        Marshal.dump({ error: "#{e.class}: #{e.message}" }, writer) rescue nil
      ensure
        writer.close
      end
      exit! 0
    end
    # Close the race before a very short deadline: either parent or child sets the group.
    begin
      Process.setpgid(pid, pid)
    rescue Errno::EACCES, Errno::ESRCH
      nil
    end
    writer.close
    output, status, error = collect(pid, [reader], timeout: timeout, max_output: max_output)
    unless error
      data = Marshal.load(output.first) # Only the locally forked block writes this private pipe.
      error = SerializationError.new(data[:error]) if data[:error]
      error ||= ExitError.new('Child failed') unless status.success?
    end
    StepResult.new(result: data && data[:result], exception: error, timed_out: error.is_a?(TimeoutError))
  rescue StandardError => e
    StepResult.new(exception: e, timed_out: e.is_a?(TimeoutError))
  ensure
    [reader, writer].compact.each { |io| io.close unless io.closed? }
  end

  def self.call(**options, &block)
    result = call_result(**options, &block)
    raise result.exception unless result.success?

    result.result
  end
end
