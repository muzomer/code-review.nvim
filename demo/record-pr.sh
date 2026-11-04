#!/usr/bin/env bash
# Record the PR review GIF: the invented PR acme/payments#128 is served by
# demo/bin/curl, so no network or GitHub account is used.
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO_TMP=$(mktemp -d /tmp/pr-demo.XXXX)
export DEMO_TMP DEMO_DIR="$PWD/demo" PATH="$PWD/demo/bin:$PATH" GH_TOKEN=demo \
  NVIM_CODE_REVIEW_STATE="$DEMO_TMP/state" NVIM_CODE_REVIEW_CACHE="$DEMO_TMP/cache"
env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u NVIM -u NVIM_LISTEN_ADDRESS \
  nix shell nixpkgs#ttyd -c vhs demo/pr.tape
