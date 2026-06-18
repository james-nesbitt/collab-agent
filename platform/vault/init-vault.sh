#!/usr/bin/env bash
# init-vault.sh — create a PASSPHRASE-PROTECTED omp-vault GPG key + pass store
# on the VM. Installed by `manager.sh setup --passphrase` and run there.
#
# Reads the passphrase from stdin (one line). The passphrase is NEVER written to
# disk and NEVER passed as an argument: the GPG key params file carries no
# passphrase, and gpg reads it via loopback from a pipe fed by the in-memory
# value. Idempotent: if the store already exists it prints VAULT_EXISTS and exits
# without touching it.
set -e

VDIR="$HOME/.omp-vault"
export GNUPGHOME="$VDIR/gnupg" PASSWORD_STORE_DIR="$VDIR/store"

if [ -d "$PASSWORD_STORE_DIR" ]; then
    echo VAULT_EXISTS
    exit 0
fi

IFS= read -r PP || true
[ -n "$PP" ] || { echo "init-vault: empty passphrase on stdin" >&2; exit 1; }

mkdir -p "$GNUPGHOME"
chmod 700 "$VDIR" "$GNUPGHOME"

# gpg-agent must allow preset passphrases so a detached session launcher can
# decrypt without a pinentry prompt; bound how long a preset lingers in memory.
cat > "$GNUPGHOME/gpg-agent.conf" <<'CONF'
allow-preset-passphrase
default-cache-ttl 120
max-cache-ttl 120
CONF
gpgconf --kill gpg-agent 2>/dev/null || true

KP="$(mktemp)"
cat > "$KP" <<'KPARAMS'
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: ecdh
Subkey-Curve: cv25519
Name-Real: omp-vault
Name-Email: omp-vault@local
Expire-Date: 0
%commit
KPARAMS
printf '%s' "$PP" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --gen-key "$KP"
rm -f "$KP"

KID="$(gpg --list-keys --with-colons omp-vault@local | awk -F: '/^pub/{print $5; exit}')"
[ -n "$KID" ] || { echo "init-vault: key generation failed" >&2; exit 1; }
pass init "$KID" >/dev/null

touch "$VDIR/.passphrase-protected"
echo VAULT_OK
