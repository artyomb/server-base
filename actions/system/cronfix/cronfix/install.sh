#!/bin/bash
set -euo pipefail
umask 077
PROJECT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
exec "${RUBY_BIN:-ruby}" "$PROJECT_DIR/bundle.rb" "$@"
