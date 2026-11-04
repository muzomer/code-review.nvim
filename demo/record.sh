#!/usr/bin/env bash
# Record the demo GIF: needs vhs (and ttyd, taken from nix here).
set -euo pipefail
cd "$(dirname "$0")/.."
demo/setup.sh
export DEMO_DIR="$PWD/demo"
env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u NVIM -u NVIM_LISTEN_ADDRESS \
  nix shell nixpkgs#ttyd -c vhs demo/demo.tape
