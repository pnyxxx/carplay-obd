#!/bin/sh
# Compile et teste le cœur OBD (OBDKit) sous Linux, dans un conteneur Swift officiel.
set -e
cd "$(dirname "$0")/../Packages/OBDKit"
exec docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD":/pkg -w /pkg swift:6.2 \
  swift test --scratch-path /tmp/obdkit-build "$@"
