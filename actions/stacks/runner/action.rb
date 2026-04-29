Action :runner do
  apply do |params|
    env = {
      'MAIN_DOMAIN' => config.main_domain,
      'TLS_DOMAIN' => config.tls_domain
    }.compact

    deploy_drs('runner.drs', env)
  end
end
