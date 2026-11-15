Action :nats, depends: [:swarm] do
  apply do |_params|
    previous_umask = File.umask(0o077)
    begin
      deploy_drs('nats.drs')
    ensure
      File.umask(previous_umask)
    end
  end
end
