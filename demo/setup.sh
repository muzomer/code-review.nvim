#!/usr/bin/env bash
# Build the throwaway demo project (/tmp/api) and seed a few threads.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rm -rf /tmp/api && mkdir -p /tmp/api && cp "$here/rate_limiter.py" /tmp/api/
cd /tmp/api && git init -q && git add . && git -c user.name=demo -c user.email=demo@example.com commit -qm init
nvim --clean --headless -l "$here/seed.lua"
