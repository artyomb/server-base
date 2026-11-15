#!/bin/bash
set -euo pipefail
umask 077
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
case ":$PATH:" in
  *:/usr/local/bin:*) ;;
  *) export PATH="/usr/local/bin:$PATH" ;;
esac
PROJECT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# No profiles or shell configuration are sourced. The installer pins the Ruby path.
RUBY_CMD="$(cat "$PROJECT_DIR/.ruby-path")"
exec flock -n -E 0 "$PROJECT_DIR/state/run.lock" "$RUBY_CMD" "$PROJECT_DIR/fixes_processor.rb" --locked
