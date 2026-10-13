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
#
# A tag can be moved on the remote, so the clone must also resolve to the
# commit recorded in LIB_COMMIT; bump both together.

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

LIB="${BASH_INCLUDES_DIR:-}"
if [[ -z "$LIB" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$(cat LIB_VERSION)" \
        https://github.com/ksgill/bash-includes.git "$tmp/bash-includes" 2>/dev/null \
        || { echo "Could not clone bash-includes at $(cat LIB_VERSION)" >&2; exit 1; }
    want="$(cat LIB_COMMIT)"
    got="$(git -C "$tmp/bash-includes" rev-parse HEAD)"
    if [[ "$got" != "$want" ]]; then
        echo "bash-includes $(cat LIB_VERSION) is ${got}, but LIB_COMMIT pins ${want}. Refusing to build." >&2
        exit 1
    fi
    LIB="$tmp/bash-includes/lib"
fi

# A repo-local lib/ shadows the shared library when it exists; most repos have
# none, and bld rejects a search path that is not there.
SEARCH=(-L "$LIB")
[[ -d lib ]] && SEARCH=(-L lib "${SEARCH[@]}")

# Not exec: the EXIT trap has to survive to remove the clone.
"${LIB}/../bin/bld" "${SEARCH[@]}" -o dist git-bootstrap.sh
