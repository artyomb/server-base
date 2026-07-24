Server :server_ru do
  host 'x.x.x.x'
  tls_domain 'x.com'

  install :swarm
  install :traefik
  install :oauth2_slim #, users:{ admin { ....} }
  install :insight
  install :grafana #, env: { GPU_NODE: true }
  install :registry_listener
  install :runner, env: {
    GITLAB_RUNNER_NAME: 'build_deploy',
    GITLAB_RUNNER_URL: 'https://gitlab....',
    GITLAB_RUNNER_TOKEN: 'glrt-...',
    REGISTRY_HOST: 'reg...'
  }
  install :docker_login, credentials: 'login:passwd@reg...'
end
