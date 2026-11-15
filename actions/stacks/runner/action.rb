Action :runner do
  apply do |params|
    node_id = capture("docker info --format '{{.Swarm.NodeID}}'").strip
    raise 'Runner requires an active Swarm node' if node_id.empty?

    env = {
      'MAIN_DOMAIN' => config.main_domain,
      'TLS_DOMAIN' => config.tls_domain,
      'GITLAB_RUNNER_NODE_ID' => node_id
    }.compact

    deploy_drs('runner.drs', env)
  end
end
