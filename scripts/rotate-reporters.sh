#!/usr/bin/env bash
# rotate-reporters.sh — generate 3 fresh reporter EOAs and write their
# private keys to the secrets directory. Prints the corresponding public
# addresses so the operator can register them via ReporterSet.
#
# This script does NOT make any on-chain calls. The operator must follow up
# with the contracts repo's reporter-set rotation script to call
# ReporterSet.addReporter / removeReporter on chain.
#
# Architecture: rule 8 deviation. Reporter rotation is a key-management
# action, not a runtime config change — it cannot be bootstrapped by an
# env-var on container start (you'd lose the previous keys' signatures
# mid-rotation). Manual + explicit by design.
#
# Security: this writes plaintext private keys to disk. The keys are mode
# 0400 owned by the deploy user. Production-grade would use HSM or KMS;
# the demo is explicit about the tradeoff in docs/SECURITY.md.

set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-/etc/lighthouse/secrets}"
OWNER="${SECRETS_OWNER:-deploy:deploy}"
COUNT=3

usage() {
    cat <<EOF
Usage: rotate-reporters.sh [--secrets-dir <path>] [--owner <user:group>] [--count <N>]

Generates N (default 3) fresh secp256k1 keys, writes them as reporter*.key
files (mode 0400) in the secrets directory, and prints the matching public
EVM addresses. Does NOT call ReporterSet on chain.

Required tools: openssl, python3 with eth_keys (or 'cast wallet new' from
foundry, auto-detected).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --secrets-dir) SECRETS_DIR="$2"; shift 2 ;;
        --owner)       OWNER="$2"; shift 2 ;;
        --count)       COUNT="$2"; shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ ! -d "${SECRETS_DIR}" ]]; then
    echo "secrets directory does not exist: ${SECRETS_DIR}" >&2
    echo "run bootstrap-vps.sh first (creates /etc/lighthouse tree)" >&2
    exit 1
fi

log() { echo "[rotate-reporters] $*"; }

emit_key() {
    # Outputs "<priv_hex>\t<addr>" for one fresh EOA. Prefers `cast` if
    # available because it ships with foundry on every dev box; falls back
    # to python+eth_keys.
    if command -v cast >/dev/null 2>&1; then
        cast wallet new --json | jq -r '.[] | "\(.private_key)\t\(.address)"'
        return
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import eth_keys' 2>/dev/null; then
        python3 - <<'PY'
import os
from eth_keys import keys
priv = os.urandom(32)
pk = keys.PrivateKey(priv)
print(f"{priv.hex()}\t{pk.public_key.to_checksum_address()}")
PY
        return
    fi
    echo "neither 'cast' (foundry) nor python3+eth_keys is available" >&2
    exit 1
}

declare -a ADDRESSES=()

log "generating ${COUNT} fresh reporter keys into ${SECRETS_DIR}"
for i in $(seq 1 "${COUNT}"); do
    KEY_FILE="${SECRETS_DIR}/reporter${i}.key"
    if [[ -f "${KEY_FILE}" ]]; then
        echo "${KEY_FILE} already exists; refusing to overwrite" >&2
        exit 1
    fi
    out=$(emit_key)
    priv=$(echo "${out}" | cut -f1)
    addr=$(echo "${out}" | cut -f2)
    # Store the 0x-prefixed hex private key — what oracle-service expects.
    if [[ "${priv}" != 0x* ]]; then
        priv="0x${priv}"
    fi
    umask 0277
    echo "${priv}" > "${KEY_FILE}"
    chmod 0400 "${KEY_FILE}"
    chown "${OWNER}" "${KEY_FILE}"
    ADDRESSES+=("${addr}")
done

log "wrote ${COUNT} key files."
log ""
log "new reporter addresses (register on chain via ReporterSet.addReporter):"
for i in "${!ADDRESSES[@]}"; do
    echo "  reporter$((i + 1)): ${ADDRESSES[$i]}"
done
log ""
log "next steps:"
log "  1. add all new addresses to ReporterSet on chain"
log "  2. remove the previous reporter addresses from ReporterSet"
log "  3. update SIGNER_REPORTER_KEY_PATHS in .env if file count changed"
log "  4. restart oracle-service: scripts/deploy.sh --restart"
