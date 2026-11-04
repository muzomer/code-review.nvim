#!/usr/bin/env bash
# Record a review of a real public PR (neovim/neovim#42677), answered by the
# real `claude` (a paid run). Needs network, a GitHub token (gh auth) and claude.
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO_TMP=$(mktemp -d /tmp/pr-demo.XXXX)
export DEMO_TMP DEMO_DIR="$PWD/demo" DEMO_REAL_AGENT=1 \
  NVIM_CODE_REVIEW_STATE="$DEMO_TMP/state" NVIM_CODE_REVIEW_CACHE="$DEMO_TMP/cache"
env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u NVIM -u NVIM_LISTEN_ADDRESS \
  nix shell nixpkgs#ttyd -c vhs demo/pr-real.tape
