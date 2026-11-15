require 'json'
require 'shellwords'
require_relative 'cronfix/bundle'

Action :cronfix do
  local_dir = File.expand_path('cronfix', __dir__)
  prepare = lambda do |context, params, mode|
    settings = JSON.parse(JSON.generate(params.fetch(:settings, {})))
    settings['telegram_credentials'] = params[:telegram_credentials] if params.key?(:telegram_credentials)
    package = Cronfix::Bundle.package(local_dir, settings)
    root = params.fetch(:install_root, '/opt/cronfix')
    # Validate locally before creating a remote staging directory.
    Cronfix::Bundle.new(root, package)
    stage = context.capture('umask 077; mktemp -d /tmp/server-base-cronfix.XXXXXXXX').strip
    raise 'Unexpected staging path' unless stage.match?(%r{\A/tmp/server-base-cronfix\.[A-Za-z0-9]+\z})

    begin
      %w[bundle.rb config.rb safe_exec.rb install.sh].each do |name|
        context.write_file("#{stage}/#{name}", File.read(File.join(local_dir, name)))
      end
      # write_file uses a quoted heredoc; set +x prevents secrets in debug SSH output.
      payload = JSON.generate(package)
      context.remote("set +x\numask 077\ncat > #{stage}/package.json <<'CRONFIX_PACKAGE_JSON'\n#{payload}\nCRONFIX_PACKAGE_JSON\n")
      command = "bash #{Shellwords.escape(stage)}/install.sh #{mode} #{Shellwords.escape(root)} #{stage}/package.json"
      if mode == 'check'
        output = context.capture("#{command}; result=$?; [ \"$result\" -le 1 ] || exit \"$result\"")
        output.strip == 'ready'
      else
        context.exec(command)
        true
      end
    ensure
      context.exec("rm -rf -- #{Shellwords.escape(stage)}")
    end
  end

  check { |params| prepare.call(self, params, 'check') }
  apply { |params| prepare.call(self, params, 'install') }
end
