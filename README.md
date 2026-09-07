# git-bootstrap

Bootstraps an SSH-based Git identity on a fresh Ubuntu system.

Everything a newly installed machine needs before it can talk to GitHub —
the keypair, the SSH host block, a pinned host key, `/opt/git` ownership and
git's global configuration — done in one pass, from a keypair carried on
removable media.

The keys never live in this repository. The script reads them from a directory
you point it at with `--keys-dir`, so the code can be maintained in public
while the key material stays on a USB stick in your pocket.

## Quick start

```sh
git clone https://github.com/ksgill/git-bootstrap.git
cd git-bootstrap
./dist/git-bootstrap.sh --keys-dir /run/media/"$USER"/MYSTICK/git-bootstrap
```

`dist/git-bootstrap.sh` is the thing you run. It is committed, self-contained,
and needs nothing but a stock Ubuntu — which matters here more than in most
repos, because this is what runs on a machine where nothing is set up yet. The
top-level `git-bootstrap.sh` is the source, and it needs the `bash-includes`
library; see [Building](#building).

Or run it straight off the stick, with the keys beside it, which is what
`--keys-dir` defaults to:

```sh
/run/media/"$USER"/MYSTICK/git-bootstrap/git-bootstrap.sh
```

The copy on the stick is the built artifact under its plain name, so there is no
`dist/` to remember when running it from there.

Run it as your normal user. It calls `sudo` per command where it genuinely
needs root — installing packages, creating `/opt/git` — and never expects to
be run as root itself.

## What it does

In order:

1. **Preflight.** Resolves the key directory, shows it, and asks you to confirm
   it is right. Detects whether the keys are an unencrypted pair or an
   encrypted bundle.
2. **Installs `git`** if `dpkg` does not already report it installed. Installs
   `gnupg` too, but only when the keys are encrypted and it is actually needed.
3. **Creates `/opt/git`**, chowns it to the invoking user and sets mode `774`.
   This is where project repositories are expected to live.
4. **Creates `~/.ssh`** at mode `700` if it does not exist. SSH refuses to use
   the directory otherwise.
5. **Installs the keypair** into `~/.ssh`, private key `600`, public key `644`.
6. **Writes `~/.ssh/config.d/10-github.conf`** and prepends an `Include` for it
   to `~/.ssh/config`, both at `600` — SSH silently ignores a config file with
   looser permissions. A stanza appended to `~/.ssh/config` by an older version
   is removed, so the host is defined in exactly one place.
7. **Pins GitHub's Ed25519 host key** in `~/.ssh/known_hosts`.
8. **Sets git's global configuration** — identity plus a handful of defaults.
9. **Verifies** by running `ssh -T` against GitHub and checking the greeting.

## Key sources

The key directory may contain either form. The script detects which and does
the right thing without being told.

| What is in `--keys-dir` | Behaviour |
|---|---|
| `git@github.com` and `git@github.com.pub` | Used directly. No passphrase needed. |
| `keys.tar.gpg` | Decrypted with a passphrase you are prompted for. |
| Both | The unencrypted pair is used, and a warning is printed. |
| Neither | Aborts, naming both of the layouts it looked for. |

### Creating the encrypted bundle

`keys.tar.gpg` is an ordinary `tar` of the two key files, encrypted with GnuPG's
symmetric mode. From the directory holding the keys:

```sh
tar -cf - git@github.com git@github.com.pub \
  | gpg --symmetric --cipher-algo AES256 --digest-algo SHA512 \
        --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
        -o keys.tar.gpg
```

The algorithm flags are explicit rather than left to the defaults. Current
GnuPG already chooses AES256 and SHA512 for symmetric encryption, but 2.0-era
releases defaulted to AES128 and SHA1, and the bundle may well outlive the
machine that made it.

Encrypting the bundle protects the keys **at rest on the removable media**. It
does not protect them on the machine you bootstrap: once installed, the private
key sits unencrypted at `~/.ssh/git@github.com`, mode `600`, exactly as it
would have if you had carried it in the clear. If you want the key protected
everywhere, put a passphrase on the key itself with `ssh-keygen -p`, and accept
the prompt on every use or load it into an agent.

## Passphrase entry, and headless machines

The passphrase is read directly from the terminal and handed to `gpg` on a file
descriptor. GnuPG's own `pinentry` is deliberately not used.

That matters on a server. `pinentry` may be absent on a minimal install, or
`gpg-agent` may be configured for a GUI variant such as `pinentry-gtk2`, which
needs a `DISPLAY` that a plain SSH session does not have. The resulting failure
is obscure — usually `Inappropriate ioctl for device` — and has nothing
obviously to do with the passphrase. Reading it here instead means the script
behaves identically on a headless box and on a desktop.

Two details follow from the same concern:

- The prompt reads from `/dev/tty`, not standard input, so it still works when
  stdin is a pipe.
- The passphrase is passed as `--passphrase-fd`, never `--passphrase`. Command
  line arguments are visible to any user running `ps`.

Decryption is streamed — `gpg --decrypt | tar -x` under `umask 077`. No
plaintext tar is ever written to disk, and the extracted private key is created
with mode `600` rather than being created loose and tightened afterwards, so
there is no window in which it is world-readable.

If the passphrase is wrong the run aborts with a plain message and nothing is
left behind in `~/.ssh`.

## Options

| Option | Meaning |
|---|---|
| `--keys-dir DIR` | Where to read the keypair from. Defaults to the directory holding the script. |
| `--non-interactive` | Never prompt. See the environment variables below. |
| `-h`, `--help` | Usage summary. |

## Environment

| Variable | Used for |
|---|---|
| `GIT_USER_NAME` | `git config --global user.name`. Prompted for if unset. |
| `GIT_USER_EMAIL` | `git config --global user.email`. Prompted for if unset. |
| `GPG_PASSPHRASE` | Passphrase for `keys.tar.gpg`. Prompted for if unset. |

When set, these become the defaults offered at the interactive prompts.

With `--non-interactive`, the ones that apply are **required**, and the script
aborts naming them if they are missing. It deliberately does not fall back to a
placeholder identity: a wrong `user.email` produces no error at any later point,
it just quietly detaches every commit you make from your GitHub account. Failing
at setup is cheaper than discovering that weeks later.

## What it writes

| Path | Mode | Notes |
|---|---|---|
| `/opt/git` | `774` | Created if absent; chowned to the invoking user. |
| `~/.ssh` | `700` | Created if absent. |
| `~/.ssh/git@github.com` | `600` | The private key. |
| `~/.ssh/git@github.com.pub` | `644` | The public key. |
| `~/.ssh/config` | `600` | Gains an `Include` line, prepended. Existing content preserved. |
| `~/.ssh/config.d/10-github.conf` | `600` | The GitHub stanza. Owned by the script and overwritten wholesale. |
| `~/.ssh/known_hosts` | `644` | Appends GitHub's pinned Ed25519 key. |
| `~/.gitconfig` | — | Via `git config --global`. |

The stanza it writes:

```
# Managed by bash-includes (git.sh) — this file is overwritten.
Host github
    HostName github.com
    User git
    IdentityFile ~/.ssh/git@github.com
    IdentitiesOnly yes
    AddKeysToAgent no
    HostKeyAlgorithms ssh-ed25519
```

It lives in its own file rather than being appended, because an append cannot
*update*: the usual grep-for-a-sentinel idiom skips on every machine that has
already run, so changing a directive later would silently do nothing. Owning a
whole file means the stanza is always exactly what the code says. The `Include`
is prepended rather than appended because ssh takes the first value it obtains
for most keywords.

`IdentitiesOnly yes` stops SSH offering other loaded keys before this one, which
matters if you have several and GitHub starts rejecting attempts before reaching
the right key. `HostKeyAlgorithms ssh-ed25519` constrains the connection to the
one host key type that is actually pinned below.

The block is keyed on the alias `github`, so remotes are written in the short
form:

```sh
git clone github:ksgill/some-repo
```

SSH matches `Host` patterns against the literal string in the remote, not
against whatever it resolves to, so the alias is the interface: a full
`git@github.com:owner/repo.git` URL does **not** match this block and falls
through to the default identity list. Host key verification is unaffected —
`known_hosts` is keyed on the resolved `HostName`, so the pin below still
applies when you connect through the alias.

That is a deliberate choice rather than an oversight. GitHub's web UI hands out
full `git@github.com:` URLs, so if you prefer those to work too, add the second
pattern:

```
Host github github.com
```

The git settings applied are `user.name`, `user.email`, `submodule.recurse`,
`clone.recurseSubmodules`, `push.default current`, and
`push.autoSetupRemote true`. The last of these is why a first push needs no
`-u origin HEAD` incantation.

## Host key pinning

GitHub's Ed25519 host key is written into `~/.ssh/known_hosts` before the first
connection, and verification then runs with `StrictHostKeyChecking=yes`.

The alternative, `accept-new`, is trust-on-first-use: it silently accepts a host
it has never seen, records the key, and only objects if it later changes. On a
freshly installed machine `known_hosts` is empty, so *every* run is a first
connection — precisely the unprotected case. Pinning removes that window
entirely.

The pinned key is:

```
SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU
```

It was taken from `https://api.github.com/meta`, which is authenticated by TLS,
and cross-checked against `ssh-keyscan`. `ssh-keyscan` alone would not do — it
is itself trust-on-first-use, so pinning its output would only move the problem
rather than solve it.

`pin_host_key` re-derives the fingerprint from the key at run time and aborts on
a mismatch, so a typo in the constant cannot be pinned silently. An existing
`github.com` entry — a stale one, or one picked up earlier by TOFU — is removed
and replaced rather than left to collide. Entries for other hosts are untouched.

Only the Ed25519 key is pinned. GitHub also serves RSA and ECDSA host keys;
those are deliberately excluded, and the `HostKeyAlgorithms` line in the SSH
block keeps the connection from negotiating them.

**When GitHub rotates this key, every run will fail loudly** with
`REMOTE HOST IDENTIFICATION HAS CHANGED`. That is the intended behaviour, but it
does mean the constant needs maintaining: re-check `https://api.github.com/meta`
and update `GITHUB_HOST_KEY` and `GITHUB_HOST_FPR` together. GitHub last rotated
its RSA host key in March 2023 after it was briefly exposed, so this is not a
hypothetical.

## Re-running

Safe. The script is idempotent in the places that matter:

- The SSH config block is skipped if one is already present.
- The host key pin is skipped if the exact key is already in `known_hosts`.
- Package installs are skipped if `dpkg` reports the package installed.
- Overwriting an existing private key asks first, and aborts if you decline.

## Building

The shared parts — git identity, the ssh stanza, the host key pin — live in
[bash-includes](https://github.com/ksgill/bash-includes), so that
`git-bootstrap` and `sys-bld` cannot drift apart on them. The pinned host key in
particular exists in one place, which matters because GitHub will eventually
rotate it.

`build.sh` inlines the library into `dist/git-bootstrap.sh`:

```sh
./build.sh                                   # clones the tag in LIB_VERSION
BASH_INCLUDES_DIR=../bash-includes/lib ./build.sh   # or use a local checkout
```

Building needs the network and the library. Running the artifact needs neither.
Commit the source and the rebuilt `dist/` as separate commits — the version
stamp is taken from the working tree, so building with uncommitted changes
marks the artifact `-dirty` and CI rejects it.

## Requirements

- Ubuntu or Debian, or anything else with `apt-get` and `dpkg`.
- `bash`, `tar`, `ssh`, `ssh-keygen` — all present on a stock install.
- `sudo` rights for the invoking user. Passwordless sudo is not required; the
  script prompts per command as normal. It is used only to install packages and
  to create `/opt/git` — locating and reading the keys needs no elevation when
  the key directory is readable by you, which is the normal case.
- `gnupg`, installed automatically, and only when the keys are encrypted.

## Keys and this repository

The keypair must never end up in a clone of this repo. Two things prevent it:

- `--keys-dir` means the keys have no reason to be here at all. Point it at the
  removable volume.
- `.gitignore` covers the key filenames, `id_*`, `*.pem`, `*.key`, `*.gpg`,
  `*.asc` and `keys.tar*` as a backstop, so a stray copy cannot be committed by
  a careless `git add -A`.

This repository is public. Treat the second layer as insurance, not permission.

## What it does not do

- Clone your project repositories. That is deliberate — clone what you want,
  when you want it.
- Generate a keypair. It installs one you already have. Use
  `ssh-keygen -t ed25519` if you need a new one, and add the public half to
  GitHub yourself.
- Copy any credential other than the keypair you point it at.
- Install anything beyond `git` and, conditionally, `gnupg`.

## Licence

None specified.
