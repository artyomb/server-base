#!/bin/bash
set -eu

wait_for_sync() {
  local tries=$1
  timeout -k 1 "$((tries + 4))" chronyc -n waitsync "$tries" 0 0 1 >/dev/null 2>&1
}

show_sources() {
  timeout -k 1 5 chronyc -n sources >&2 || true
}

mode=$1
shift
conf=/etc/chrony.conf
[ ! -f /etc/chrony/chrony.conf ] || conf=/etc/chrony/chrony.conf
state_dir=/var/lib/server-base/chrony
pending=$state_dir/restart-pending
verified=$state_dir/sources-verified

# Return a sed range for this block. Reject ambiguous markers before editing.
block_range() {
  awk -v target="$1" '
    /^# BEGIN BASE (FALLBACK )?NTP SERVERS$/ {
      if (open) invalid = 1
      open = substr($0, 9)
      if (open == target) {
        if (first) invalid = 1
        first = NR
      }
    }
    /^# END BASE (FALLBACK )?NTP SERVERS$/ {
      if (open != substr($0, 7)) invalid = 1
      if (open == target) last = NR
      open = ""
    }
    END {
      if (invalid || open) {
        print "Malformed managed NTP source markers in " FILENAME > "/dev/stderr"
        exit 1
      }
      if (first) print first "," last
    }
  ' "$conf"
}

source_block() {
  local marker=$1
  shift
  echo "# BEGIN $marker"
  printf 'server %s iburst\n' "$@"
  echo "# END $marker"
}

block_matches() {
  local range=$1
  shift
  [ -n "$range" ] && cmp -s <(source_block "$@") <(sed -n "${range}p" "$conf")
}

if [ "$mode" = check ]; then
  if ! (systemctl is-active --quiet chronyd || systemctl is-active --quiet chrony); then
    echo inactive
    exit 0
  fi
  if [ "$#" -gt 0 ]; then
    range=$(block_range 'BASE NTP SERVERS')
    if ! block_matches "$range" 'BASE NTP SERVERS' "$@"; then
      echo sources-drift
      exit 0
    fi
  fi
  if [ -e "$pending" ]; then
    echo restart-pending
  elif [ "$#" -gt 0 ] && ! cmp -s "$verified" <(printf '%s\n' "$@"); then
    echo sources-unverified
  elif wait_for_sync 1; then
    echo synchronized
  else
    show_sources
    echo unsynchronized
  fi
  exit 0
fi

[ "$mode" = apply ] || { echo "Expected check or apply" >&2; exit 1; }
configure_sources() (
  local marker=$1 range tmp
  shift
  [ "$#" -gt 0 ] || return 0
  range=$(block_range "$marker")
  if block_matches "$range" "$marker" "$@"; then return 0; fi
  # Replace in place within the file so surrounding directives keep their order.
  tmp=$(mktemp -- "${conf}.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  cp --preserve=all -- "$conf" "$tmp"
  {
    if [ -n "$range" ]; then
      head -n "$(( ${range%,*} - 1 ))" -- "$conf"
      source_block "$marker" "$@"
      tail -n "+$(( ${range#*,} + 1 ))" -- "$conf"
    else
      cat -- "$conf"
      if [ -s "$conf" ] && [ -n "$(tail -c 1 -- "$conf")" ]; then echo; fi
      source_block "$marker" "$@"
    fi
  } > "$tmp"
  # The running daemon may still use the previous configuration until restart.
  touch -- "$pending"
  mv -fT -- "$tmp" "$conf"
)

conf=$(readlink -f -- "$conf")
mkdir -p -- "$state_dir"
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
if [ "$#" -gt 0 ]; then
  touch -- "$pending"
  chmod 600 -- "$pending"
  printf '%s\n' "$@" > "$pending"
  mv -fT -- "$pending" "$verified"
else
  rm -f -- "$pending"
fi
