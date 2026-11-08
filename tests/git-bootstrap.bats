#!/usr/bin/env bats
# Tests for git-bootstrap.sh.
#
# Scope: the entry-point guard rails — --help, argument errors, and the root
# refusal. The setup path itself (apt, /opt/git, ~/.ssh, ssh -T to GitHub) is
# not exercised: it needs real sudo and the network.
#
# The source script is run, not dist/, through the development bootstrap with
# BASH_INCLUDES_DIR pointed at the pinned library. CI's bats job has no library
# checked out, so it is cloned at the LIB_VERSION tag the way build.sh does.
#
# sudo, apt-get and dpkg are stubbed on PATH. The sudo stub records every call
# and runs nothing, so "no sudo call happened" is a test of whether the script
# got as far as changing the system. HOME and XDG_STATE_HOME point into a temp
# tree, so ~/.ssh and the journal are observable and the real ones untouched.

bats_require_minimum_version 1.5.0

setup_file() {
    if [[ -n "${BASH_INCLUDES_DIR:-}" ]]; then
        export GB_LIB="$BASH_INCLUDES_DIR"
    else
        git -c advice.detachedHead=false clone --quiet --depth 1 \
            --branch "$(cat "${BATS_TEST_DIRNAME}/../LIB_VERSION")" \
            https://github.com/ksgill/bash-includes.git "${BATS_FILE_TMPDIR}/bash-includes"
        export GB_LIB="${BATS_FILE_TMPDIR}/bash-includes/lib"
    fi
}

setup() {
    REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    SCRIPT="${REPO}/git-bootstrap.sh"
    TMP="$(mktemp -d)"
    export TMP
    STUBS="${TMP}/bin"
    mkdir -p "$STUBS" "${TMP}/home" "${TMP}/keys"

    export BASH_INCLUDES_DIR="$GB_LIB"
    export HOME="${TMP}/home"
    export XDG_STATE_HOME="${TMP}/state"
    export SUDO_LOG="${TMP}/sudo.log"
    export GIT_USER_NAME="Test User"
    export GIT_USER_EMAIL="test@example.invalid"

    # A plaintext pair, so preflight would pass and the run would go on to
    # change things if nothing stopped it.
    printf 'not a real key\n' > "${TMP}/keys/git@github.com"
    printf 'not a real key\n' > "${TMP}/keys/git@github.com.pub"

    # sudo: record, run nothing, succeed. SUDO_FAIL makes it refuse instead.
    # cp, chown and cmp are run for real when every path they name is inside
    # $TMP, so the key-install tests can see what lands in ~/.ssh.
    cat > "${STUBS}/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${SUDO_LOG}"
[[ -z "${SUDO_FAIL:-}" ]] || exit 1
case "${1:-}" in
    cp|chown|cmp)
        for a in "$@"; do
            [[ "$a" != /* || "$a" == "${TMP}"/* ]] || exit 0
        done
        exec "$@" ;;
esac
exit 0
STUB
    # apt-get: must never be reached in these tests.
    cat > "${STUBS}/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${SUDO_LOG}"
exit 1
STUB
    # dpkg: everything reports installed, so no install is attempted.
    cat > "${STUBS}/dpkg" <<'STUB'
#!/usr/bin/env bash
printf 'ii  %s  1.0  all  stub\n' "${2:-}"
STUB
    chmod +x "${STUBS}"/*
    export PATH="${STUBS}:${PATH}"
}

teardown() {
    rm -rf "${TMP}"
}

# Nothing under HOME, no journal, and sudo never used for a change.
_assert_untouched() {
    [ -z "$(ls -A "${TMP}/home")" ]
    [ ! -e "${TMP}/state" ]
    if [[ -e "$SUDO_LOG" ]]; then
        # The guard's own non-interactive probe is the only permitted call.
        [ -z "$(grep -v '^sudo -n true$' "$SUDO_LOG" || true)" ]
    fi
}

@test "--help prints usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--keys-dir DIR"* ]]
    _assert_untouched
}

@test "an unknown argument exits 1 with usage and changes nothing" {
    run "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument: --bogus"* ]]
    _assert_untouched
}

@test "--keys-dir without a value is refused" {
    run "$SCRIPT" --keys-dir
    [ "$status" -eq 1 ]
    [[ "$output" == *"--keys-dir requires a directory argument"* ]]
    _assert_untouched
}

# EUID cannot be faked, and the suite never uses real root. An unprivileged
# user namespace maps the caller to uid 0 with no real privilege, which is
# enough to reach the check.
@test "--help still works as root" {
    unshare -r true 2>/dev/null || skip "unprivileged user namespaces are not available"
    run unshare -r "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "running as root is refused before anything is touched" {
    unshare -r true 2>/dev/null || skip "unprivileged user namespaces are not available"
    run unshare -r "$SCRIPT" --keys-dir "${TMP}/keys" --non-interactive
    [ "$status" -eq 1 ]
    [[ "$output" == *"not as root"* ]]
    [ ! -e "$SUDO_LOG" ]
    _assert_untouched
}

@test "unusable sudo is refused before anything is touched" {
    export SUDO_FAIL=1
    run "$SCRIPT" --keys-dir "${TMP}/keys" --non-interactive </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"sudo access is required"* ]]
    [ -z "$(ls -A "${TMP}/home")" ]
    [ ! -e "${TMP}/state" ]
    # Only the guard's probe and its prime, nothing that changes state.
    [ "$(cat "$SUDO_LOG")" = $'sudo -n true\nsudo -v' ]
}

# ── install_keys: an existing key ────────────────────────────────────────────
# Replacing a key is destructive: the prompt defaults to no, --non-interactive
# never answers it, and a pair identical to the source is not asked about.
# ssh is stubbed here because the run gets as far as verify_identity.

_stub_ssh() {
    cat > "${STUBS}/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'Hi stub! You'"'"'ve successfully authenticated, but GitHub does not provide shell access.\n' >&2
exit 1
STUB
    chmod +x "${STUBS}/ssh"
}

@test "an identical keypair already in ~/.ssh is left alone without a prompt" {
    _stub_ssh
    mkdir -m 700 "${TMP}/home/.ssh"
    cp "${TMP}/keys/git@github.com" "${TMP}/keys/git@github.com.pub" "${TMP}/home/.ssh/"
    run "$SCRIPT" --keys-dir "${TMP}/keys" --non-interactive </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"already match the source"* ]]
    [[ "$output" != *"Overwrite?"* ]]
    run ! grep -q '^sudo cp ' "$SUDO_LOG"
    [ "$(cat "${TMP}/home/.ssh/git@github.com")" = "not a real key" ]
    [ "$(stat -c '%a' "${TMP}/home/.ssh/git@github.com")" = 600 ]
}

@test "--non-interactive never replaces a different existing key" {
    _stub_ssh
    mkdir -m 700 "${TMP}/home/.ssh"
    printf 'the old key\n' > "${TMP}/home/.ssh/git@github.com"
    run "$SCRIPT" --keys-dir "${TMP}/keys" --non-interactive </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"differs from the source"* ]]
    [[ "$output" == *"--non-interactive never overwrites an existing key"* ]]
    [[ "$output" != *"Overwrite?"* ]]
    run ! grep -q '^sudo cp ' "$SUDO_LOG"
    [ "$(cat "${TMP}/home/.ssh/git@github.com")" = "the old key" ]
}

@test "interactively, Overwrite? defaults to no: an empty answer keeps the existing key" {
    command -v script >/dev/null || skip "util-linux script(1) is not available"
    _stub_ssh
    mkdir -m 700 "${TMP}/home/.ssh"
    printf 'the old key\n' > "${TMP}/home/.ssh/git@github.com"
    # confirm reads only from a terminal, so the run gets a pty from script(1)
    # and its answers through it: an empty line for the key path (default
    # yes), then an empty line for Overwrite? (default no). Each answer is
    # sent after a pause, because confirm drains typeahead before it asks.
    run timeout 60 bash -c "{ sleep 2; printf '\\n'; sleep 2; printf '\\n'; sleep 2; } | NO_COLOR=1 script -qefc '$SCRIPT --keys-dir ${TMP}/keys' /dev/null"
    [[ "$output" == *"Overwrite? [y/N]"* ]]
    [[ "$output" == *"Aborted — existing key preserved."* ]]
    run ! grep -q '^sudo cp ' "$SUDO_LOG"
    [ "$(cat "${TMP}/home/.ssh/git@github.com")" = "the old key" ]
}

@test "interactively, answering y to Overwrite? installs the new key" {
    command -v script >/dev/null || skip "util-linux script(1) is not available"
    _stub_ssh
    mkdir -m 700 "${TMP}/home/.ssh"
    printf 'the old key\n' > "${TMP}/home/.ssh/git@github.com"
    # Key path (default yes), Overwrite? (y), then the git name and email
    # prompts take their defaults from the environment.
    run timeout 60 bash -c "{ sleep 2; printf '\\n'; sleep 2; printf 'y\\n'; sleep 2; printf '\\n'; sleep 1; printf '\\n'; sleep 2; } | NO_COLOR=1 script -qefc '$SCRIPT --keys-dir ${TMP}/keys' /dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Overwrite? [y/N]"* ]]
    [[ "$output" == *"Keys installed to"* ]]
    grep -q '^sudo cp ' "$SUDO_LOG"
    [ "$(cat "${TMP}/home/.ssh/git@github.com")" = "not a real key" ]
    [ "$(stat -c '%a' "${TMP}/home/.ssh/git@github.com")" = 600 ]
    [ "$(stat -c '%a' "${TMP}/home/.ssh/git@github.com.pub")" = 644 ]
}
