# Server Base

Small Ruby deployment tool for provisioning a Docker Swarm host over SSH and
deploying a basic public infrastructure stack.

Included actions:

- `swarm`
- `traefik`
- `oauth2_slim`
- `insight`
- `grafana`
- `nats` (optional messaging, JetStream and OAuth-protected NUI)
- `registry_listener`
- `runner`
- `cronfix` (optional scheduled diagnostics)

The runtime also includes the default/dependency actions needed by those
install steps: `base`, `docker`, `docker_resolved`, and `system_check`.

## Requirements

- Ruby 3.1.2 or newer and Bundler
- root SSH access to the target server
- Docker-capable Ubuntu or RED OS target
- `dry-stack` 0.1.64 or a newer 0.1.x release, installed through Bundler

Install dependencies:

```sh
bundle install
```

## Configure and Deploy a Server

Keep real server definitions and credentials outside the public checkout. Create
`demo.rb` in a private directory, for example `../server-config/`:

```ruby
Server :demo do
  host ENV.fetch('DEPLOY_HOST')
  tls_domain ENV.fetch('DEPLOY_DOMAIN')

  install :swarm
  install :oauth2_slim
  install :traefik
  install :insight
  install :grafana
  install :registry_listener
end
```

Set `DEPLOY_HOST`, `DEPLOY_DOMAIN`, `GRAFANA_BASIC_AUTH`, `INSIGHT_BASIC_AUTH`, `GF_ADMIN_PASSWORD`,
and either `AUTH_USERS` or `AUTH_VERIFY_KEY` in the deployment environment before
running the command below. Use your own credentials; formats are described in
[Environment Variables](#environment-variables). The deployer inherits the process
environment and does not automatically load `.env` files.

```sh
ruby bin/deploy --servers-dir ../server-config --server demo
```

The main SSH session takes an exclusive `flock` on
`/run/server-base-deploy.lock` before it reads the host's preflight data.
A competing deployment to the same host fails before preflight, even from
another runner. Different hosts can deploy in parallel. During rollout, let
deployments using the previous version finish before starting the first
protected run.

The deployer runs SSH preflight checks, resolves
action dependencies, and applies host actions whose checks report missing or
outdated configuration. Stack actions run on every deployment; removed services
can be pruned. Keep `swarm` before stacks that need its networks.

The bundled [demo definition](config/servers.demo/demo.rb) is a template, not a
ready deployment. It contains placeholders, optional runner settings, and a
`docker_login` action that is not included in this repository. Remove that action
and configure or remove the runner before using the bundled file.

For definitions under `config/servers` or `config/servers.*`, an interactive picker
is also available. Exclude private configuration directories from Git locally.

```sh
ruby bin/deploy-menu
```

## Batch Deployment

Deploy every server definition in a private directory, or select one by filename:

```sh
JOBS=2 JOB_TIMEOUT=300 ruby run-all.rb ../server-config
ruby run-all.rb ../server-config demo
```

`JOBS` and `JOB_TIMEOUT` must be positive integers. They default to the local CPU
count and 300 seconds per server. Jobs run without interactive input. Each job
gets its own local process group; on timeout, the runner sends TERM, waits one
second, then sends KILL to the group and waits for its direct child to exit.

Timed-out jobs are recorded as status 124 in `parallel.log`. Other queued jobs
continue, and the final summary includes completed and failed job counts. The
batch exits unsuccessfully if any job fails or a result is missing.

The server releases the lock when the main SSH session's input closes,
including when the runner exits during an action. After a silent network
failure, release depends on when SSH closes the channel. The client checks
the main session's exit status at the end of the deployment.
The lock file can remain in `/run` between deployments. Leave it in place.
The SSH agent and a persistent SSH master can stay up between jobs. Separate
commands started by exec, rsync or dry-stack may finish after the session ends.

## CI/CD

The [GitLab pipeline](.gitlab-ci.yml) builds a deployment image and runs it on a
Docker-capable runner tagged `swarm`. Configure `SSH_PRIVATE_KEY` for the deployment
job and supply your private server definitions through your CI secret-management
process.

The default job reads `config/servers`, which is not supplied in this public
checkout. The manual job is named `deploy-demo`; its current `DEPLOY_ARGS` is
`config/servers demo`. Set the arguments to the directory and filename you supply.

The job's `ci.env` filter forwards only `CI_*`, `DEBUG`, `JOBS`, and `JOB_TIMEOUT`.
Explicitly pass the required stack settings into the deployment container; setting
`AUTH_USERS` or `GRAFANA_BASIC_AUTH` as CI variables alone does not forward them.

The local [Docker deployment helper](test-deploy-dockerfile.sh) builds and **runs**
the same deployment image. It changes configured servers and is not an offline
smoke test. It uses the same environment filter and requires a usable SSH key.

## Local Validation

These checks do not connect to a server:

```sh
git diff --check
ruby -c lib/deploy.rb
bash -n actions/system/docker/install-docker-static.sh
ruby -Ilib -rdeploy -e 'r = Deploy::Actions::Registry.new; Deploy::Actions::Loader.new("actions", r).load_all; puts r.names.sort'
```

Syntax and action-loading checks do not prove that a generated stack will start
or that authentication and networking work on the target.

With Minitest installed, run the local regression tests after `bundle install`:

```sh
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require_relative file }'
```

These tests use temporary files and fake commands for Docker, journals and
notifications; they do not deploy or contact a server.

## Environment Variables

- `GF_ADMIN_USER` / `GF_ADMIN_PASSWORD`: Grafana bootstrap admin credentials
  (defaults: `admin` / `admin`). They are passed as Grafana's
  `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`; set your own password
  before deployment. They do not reset users in an existing Grafana database.
  Normal access uses OAuth2 Slim; Grafana's own login form and BasicAuth are disabled.
- `GRAFANA_BASIC_AUTH`: credentials for the Tempo, VictoriaMetrics and Loki
  diagnostic routes, in `user:password[:salt]` format. Falls back to
  `TRAEFIK_BASIC_AUTH`; one of these settings is required for Grafana. Use a stable salt
  to keep generated labels reproducible.
- `INSIGHT_BASIC_AUTH`: Insight credentials in `user:password[:salt]` format.
  Falls back to `TRAEFIK_BASIC_AUTH`, then a demo account. Supply your own value
  when deploying Insight.
- `TRAEFIK_BASIC_AUTH`: shared fallback for `GRAFANA_BASIC_AUTH` and
  `INSIGHT_BASIC_AUTH`. Traefik's dashboard uses OAuth2 Slim and does not use this setting.
- `TRAEFIK_POSTGRES_PORT`: optional published PostgreSQL TCP port (1–65535),
  independent of TLS; unpublished when unset. Set it explicitly only when a
  dedicated PostgreSQL port is needed. PostgreSQL over port 443 requires
  a TCP SNI route to a database service and a client using TLS with SNI;
  removing this setting does not create that route.
- `TRAEFIK_HTTP_PORT` / `TRAEFIK_HTTPS_PORT`: published ingress ports, default
  80 / 443. HTTPS publishes both TCP and UDP; HTTP/3 advertises this HTTPS port.
- `ACME_EMAIL`: ACME registration email when TLS is enabled.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`: optional registry listener and
  Grafana alert notifications.
- `AUTH_USERS`: OAuth2 Slim users YAML. Supply a `users` array of login mappings
  with nonempty string passwords for enabled users, for example
  `users: [{operator: {enabled: true, password: "<your-password>"}}]` with your own
  password. There is no default OAuth user.
- `AUTH_VERIFY_KEY`: optional 32-byte Ed25519 public key encoded as 64 hexadecimal
  characters. OAuth requires `AUTH_USERS` or this key; `AUTH_BOT` is optional with
  the key. No bot or signing settings are supplied automatically.
- `OIDC_CLIENT_SECRET` / `OIDC_ISSUER`: optional OpenID Connect settings. A configured
  issuer requires a nonempty secret; with a secret alone, the issuer is derived
  from `SCHEME`, `MAIN_DOMAIN` and `/oauth_slim`. Grafana uses ForwardAuth without
  a second login; native Grafana OAuth is not enabled.
- `VLLM_DASHBOARD_ENABLED=true`: provision the optional vLLM dashboard when vLLM
  metrics are already available through the Prometheus datasource. It creates no
  vLLM service or exporter; existing `GPU_NODE` behavior is unchanged.
- `NATS_TOKEN`: required private token when deploying `nats`; at least 32 URL-safe
  characters. Resource budgets and connection details are documented in the
  [NATS stack guide](actions/stacks/nats/README.md).

Do not commit real server IPs, credentials, generated dry-stack config files, or
local `.env` files to a public repository.

## Operational Notes

Docker setup preserves an existing client configuration. Swarm setup creates the
shared overlay networks on managers. An inactive host with `manager_ip` in its
profile stops before initialization. Join it to the existing cluster with a
worker token from its manager, then rerun deployment. An inactive host without
that setting initializes its own Swarm.
An enabled `loki:latest` alias satisfies stack logging; its driver version is
retained. Custom aliases are preserved but do not replace this default alias.
A disabled default alias requires manual attention. See the PostgreSQL port
setting above when updating an existing ingress.

Swarm setup installs `swarm-block-ports.service` to reject traffic arriving on
default-route interfaces, for IPv4 and IPv6: Loki's published TCP port 3100,
Swarm host TCP ports 2377/7946, and UDP ports 7946/4789. Local host log drivers
retain access. If peers use a default-route interface, list the other nodes'
individual IP addresses on each host, e.g. `install :swarm, trusted_peers: ['192.0.2.10']`.
The default list is empty. Check the route to each peer in both directions.
The exceptions cover only the four Swarm port/protocol combinations above.
Loki stays blocked on those interfaces, including for trusted peers.
The rules are checked on each deployment and reapplied after Docker restarts
and reboots. Use `install :swarm, block_ports: false`
only when equivalent filtering is managed elsewhere; this skips management and
does not remove existing rules. Loki logging uses the driver's default batch size.

When recovering a worker, check Docker's Swarm error, the node certificate's
expiry, both Docker Engine versions and connectivity to the original manager.
A missing ALPN negotiation during a join can indicate incompatible engines.
Keep compatibility overrides and any required host routes in the affected site's
configuration. Verify the manager sees the worker as Ready and that containers
on different nodes can reach each other over an overlay.

Base checks time synchronization with a bounded `chronyc waitsync`. If public
NTP is unreachable, configure `install :base, ntp_servers: ['ntp.example.org']`
in the host profile. Base compares the configured list with the `BASE NTP SERVERS`
block, even when the old source is unreachable. If all other host checks pass,
Base repairs only chrony. Before replacing a managed block, it records a pending
restart. A later deployment retries an interrupted update even if the clock
still reports synchronization with the old source. After a successful restart
and synchronization, Base records the explicit source list in `sources-verified`.
A missing, empty or mismatched record triggers one restart to load the requested
list from disk. The next deployment with the same list skips the action if the
host is healthy. An omitted or empty list leaves existing source configuration
under the operator's control.
A timeout causes readiness to fail. During repair, Base
tries the configured sources and then the fallback sources, reporting
`chronyc -n sources` if synchronization still fails.

The runner action places GitLab Runner and its SSH agent on the deployment node.
Job containers mount the agent's named socket volume at `/run/ssh-agent` read-only;
`CI_SSH_AUTH_SOCK` points to its `proxy-socket`. Direct DRS rendering requires
`GITLAB_RUNNER_NODE_ID`; the action obtains it automatically from Docker.

Grafana is available at `/map/grafana/` behind OAuth2 Slim ForwardAuth, with no
second login. Users admitted by OAuth share organization Admin access in
`Main Org.`; Grafana does not distinguish their OAuth identities. Its internal
anonymous access is enabled, so keep port 3000 unpublished and route external
access through the protected ingress. Keep its existing data volumes and the OAuth
signing-key volume across updates. Telegram contact points
require both notification settings; configure Grafana notification routing
separately. The optional vLLM dashboard requires an existing metrics source.

Grafana stores its database and local data in the `grafana_data` volume. When
upgrading an existing deployment without that mount, back up and migrate
`/var/lib/grafana` into the volume before redeploying; an empty volume starts with
a new database.

Open `/traefik/dashboard/` on the main domain for Traefik's dashboard. With DNS
configured for `traefik.<your-domain>`, `/dashboard/` on that hostname also works.
Both dashboard and API routes require OAuth2 Slim login; deploy `oauth2_slim` on
the shared ingress network before using them. The dashboard uses `api@internal`
and does not expose an unauthenticated port 8080 listener.
Its path and hostname routes use dry-stack's native `mount`, `target_prefix`,
`redirect_root`, and `service` options, with OAuth before redirects and rewriting.

Optional inode, kernel OOM and Swarm replica diagnostics:
[cronfix configuration and behavior](actions/system/cronfix/README.md).
The action is opt-in and does not enable itself in existing server definitions.

Optional NATS messaging and JetStream storage are available through `install :nats`.
NUI is served at `/map/nats/` behind OAuth2 Slim; admitted users share NATS
management access. The stack uses bounded resource budgets and persistent volumes,
with client access restricted to the internal overlay network. See the
[NATS stack guide](actions/stacks/nats/README.md).
