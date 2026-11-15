require 'shellwords'

Action :swarm, depends: [:docker] do
  loki_driver_version = '3.7.2'

  check do |_params|
    swarm_state = capture("docker info --format '{{.Swarm.LocalNodeState}}'").strip
    raise 'Docker returned an empty Swarm state' if swarm_state.empty?
    next false unless swarm_state == 'active'

    manager = capture("docker info --format '{{.Swarm.ControlAvailable}}'").strip
    raise 'Docker returned an invalid Swarm manager state' unless %w[true false].include?(manager)

    plugins = capture("docker plugin ls --format '{{.Name}} {{.Enabled}}'").lines.map(&:split)
    loki_enabled = plugins.any? { |name, enabled| %w[loki loki:latest].include?(name) && enabled == 'true' }
    networks_ok = if manager == 'true'
                    networks = capture("docker network ls --format '{{.Name}}'").lines.map(&:strip)
                    %w[ingress-routing grafana-network nats-network].all? { |name| networks.include?(name) }
                  else
                    true
                  end

    loki_enabled && networks_ok
  end

  apply do |params|
    join_token = nil
    manager_ip = params[:manager_ip]
    advertise_addr = params[:advertise_addr]
    # if manager_ip && !manager_ip.empty?
    #   join_token = `ssh -o StrictHostKeyChecking=no #{manager_ip} docker swarm join-token -q worker`.strip
    # end
    script = <<~SH
      set -euo pipefail

      pick_advertise_addr() {
        local given=#{Shellwords.escape(advertise_addr.to_s)}
        if [ -n "$given" ]; then
          echo "$given"
          return 0
        fi

        local ips private_ip
        ips="$(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 || true)"
        private_ip="$(printf '%s\n' "$ips" | awk '/^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.)/{print; exit}' || true)"
        if [ -n "$private_ip" ]; then
          echo "$private_ip"
          return 0
        fi

        printf '%s\n' "$ips" | head -n 1
      }

      swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
      case "$swarm_state" in
        active) echo "Swarm already active" ;;
        inactive) ;;
        *)
          echo "Swarm is not ready (state: $swarm_state); refusing to initialize" >&2
          exit 1
          ;;
      esac

      if [ "$swarm_state" = "inactive" ]; then
        if [ -n "#{join_token}" ]; then
          echo "Joining Swarm master: #{manager_ip}:2377"
          docker swarm join --token "#{join_token}" #{manager_ip}:2377
        else
          advertise_addr="$(pick_advertise_addr)"
          if [ -z "$advertise_addr" ]; then
            echo "Failed to auto-detect advertise address for swarm init" >&2
            exit 1
          fi
          echo "Initialize Swarm master"
          echo "Using advertise address: $advertise_addr"
          docker swarm init --advertise-addr "$advertise_addr"
        fi
      fi

      swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
      if [ "$swarm_state" != "active" ]; then
        echo "Swarm is not active after initialization (state: $swarm_state)" >&2
        exit 1
      fi
      manager="$(docker info --format '{{.Swarm.ControlAvailable}}')"
      case "$manager" in
        true|false) ;;
        *) echo "Invalid Swarm manager state: $manager" >&2; exit 1 ;;
      esac

      plugins="$(docker plugin ls --format '{{.Name}} {{.Enabled}}')"
      loki_enabled="$(awk '$1 == "loki" || $1 == "loki:latest" {print $2}' <<< "$plugins")"
      case "$loki_enabled" in
        true) echo "Grafana Loki Docker driver plugin is already enabled." ;;
        false)
          echo "Grafana Loki Docker driver plugin is disabled; enable it during a maintenance window" >&2
          exit 1
          ;;
        "")
          loki_driver_host_arch="$(uname -m)"
          case "$loki_driver_host_arch" in
            x86_64|amd64) loki_driver_arch="amd64" ;;
            aarch64|arm64) loki_driver_arch="arm64" ;;
            *) echo "Unsupported architecture for Grafana Loki Docker driver: $loki_driver_host_arch" >&2; exit 1 ;;
          esac
          docker plugin install "grafana/loki-docker-driver:#{loki_driver_version}-${loki_driver_arch}" --alias loki --grant-all-permissions
          ;;
        *) echo "Unexpected Loki plugin state: $loki_enabled" >&2; exit 1 ;;
      esac

      ensure_overlay_network() {
        local name="$1"
        if ! grep -Fxq -- "$name" <<< "$networks"; then
          echo "Creating $name network..."
          docker network create --driver overlay "$name"
        else
          echo "$name network already exists."
        fi
      }

      if [ "$manager" = "true" ]; then
        networks="$(docker network ls --format '{{.Name}}')"
        ensure_overlay_network ingress-routing
        ensure_overlay_network grafana-network
        ensure_overlay_network nats-network
      else
        echo "This is a worker node. Skipping network creation."
      fi
    SH
    remote(script)
  end
end
