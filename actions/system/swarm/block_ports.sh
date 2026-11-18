#!/bin/sh
set -eu

# Keep Loki and Swarm internals reachable locally and over private interfaces.
# Explicit peer addresses may share a default-route interface; Loki stays blocked.
# Match the original port because Docker DNAT runs before the filter chains.
trusted_peers=''
mode=${1:---apply}
case "$mode" in --apply|--check) ;; *) echo 'Usage: swarm-block-ports [--apply|--check]' >&2; exit 2 ;; esac
interfaces=${EXT_IF:-$(ip -o -4 route show default; ip -o -6 route show default)}
if [ -z "${EXT_IF:-}" ]; then
  interfaces=$(printf '%s\n' "$interfaces" | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1)}' | sort -u)
fi
[ -n "$interfaces" ] || { echo 'Cannot detect external interfaces' >&2; exit 1; }

protect_chain() {
  parent=$1
  chain=$2
  match=$3
  if [ "$mode" = '--apply' ]; then
    "$ipt" -w -N "$chain" 2>/dev/null || true
    "$ipt" -w -F "$chain"
  fi
  operation=-A
  [ "$mode" != '--check' ] || operation=-C
  count=0
  if [ "$match" = direct ]; then
    for interface in $interfaces; do
      for peer in $trusted_peers; do
        case "$peer" in *:*) family=ip6tables ;; *) family=iptables ;; esac
        [ "$ipt" = "$family" ] || continue
        "$ipt" -w "$operation" "$chain" -i "$interface" -s "$peer" -p tcp -m multiport --dports 2377,7946 -j RETURN
        "$ipt" -w "$operation" "$chain" -i "$interface" -s "$peer" -p udp -m multiport --dports 7946,4789 -j RETURN
        count=$((count + 2))
      done
    done
  fi
  peer_count=$count
  for interface in $interfaces; do
    if [ "$match" = original ]; then
      "$ipt" -w "$operation" "$chain" -i "$interface" -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 3100 -j REJECT --reject-with tcp-reset
      count=$((count + 1))
    else
      for port in 3100 2377 7946; do
        "$ipt" -w "$operation" "$chain" -i "$interface" -p tcp --dport "$port" -j REJECT --reject-with tcp-reset
        count=$((count + 1))
      done
      for port in 7946 4789; do
        # REJECT defaults to the port-unreachable response for this IP family.
        "$ipt" -w "$operation" "$chain" -i "$interface" -p udp --dport "$port" -j REJECT
        count=$((count + 1))
      done
    fi
  done
  "$ipt" -w "$operation" "$chain" -j RETURN
  if [ "$mode" = '--apply' ]; then
    while "$ipt" -w -D "$parent" -j "$chain" 2>/dev/null; do :; done
    "$ipt" -w -I "$parent" 1 -j "$chain"
  else
    [ "$("$ipt" -w -S "$chain" | wc -l)" -eq "$((count + 2))" ]
    # Peer exceptions precede all rejections; the unconditional return must be last.
    "$ipt" -w -S "$chain" | awk -v n="$peer_count" -v chain="$chain" '
      NR > 1 && NR <= n+1 && / -j RETURN$/ { peers++ }
      { last = $0 }
      END { exit !(peers+0 == n && last == "-A " chain " -j RETURN") }'
    [ "$("$ipt" -w -S "$parent" | sed -n '2p')" = "-A $parent -j $chain" ]
    [ "$("$ipt" -w -S "$parent" | grep -Fxc -- "-A $parent -j $chain")" -eq 1 ]
  fi
}

for ipt in iptables ip6tables; do
  if [ "$ipt" = ip6tables ] && [ ! -e /proc/net/if_inet6 ]; then continue; fi
  "$ipt" -w -S INPUT >/dev/null
  parent=FORWARD
  if "$ipt" -w -S DOCKER-USER >/dev/null 2>&1; then parent=DOCKER-USER; fi
  protect_chain "$parent" SWARM-BLOCK-PUBLISHED original
  protect_chain INPUT SWARM-BLOCK-INPUT direct
done
