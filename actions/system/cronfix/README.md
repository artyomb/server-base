# Cronfix diagnostics

Optional action, not a default install step. It transfers an explicit ten-file
bundle and runs three sequential, read-only diagnostics. No fix callback, cleanup,
restart, pruning, version policy or incident snapshot is included.

## Configuration and future installation

Add the action to a server definition only when you intend to enable its schedule:

~~~ruby
install :cronfix,
  telegram_credentials: ENV.fetch('CRONFIX_TELEGRAM_CREDENTIALS'),
  settings: {
    tasks: %w[inode_usage oom_checker swarm_service_replicas],
    interval_minutes: 5,
    inode_paths: ['/'],
    inode_docker_root: true,
    inode_percent: 90,
    swarm_grace_seconds: 300
  }
~~~

Credentials are `chat_id:bot_id:token`; supply your own recipient and bot.
They are independent of Grafana/registry listener notification settings.
There is no built-in recipient/token. No host settings are imported from Base.

Default install root is `/opt/cronfix`, overridable by `install_root`. Use an
absolute normalized path containing letters, digits, `_`, `.`, `-`, `/` only.
One marked cron entry per host is managed. Multiple independent instances are
not supported. The normal project deploy command processes **all** configured
actions and its existing preflight; it is not a read-only cronfix test.
Review the server definition before a future operator-run deploy.

Target prerequisites: Linux, Bash, Ruby **3.1+** with its standard libraries,
`curl`, `crontab`, util-linux `flock`, an active systemd `cron` or `crond`, and selected diagnostic
commands (`df`, `journalctl`, Docker CLI). No additional gems are required.
The installer checks commands/Ruby/scheduler and pins the resolved Ruby executable
for cron; it does not install packages or enable the scheduler. Use a Ruby
available to noninteractive SSH. No profiles are sourced. Root SSH is the existing
action mechanism. Journal and Docker access must work under the cron account;
service checks require an active manager.
The wrapper adds `/usr/local/bin` when missing from cron's PATH so it can find
the static Docker client. The deployment client's `base64` dependency is
installed through the root Gemfile; it is not needed by the target diagnostics.

All runtime settings live in `config.json` (0600):

| Setting | Default | Meaning/source |
|---|---|---|
| `tasks` | the three names above | Explicit allowlist; nonempty subset, no duplicates |
| `interval_minutes` | `5` | Base interval, cron `*/N` minute field, integer 1–59 |
| `inode_paths` | `['/']` | Base root check, additional absolute paths supported |
| `inode_docker_root` | `true` | Adaptation: discover Docker data-root every run |
| `inode_percent` | `90` | Base threshold, inclusive; integer 1–100 |
| `oom_initial_minutes` | `10` | Base lookback, used once when creating OOM state |
| `oom_include_message` | `false` | Adaptation: send time only; opt in to sanitized 500-character kernel text |
| `swarm_grace_seconds` | `300` | Adaptation: continuous replica deficit before alerting |
| `command_timeout` | `20` | Adaptation: subprocess seconds |
| `run_timeout` | `240` | Adaptation: pass budget, reserves up to 20 seconds for notification |
| `max_output_bytes` | `4194304` | Adaptation: combined stdout/stderr cap per command |
| `telegram_credentials` | unset | Required to install a schedule |

These are code defaults, not confirmed production settings. A `*/7` cron schedule
runs at minutes 0,7,…,56 and then 0, not at exact seven-minute elapsed intervals.
Choose timing for actual workload/journal volume. Set `inode_docker_root: false`
explicitly to check only configured paths. Unsupported inode statistics and
unavailable Docker discovery yield unknown.

Precedence: defaults < existing `config.json` < explicitly supplied settings.
Existing unknown JSON keys and unrelated files are preserved; an unchanged valid
config is not rewritten. `.env` is never sourced/replaced. Unknown action settings
are rejected to catch spelling mistakes. After changing the interval, run the
action again to update the managed cron entry.

## Ownership and updates

The action sends only files listed in `cronfix/bundle.rb`. No directory glob or
arbitrary task is loaded. Check compares installed bytes/modes, the pinned Ruby
path, settings and the exact owned cron line. Apply repairs owned code drift while
preserving state, notes, settings not explicitly overridden and other cron entries.

`.manifest.json` records ownership. Conflicting files without ownership and
unmarked schedules pointing to this bundle are refused, not silently adopted.
Only lines ending with `# server-base-cronfix` are replaced/deduplicated. A crontab
read error aborts; only the standard “no crontab for USER” result means empty.
Symlinks in managed paths are refused. Installer and processor share a nonblocking
lock; wrapper acquires it before Ruby loads bundle files. Retry an update if a
diagnostic pass is running.

Keep `state/state.json` and the ownership record across upgrades. State holds
checkpoints, observations and an outbox; writes use atomic rename/fsync.
Corrupt state is not reset. Do not copy state between hosts. `last-run.log` (0600)
contains the latest scheduled invocation, including an invocation skipped due to
the lock. There is no retained log history or archive cleanup task.

## Diagnostic and delivery semantics

- Inodes: strict numeric `df -Pi` parsing and consistency checks. Resolve current
  mountpoints for configured paths and Docker data-root each pass; deduplicate
  identical mounts. Unsupported statistics are unknown.
- OOM: kernel journal only (`_TRANSPORT=kernel`), across retained boots. Persist
  the initial boundary before the first query, then advance a cursor. Include and
  verify the previous entry so a vacuumed cursor becomes unknown. Recognize
  out-of-memory, oom-kill and killed-process variants. An event is a **journal
  record** identified by its cursor; several records from one incident can produce
  several messages. There is no incident correlation.
  Each pass processes the complete JSON records within the command output cap,
  saves the last cursor with its events, and leaves the scan pending until caught
  up. An incomplete trailing record is retried on the next pass. Binary MESSAGE
  byte arrays are decoded with invalid UTF-8 replaced. Malformed records, command
  timeouts and known nonzero exits leave the previous checkpoint unchanged.
  A single record, or the previous cursor entry plus the next record, must fit
  within the cap; otherwise the check becomes unknown without skipping records.
  Review oversized journal data or raise `max_output_bytes` to restore progress.
- Swarm: workers are explicitly not applicable; inactive/pending/invalid/API-error
  states are unknown. Check partial deficits as well as zero replicas. Accept
  scale-to-zero, zero eligible global tasks and completed jobs. Finite replicated
  services with `on-failure`/`none` need every current slot running or successfully
  complete with the current task specification; one historical success cannot
  hide failed slots. Rolling updates get bounded convergence grace, not indefinite
  exemption. This is a replica diagnostic, not application readiness or a full
  update-status monitor.
- Problems/unknowns notify on transitions, not every pass. Recovery is separate.
  Pending/not-applicable cannot erase unresolved alerts. A successful complete
  inventory explicitly retires missing resources as no longer present.
- Events and checkpoints are durable **before** delivery. Failure keeps an event
  queued even if the condition recovers. A later pass retries queued events in
  order; only HTTP success and Telegram JSON `ok: true` remove one. Messages are
  plain text, JSON escaped. Credentials/payload go to curl over stdin, never argv;
  action shell tracing is disabled around credential transfer.

A lost acknowledgement or crash after successful send but before local save can
cause a duplicate: this is not an exactly-once transport. The outbox is not
discarded/capped; watch free space during prolonged delivery failure. Missing
state, lost journal retention and host downtime cannot be repaired by a monitor.
For a lost cursor, preserve state/outbox, investigate the gap, then deliberately
reanchor only `checkpoints.oom_checker` to a reviewed `since` epoch or retained
cursor. Automatic moving-window fallback would silently lose evidence.

Commands own process groups, drain pipes concurrently and enforce output/time
limits with TERM/KILL cleanup, including descendants retaining pipes. Diagnostics
call commands directly with the shared pass deadline; they do not nest supervisors
or launch detached daemons. The forked-block SafeExec helper is retained for
bounded local Ruby work.

Exit 0: no unresolved problem/unknown or pending delivery (individual checks can
still be pending/not applicable). Exit 1: diagnostic/delivery attention. Exit 2:
startup/state/config error. Inspect states as well as the exit code.

## Local verification

From the repository root, with Minitest installed, run:

```sh
ruby test/cronfix_runtime_test.rb
ruby test/cronfix_oom_test.rb
```

These regression tests use fake journal processes and notification recorders to
check backlog progress, binary messages, cursor continuity, retry and timeout
behavior, cron PATH, and Bundler action loading. They do not contact a server.

The earlier task's `outputs/cronfix-implementation/verify.rb` tests actual source, the existing
action loader, fixture filesystem/crontab and fake commands. Only the transport
test uses real curl, against a local fake HTTP endpoint. No host schedule, real
journal, Docker data or servers are used.
Tested runtimes: system Ruby 3.3.8 and project Ruby 3.4.4. The 3.1 minimum is
enforced, but Ruby 3.1 was not available for execution in this workspace.
