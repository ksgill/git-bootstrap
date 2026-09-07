#!/usr/bin/env bash
set -euo pipefail

# build.sh — produce dist/git-bootstrap.sh, self-contained.
#
# Uses a local bash-includes checkout when BASH_INCLUDES_DIR is set, so the
# edit/build loop is instant. Otherwise clones the tag pinned in LIB_VERSION,
# which is what CI and clean builds get — reproducible, and bumping the
# library is a one-line reviewable diff.
#
# The artifact is the thing you run. This script is the only part of the repo
# that needs the network or the library; dist/git-bootstrap.sh needs neither,
# which is the point — it runs on a machine that has nothing yet.

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

LIB="${BASH_INCLUDES_DIR:-}"
if [[ -z "$LIB" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$(cat LIB_VERSION)" \
        https://github.com/ksgill/bash-includes.git "$tmp/bash-includes" 2>/dev/null \
        || { echo "Could not clone bash-includes at $(cat LIB_VERSION)" >&2; exit 1; }
    LIB="$tmp/bash-includes/lib"
fi

exec "${LIB}/../bin/bld" -L "$LIB" -o dist git-bootstrap.sh
