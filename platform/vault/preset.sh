#!/usr/bin/env bash
# preset.sh — preset the omp-vault passphrase into gpg-agent so a detached
# session launcher can decrypt with `pass show` and no pinentry prompt.
# Installed by `manager.sh setup --passphrase`; run by `manager.sh new` just
# before launching a session against a passphrase-protected vault.
#
# Reads the passphrase from stdin (one line); never writes it to disk or argv.
# Presets every keygrip (primary + encryption subkey) because `pass` decrypts
# with the encryption subkey. The passphrase lives only in gpg-agent memory and
# expires per the agent's max-cache-ttl (set by init-vault.sh).
set -e

export GNUPGHOME="$HOME/.omp-vault/gnupg"

IFS= read -r PP || true
[ -n "$PP" ] || { echo "preset: empty passphrase on stdin" >&2; exit 1; }

BIN="$(gpgconf --list-dirs libexecdir)/gpg-preset-passphrase"
[ -x "$BIN" ] || { echo "preset: gpg-preset-passphrase not found at $BIN" >&2; exit 1; }

gpg --with-keygrip --list-secret-keys omp-vault@local \
    | awk '/Keygrip/{print $3}' \
    | while IFS= read -r KG; do
        printf '%s' "$PP" | "$BIN" --preset "$KG"
    done

echo PRESET_OK
