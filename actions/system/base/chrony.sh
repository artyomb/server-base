#!/bin/bash
set -eu

wait_for_sync() {
  local tries=$1
  timeout -k 1 "$((tries + 4))" chronyc -n waitsync "$tries" 0 0 1 >/dev/null 2>&1
}

show_sources() {
  timeout -k 1 5 chronyc -n sources >&2 || true
}

if [ "$1" = check ]; then
  if ! (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony); then
    echo inactive
  elif wait_for_sync 1; then
    echo synchronized
  else
    show_sources
    echo unsynchronized
  fi
  exit 0
fi

[ "$1" = apply ] || { echo "Expected check or apply" >&2; exit 1; }
shift
conf=/etc/chrony.conf
[ ! -f /etc/chrony/chrony.conf ] || conf=/etc/chrony/chrony.conf
configure_sources() {
  local marker=$1
  shift
  [ "$#" -gt 0 ] || return 0
  local begin="# BEGIN $marker" end="# END $marker"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$conf" > "$tmp"
  {
    echo "$begin"
    printf 'server %s iburst\n' "$@"
    echo "$end"
  } >> "$tmp"
  cat "$tmp" > "$conf"
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
configure_sources 'BASE NTP SERVERS' "$@"
if systemctl enable chronyd >/dev/null 2>&1; then
  service=chronyd
else
  systemctl enable chrony >/dev/null
  service=chrony
fi

wait_after_restart() {
  timeout -k 1 5 chronyc burst 4/4 >/dev/null 2>&1 || true
  wait_for_sync 60
}

systemctl restart "$service"
if ! wait_after_restart; then
  echo "[base] chrony did not synchronize, trying fallback NTP servers"
  configure_sources 'BASE FALLBACK NTP SERVERS' \
    0.ru.pool.ntp.org 1.ru.pool.ntp.org 2.ru.pool.ntp.org 3.ru.pool.ntp.org \
    ntp.sashenki.ru vniiftri.khv.ru time.cloudflare.com time.google.com \
    0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
  systemctl restart "$service"
  wait_after_restart || {
    echo "[base] chrony did not synchronize with configured or fallback sources" >&2
    show_sources
    exit 1
  }
fi
