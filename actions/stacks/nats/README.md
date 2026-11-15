# NATS

This optional stack adapts Base's NATS services into three containers:

- NATS 2.15.3 with JetStream and persistent `nats_data` storage.
- Prometheus NATS exporter 0.20.3 for the existing Grafana scrape target.
- NUI 0.10.0 at `/map/nats/`, protected by OAuth2 Slim.

## Deployment

Add this to a private server definition after Swarm, OAuth and Traefik:

```ruby
install :nats, env: { NATS_TOKEN: ENV.fetch('NATS_TOKEN') }
```

Generate a token once, save it in private configuration, and reuse it on subsequent
deployments. `NATS_TOKEN` must contain at least 32 letters, digits, underscores or
hyphens. There is no default credential. Generated dry-stack files contain the
private NUI connection context; the action creates them with a private umask.
Keep these files and rendered Compose output out of public commits and logs.

The action depends on `swarm`, which creates the shared overlay networks. OAuth2
Slim and Traefik must already be deployed for the web interface. Grafana is
optional; its existing `prometheus_nats_exporter:7777` scrape and NATS dashboards
work without another scrape job or a separate monitoring deployment.

## Access and persistence

Applications on `nats-network` connect to `nats://nats_nats_single:4222` using the
token. Client, monitoring, exporter and UI ports are not published on the host.
The stack's internal network carries monitoring traffic; the exporter also joins
`grafana-network`, and NUI joins `ingress-routing` for OAuth-protected access.
There is no external NATS WebSocket or cluster listener.

Open `/map/nats/` on the deployment's main domain. The slashless URL redirects
after authentication. NUI imports the `server` connection at startup and keeps its
database in `nats_nui_db`. It requires no second login. Users admitted by OAuth
share management access, including creating/deleting streams and viewing the
connection credential. Keep the ingress and internal networks trusted.

This is a single-server JetStream deployment, not a replicated cluster. Its local
data volume must stay with the server. Before adding more Swarm managers, pin the
service to the node holding the volume or migrate the data deliberately; a fresh
volume on another manager does not preserve messages. Back up `nats_data` and
`nats_nui_db` before storage migrations.

## Resource budgets

| Setting | Default | Meaning |
| --- | --- | --- |
| `NATS_MEMORY_MIB` | `512` | NATS container RAM limit; minimum 128 MiB |
| `NATS_CPU_LIMIT` | `1.0` | NATS CPU limit in cores |
| `NATS_JS_MEMORY_MIB` | `128` | JetStream memory store; at most half the RAM limit |
| `NATS_JS_FILE_MIB` | `2048` | JetStream file-store message limit; filesystem overhead is additional |

NATS also limits connections to 1024, message payloads to 1 MiB and pending output
per connection to 8 MiB. The exporter is limited to 128 MiB / 0.25 CPU and NUI to
256 MiB / 0.5 CPU. These are ceilings, not reserved resources. Go memory targets
leave headroom below the container limits. Each service rotates its JSON logs at
10 MiB with three files.

Set stream-specific retention (`max_age`, `max_bytes`, `max_msgs`) for each
workload. Server storage ceilings prevent unlimited message storage but do not
define how long messages should be retained. Budget changes require measurements
under the expected load; idle usage alone does not establish production capacity.

The exporter collects server health and JetStream consumer metrics needed by the
existing dashboards. It omits the per-connection, subscription, cluster, gateway
and leaf-node collectors from Base's broader stack. Base's idle toolbox, Ruby
evaluation worker and overlapping web interfaces are not included.

## Validation

`ruby test/nats_stack_test.rb` renders through dry-stack and validates with
`docker stack config`; it checks OAuth routing, resource overrides, private
generation, required credentials, persistence mounts and unpublished ports.
Docker CLI and the project's bundled gems must be installed; no daemon or remote
server is contacted by these tests.

After deployment, check service convergence, authenticated pub/sub, JetStream
write/read persistence, Grafana metrics, and NUI's assets/API/WebSocket under
`/map/nats/`. Confirm anonymous UI/API access requires OAuth and repeat deployment
to verify that credentials, connection identity and stored data remain stable.
