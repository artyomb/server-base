Server :server_ru do
  host 'x.x.x.x'
  tls_domain 'x.com'

  install :swarm
  install :traefik
  install :oauth2_slim #, users:{ admin { ....} }
  install :insight
  install :grafana #, env: { GPU_NODE: true }
  # install :nats, env: { NATS_TOKEN: ENV.fetch('NATS_TOKEN') }
  install :registry_listener
  install :runner, env: {
    GITLAB_RUNNER_NAME: 'build_deploy',
    GITLAB_RUNNER_URL: 'https://gitlab....',
    GITLAB_RUNNER_TOKEN: 'glrt-...',
    REGISTRY_HOST: 'reg...'
  }
  # better avoid the local login and use swarm deploy with registry auth, also swarmkit to monitor and update the credentials
  install :docker_login, credentials: 'login:passwd@reg...'
end
