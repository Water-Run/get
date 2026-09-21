#!/usr/bin/env bash
# Install a pinned isolation dependency on a disposable GitHub Actions runner.
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
sudo apt-get update
sudo apt-get install -y meson ninja-build pkg-config libcap-dev fish ripgrep groff-base
mkdir -p .ci/bwrap-source
curl --fail --location --retry 3 \
  https://github.com/containers/bubblewrap/releases/download/v0.12.0/bubblewrap-0.12.0.tar.xz \
  --output .ci/bwrap-source/source.tar.xz
printf '%s  %s\n' 9760d007363e3abba7c747489910f9f82d9fca53ba3bd3282e396fa3c97a3314 \
  .ci/bwrap-source/source.tar.xz | sha256sum --check -
tar -xJf .ci/bwrap-source/source.tar.xz -C .ci/bwrap-source
meson setup .ci/bwrap-source/build .ci/bwrap-source/bubblewrap-0.12.0 \
  --buildtype=release -Dtests=false -Dman=disabled -Dselinux=disabled
ninja -C .ci/bwrap-source/build -j1
sudo install -m 0755 .ci/bwrap-source/build/bwrap /usr/bin/bwrap
/usr/bin/bwrap --version
