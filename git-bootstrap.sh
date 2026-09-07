#!/usr/bin/env bash
set -euo pipefail

# git-bootstrap.sh
# Bootstraps SSH-based Git identity on a fresh Ubuntu system.
# Keys are read from --keys-dir, which defaults to the directory holding this
# script (the USB layout). Point it at the removable volume when running from a
# git clone, so the keypair never has to sit inside a tracked working tree.
#
# The key directory may hold EITHER an unencrypted pair (git@github.com and
# git@github.com.pub) OR a gpg-symmetric bundle (keys.tar.gpg); the script
# detects which and prompts for the passphrase only in the encrypted case.
#
# Usage: bash git-bootstrap.sh [--keys-dir DIR] [--non-interactive]
#
# Environment:
#   GPG_PASSPHRASE   passphrase for the encrypted bundle; required with
#                    --non-interactive, prompted for otherwise

# ── Library ───────────────────────────────────────────────────────────────────

# >>> bash-includes >>>
# include: git.sh
#
# Development bootstrap. Lets this script run straight from a checkout;
# ./build.sh replaces this whole block with the library inlined, so the shipped
# artifact has no runtime dependency — which matters more here than anywhere
# else, since this is what runs on a machine where nothing is set up yet.
_bootstrap_lib() {
    local d
    for d in "${BASH_INCLUDES_DIR:-}" \
             /opt/git/bash-includes/lib \
             /usr/local/lib/bash-includes; do
        [[ -n "$d" && -r "$d/log.sh" ]] || continue
        # shellcheck source=/dev/null
        . "$d/log.sh"; . "$d/journal.sh"; . "$d/backup.sh"; . "$d/git.sh"
        return 0
    done
    printf 'ERROR: bash-includes not found. Set BASH_INCLUDES_DIR to its lib/ directory.\n' >&2
    exit 1
}
_bootstrap_lib
# <<< bash-includes <<<

# ── Constants ─────────────────────────────────────────────────────────────────

# Resolve the directory this script lives in (i.e., the USB root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Key basenames. The directory holding them is resolved after flag parsing,
# because --keys-dir may override it.
PRIVATE_KEY_NAME="git@github.com"
PUBLIC_KEY_NAME="git@github.com.pub"

# A gpg --symmetric tar of the two files above, used when no plaintext pair is
# present. Create with:
#   tar -cf - git@github.com git@github.com.pub \
#     | gpg --symmetric --cipher-algo AES256 --digest-algo SHA512 \
#           --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
#           -o keys.tar.gpg
ENCRYPTED_KEYS_NAME="keys.tar.gpg"

# Destination in the user's home directory.
SSH_DIR="${HOME}/.ssh"
PRIVATE_KEY_DST="${SSH_DIR}/git@github.com"
PUBLIC_KEY_DST="${SSH_DIR}/git@github.com.pub"
# The ssh config path, the known_hosts path and the pinned host key all live in
# lib/git.sh now, so a machine set up from this stick and one provisioned by
# sys-bld end up with the same stanza and the same pin.

# journal.sh defaults to /var/lib/provision, which needs root. This runs
# unprivileged with per-command sudo, so it keeps a per-user record instead —
# a log of what was changed in ~/.ssh on a machine that had nothing before.
JOURNAL_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/git-bootstrap"
JOURNAL_FILE="${JOURNAL_DIR}/changes.jsonl"

# The user who invoked the script — used to set correct ownership after sudo cp.
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"

# ── Flags ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
git-bootstrap.sh — set up SSH-based Git identity on a fresh Ubuntu system.

Usage:
  git-bootstrap.sh [--keys-dir DIR] [--non-interactive] [--help]

  --keys-dir DIR      where to read the keypair from. Defaults to the directory
                      holding this script, which is the USB layout. Point it at
                      the removable volume when running from a git clone, so the
                      keys never sit inside a tracked working tree.
  --non-interactive   never prompt. Requires GIT_USER_NAME and GIT_USER_EMAIL,
                      and GPG_PASSPHRASE if the keys are encrypted.
  -h, --help          this message

Key sources, detected automatically in the key directory:
  git@github.com + git@github.com.pub   an unencrypted pair; used if present
  keys.tar.gpg                          a gpg --symmetric tar; prompts for the
                                        passphrase. Create it with:

    tar -cf - git@github.com git@github.com.pub \
      | gpg --symmetric --cipher-algo AES256 --digest-algo SHA512 \
            --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
            -o keys.tar.gpg

  The passphrase is read straight from the terminal, not via gpg pinentry, so
  this works over a plain SSH session on a headless server with no DISPLAY.

Environment:
  GIT_USER_NAME     git user.name;  prompted for if unset
  GIT_USER_EMAIL    git user.email; prompted for if unset
  GPG_PASSPHRASE    passphrase for the encrypted bundle; prompted for if unset

What it does:
  installs git (and gnupg, only if the keys are encrypted); creates /opt/git
  owned by the invoking user; installs the keypair into ~/.ssh at 600/644;
  writes ~/.ssh/config.d/10-github.conf and includes it from ~/.ssh/config;
  pins GitHub's Ed25519 host key
  in ~/.ssh/known_hosts; sets git global config; verifies with ssh -T.

Re-running is safe: the ssh config block and the host key pin are both skipped
if already correct, and overwriting an existing private key asks first.
USAGE
}

NON_INTERACTIVE=false
KEYS_DIR=""

# Set by preflight to "plain" or "gpg" once it has seen what is actually there.
KEY_SOURCE_MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --keys-dir)
            [[ $# -ge 2 ]] || die "--keys-dir requires a directory argument."
            KEYS_DIR="$2"; shift 2 ;;
        --keys-dir=*) KEYS_DIR="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

# Default to the script's own directory, which is the USB layout where the keys
# sit beside the script. --keys-dir decouples the two so this code can live in a
# public repo while the keys stay on removable media.
KEYS_DIR="${KEYS_DIR:-${SCRIPT_DIR}}"
PRIVATE_KEY_SRC="${KEYS_DIR}/${PRIVATE_KEY_NAME}"
PUBLIC_KEY_SRC="${KEYS_DIR}/${PUBLIC_KEY_NAME}"
ENCRYPTED_KEYS_SRC="${KEYS_DIR}/${ENCRYPTED_KEYS_NAME}"

# ── Helpers ───────────────────────────────────────────────────────────────────

confirm() {
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        return 0
    fi
    local prompt="$1"
    local reply
    read -r -p "${prompt} [Y/n] " reply
    # Empty reply (just Enter) defaults to yes
    [[ -z "${reply}" || "${reply,,}" == "y" ]]
}

# ── Preflight checks ──────────────────────────────────────────────────────────

# Is this key file present? Tries as the invoking user first. If the key
# directory is readable and traversable by us, a plain test is authoritative and
# sudo is never invoked — which is the normal case, and avoids demanding a
# password merely to stat two files. sudo is only worth trying when the
# directory itself cannot be traversed, e.g. a root-owned mount.
#
# The distinction matters: `sudo test -f` returns non-zero both when the file is
# missing AND when sudo could not authenticate at all, so using it
# unconditionally reports "no keys found" for what is really a sudo failure.
key_file_exists() {
    local f="$1"

    [[ -f "$f" ]] && return 0

    # We could look, and it is not there. Authoritative; do not escalate.
    if [[ -r "${KEYS_DIR}" && -x "${KEYS_DIR}" ]]; then
        return 1
    fi

    sudo test -f "$f"
}

preflight() {
    log_info "Script directory: ${SCRIPT_DIR}"
    log_info "Key directory:    ${KEYS_DIR}"
    confirm "Is this the correct key path?" || die "Aborted by user."

    [[ -d "${KEYS_DIR}" ]] || die "Key directory does not exist: ${KEYS_DIR}"

    # If the directory cannot be traversed as this user, every test below has to
    # go through sudo, and a sudo that cannot authenticate would make missing
    # keys and an unusable sudo look identical. Establish which it is up front.
    if [[ ! -r "${KEYS_DIR}" || ! -x "${KEYS_DIR}" ]]; then
        log_warn "${KEYS_DIR} is not readable as ${CURRENT_USER}; falling back to sudo."
        sudo test -d "${KEYS_DIR}" \
            || die "Cannot read ${KEYS_DIR}, and sudo is not usable here. Check the path, the mount, and whether this shell has a terminal for sudo to prompt on."
    fi

    # Decide how the keys are supplied. A plaintext pair wins if present; the
    # encrypted bundle is the fallback.
    if key_file_exists "${PRIVATE_KEY_SRC}" && key_file_exists "${PUBLIC_KEY_SRC}"; then
        KEY_SOURCE_MODE="plain"
        log_info "Found an unencrypted keypair in ${KEYS_DIR}"
        if key_file_exists "${ENCRYPTED_KEYS_SRC}"; then
            log_warn "${ENCRYPTED_KEYS_NAME} is also present — using the plaintext pair."
        fi
    elif key_file_exists "${ENCRYPTED_KEYS_SRC}"; then
        KEY_SOURCE_MODE="gpg"
        log_info "Found an encrypted bundle: ${ENCRYPTED_KEYS_SRC}"
    else
        die "No keys in ${KEYS_DIR} — expected either ${PRIVATE_KEY_NAME} plus ${PUBLIC_KEY_NAME}, or ${ENCRYPTED_KEYS_NAME}."
    fi
}

# ── Install git if missing ────────────────────────────────────────────────────

ensure_git() {
    if dpkg -l git 2>/dev/null | grep -q '^ii'; then
        log_info "git is already installed."
    else
        log_info "git not found — installing."
        sudo apt-get update -qq
        sudo apt-get install -y git || die "Failed to install git."
    fi
}

# ── Install gnupg if missing ──────────────────────────────────────────────────

ensure_gpg() {
    if dpkg -l gnupg 2>/dev/null | grep -q '^ii'; then
        log_info "gnupg is already installed."
    else
        log_info "gnupg not found — installing."
        sudo apt-get update -qq
        sudo apt-get install -y gnupg || die "Failed to install gnupg."
    fi
}

# ── SSH directory setup ───────────────────────────────────────────────────────

setup_ssh_dir() {
    if [[ ! -d "${SSH_DIR}" ]]; then
        log_info "Creating ${SSH_DIR}"
        mkdir -p "${SSH_DIR}"
    fi
    # 700: only owner can read/write/execute. Required by SSH.
    chmod 700 "${SSH_DIR}"
}

# ── Copy keys ─────────────────────────────────────────────────────────────────

# Obtain the bundle passphrase into GPG_PASS. Read from the environment when
# set, so unattended runs work; otherwise prompt. Deliberately does NOT use gpg
# pinentry: on a headless server pinentry may be absent or configured for a GUI
# with no DISPLAY to draw on, and that failure is confusing. Reading it here and
# handing it to gpg on a file descriptor works the same over a bare SSH session
# as it does on a desktop.
GPG_PASS=""

read_passphrase() {
    if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
        GPG_PASS="${GPG_PASSPHRASE}"
        log_info "Using passphrase from GPG_PASSPHRASE."
        return
    fi

    if [[ "${NON_INTERACTIVE}" == true ]]; then
        die "--non-interactive with an encrypted bundle requires GPG_PASSPHRASE to be set."
    fi

    # Read from the terminal, not stdin: stdin may be a pipe. -s suppresses the
    # echo so the passphrase is not left on screen or in scrollback.
    [[ -r /dev/tty ]] || die "No terminal available to prompt for the passphrase — set GPG_PASSPHRASE instead."
    read -rsp "Passphrase for ${ENCRYPTED_KEYS_NAME}: " GPG_PASS < /dev/tty
    printf '\n'
    [[ -n "${GPG_PASS}" ]] || die "Empty passphrase."
}

install_keys_plain() {
    # sudo cp to read root-owned source files on the USB,
    # then immediately fix ownership so the invoking user owns the result.
    sudo cp "${PRIVATE_KEY_SRC}" "${PRIVATE_KEY_DST}" \
        || die "Failed to copy private key."
    sudo cp "${PUBLIC_KEY_SRC}"  "${PUBLIC_KEY_DST}" \
        || die "Failed to copy public key."

    sudo chown "${CURRENT_USER}:${CURRENT_GROUP}" "${PRIVATE_KEY_DST}" "${PUBLIC_KEY_DST}" \
        || die "Failed to set key ownership."
}

install_keys_gpg() {
    read_passphrase

    # Decrypt straight into ~/.ssh: gpg writes to stdout and tar reads it, so no
    # plaintext tarball is ever created on disk. umask 077 means the extracted
    # files are born 600 rather than being created loose and chmod-ed after,
    # which would leave a window where the private key is world-readable.
    # The passphrase goes in on a file descriptor, never as an argument, since
    # arguments are visible to anyone running ps.
    ( umask 077
      printf '%s\n' "${GPG_PASS}" \
        | gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 0 \
              --decrypt "${ENCRYPTED_KEYS_SRC}" \
        | tar -x -C "${SSH_DIR}" ) \
        || die "Could not decrypt ${ENCRYPTED_KEYS_NAME} — wrong passphrase, or not a gpg-encrypted tar."

    GPG_PASS=""

    [[ -f "${PRIVATE_KEY_DST}" && -f "${PUBLIC_KEY_DST}" ]] \
        || die "Bundle did not contain ${PRIVATE_KEY_NAME} and ${PUBLIC_KEY_NAME}."
}

install_keys() {
    if [[ -f "${PRIVATE_KEY_DST}" ]]; then
        log_warn "Private key already exists at ${PRIVATE_KEY_DST}"
        confirm "Overwrite?" || die "Aborted — existing key preserved."
    fi

    case "${KEY_SOURCE_MODE}" in
        plain) install_keys_plain ;;
        gpg)   install_keys_gpg ;;
        *)     die "Internal error: key source mode not set." ;;
    esac

    # 600: private key must not be group- or world-readable or SSH will refuse it.
    chmod 600 "${PRIVATE_KEY_DST}"
    # 644: public key can be world-readable.
    chmod 644 "${PUBLIC_KEY_DST}"

    log_info "Keys installed to ${SSH_DIR}"
}

# ── /opt/git directory setup ──────────────────────────────────────────────────

setup_git_dir() {
    if [[ ! -d /opt/git ]]; then
        log_info "Creating /opt/git"
        sudo mkdir -p /opt/git || die "Failed to create /opt/git"
    else
        log_info "/opt/git already exists — skipping creation."
    fi

    sudo chown "${CURRENT_USER}:${CURRENT_GROUP}" /opt/git || die "Failed to set ownership on /opt/git"
    # 774: owner and group have full access, others can read and traverse.
    sudo chmod 774 /opt/git || die "Failed to set permissions on /opt/git"

    log_info "/opt/git owner=${CURRENT_USER} group=${CURRENT_GROUP} mode=774"
}

# ── Git global config ─────────────────────────────────────────────────────────

configure_git() {
    local git_user git_email
    local default_user="${GIT_USER_NAME:-user}"
    local default_email="${GIT_USER_EMAIL:-user@email.com}"

    if [[ "${NON_INTERACTIVE}" == true ]]; then
        # Unattended: never prompt. read would take the flag's whole purpose
        # away, and with no stdin it returns 1, which set -e turns into an exit
        # part-way through setup. Refuse instead of falling back to the
        # placeholder defaults — a wrong user.email is silent and authors every
        # commit made afterwards.
        [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]] \
            || die "--non-interactive requires GIT_USER_NAME and GIT_USER_EMAIL to be set."
        git_user="${GIT_USER_NAME}"
        git_email="${GIT_USER_EMAIL}"
    else
        read -r -p "Git user name [${default_user}]: " git_user
        git_user="${git_user:-${default_user}}"

        read -r -p "Git email [${default_email}]: " git_email
        git_email="${git_email:-${default_email}}"
    fi

    # Identity, the global ignore file and init.defaultBranch come from the
    # library, so a machine set up from this stick matches one provisioned by
    # sys-bld rather than differing in ways nobody would think to check.
    git_identity_config "${git_user}" "${git_email}"

    # Below here is git-bootstrap's own preference, deliberately not in the
    # library: sys-bld does not set these, and they are a working style rather
    # than something a machine needs to function.

    # Always recurse into submodules on clone, pull, fetch, and checkout.
    # Override per-repo with --no-recurse-submodules if needed.
    git config --global submodule.recurse true
    # Applies recurse-submodules to git clone specifically.
    git config --global clone.recurseSubmodules true
    # Push current branch to same-named remote branch without specifying refspec.
    git config --global push.default current
    # Automatically set upstream tracking on first push — eliminates "origin HEAD:main".
    # Requires git 2.38+. Ubuntu 24.04 ships 2.43.
    git config --global push.autoSetupRemote true

    log_info "Git global config: submodule.recurse       = true"
    log_info "Git global config: clone.recurseSubmodules = true"
    log_info "Git global config: push.default            = current"
    log_info "Git global config: push.autoSetupRemote    = true"
}

# ── Verify identity ───────────────────────────────────────────────────────────

verify_identity() {
    log_info "Testing GitHub SSH authentication..."
    # ssh -T exits with code 1 even on success (GitHub sends a greeting, not a shell).
    # We capture stderr (where the greeting goes) and check its content.
    #
    # StrictHostKeyChecking=yes, not accept-new: the pin has already put the
    # real key in known_hosts, so there is no first-use window left to accept.
    # Anything presenting a different host key is refused rather than recorded.
    local output
    output="$(ssh -T -o StrictHostKeyChecking=yes github 2>&1 || true)"

    if echo "${output}" | grep -q "successfully authenticated"; then
        log_info "Authentication confirmed: ${output}"
    else
        log_warn "Unexpected response from GitHub:"
        log_warn "${output}"
        log_warn "This may be a key deployment issue or a network problem."
        log_warn "Re-run manually: ssh -T github"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    log_info "=== git-bootstrap: starting ==="

    # Records what gets changed under ~/.ssh. SCRIPT_VERSION is stamped by bld
    # in the built artifact and unset when running straight from a checkout.
    journal_init "git-bootstrap" "${SCRIPT_VERSION:-dev}"

    preflight
    ensure_git
    # Only needed for an encrypted bundle. Written as an if, not `[[ ]] && ...`,
    # because a false test as the last command would trip set -e.
    if [[ "${KEY_SOURCE_MODE}" == "gpg" ]]; then
        ensure_gpg
    fi
    setup_git_dir
    setup_ssh_dir
    install_keys
    git_github_ssh_stanza "${PRIVATE_KEY_DST}"
    git_pin_github_host_key
    configure_git
    verify_identity

    log_info "=== git-bootstrap: complete ==="
    log_info "You can now clone repos with: git clone github:<user>/<repo>"
}

main "$@"
