require 'json'
require 'socket'
require_relative 'safe_exec'

module Cronfix
  class Notifier
    def initialize(config, endpoint: nil)
      @config = config
      @endpoint = endpoint
    end

    def deliver(message, timeout: 20)
      credentials = @config['telegram_credentials']
      return false unless credentials

      chat_id, bot_id, token = credentials.split(':', 3)
      url = @endpoint || "https://api.telegram.org/bot#{bot_id}:#{token}/sendMessage"
      text = "#{Socket.gethostname}: #{message}".encode('UTF-8', invalid: :replace, undef: :replace)[0, 3500]
      payload = JSON.generate(chat_id: chat_id, text: text)
      # curl config is supplied over stdin: neither token nor message enters argv.
      escape = lambda do |string|
        string.gsub(/["\\\n\r]/) { |character| { '"' => '\\"', '\\' => '\\\\', "\n" => '\\n', "\r" => '\\r' }.fetch(character) }
      end
      input = "url = \"#{escape.call(url)}\"\nheader = \"Content-Type: application/json\"\ndata = \"#{escape.call(payload)}\"\n"
      result = SafeExec.capture('curl', '-q', '--silent', '--show-error', '--fail',
                                '--connect-timeout', [10, timeout].min.to_s, '--max-time', timeout.to_s,
                                '--config', '-', stdin_data: input, timeout: timeout + 0.2, max_output: 65_536)
      result.success? && JSON.parse(result.stdout)['ok'] == true
    rescue StandardError
      # Transport errors can contain the credential-bearing URL; never log them.
      false
    end
  end
end
