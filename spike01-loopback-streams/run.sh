#!/bin/bash
# Always through mise. Never Homebrew, never the system Ruby.
set -euo pipefail
cd "$(dirname "$0")"
exec mise exec ruby@3.4.8 -- ruby server.rb "$@"
