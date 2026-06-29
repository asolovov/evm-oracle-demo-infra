#!/usr/bin/env bash
# seed-assets.sh — register the 10 demo assets in OracleRegistry on chain.
#
# Reads aggregator addresses + asset IDs from the contracts repo's
# deployments/<chain>/<file>.json and calls OracleRegistry.registerAsset
# for each entry that isn't yet registered. Idempotent: a second run is a
# no-op once every asset is registered.
#
# Requires:
#   * hardhat workspace at repos/evm-oracle-demo-contracts/
#   * .env file with DEPLOYER_PRIVATE_KEY + CHAIN_RPC_URL
#
# Architecture rule 8: bootstrap is normally inside the application. This
# script is the one exception — registry seeding is on-chain state, not
# database state, so it doesn't fit the rule-8 pattern. It runs once per
# deploy and is harmless to re-run.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONTRACTS_DIR="${REPO_ROOT}/repos/evm-oracle-demo-contracts"
CHAIN_NAME="${CHAIN_NAME:-ethereum-sepolia}"
DEPLOYMENT_FILE="${CONTRACTS_DIR}/deployments/${CHAIN_NAME}"

usage() {
    cat <<EOF
Usage: seed-assets.sh [--chain <name>] [--emit-env-map]

Registers the 10 demo assets in OracleRegistry on the target chain.

Options:
  --chain <name>     Chain key under contracts/deployments/. Default:
                     ethereum-sepolia (matches deployed state).
  --emit-env-map     Print the CHAIN_AGGREGATOR_ADDRESSES JSON map for
                     the .env file and exit. Useful after a fresh deploy.
EOF
}

EMIT_ENV_MAP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain)
            CHAIN_NAME="$2"
            DEPLOYMENT_FILE="${CONTRACTS_DIR}/deployments/${CHAIN_NAME}"
            shift 2
            ;;
        --emit-env-map)
            EMIT_ENV_MAP=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! -d "${DEPLOYMENT_FILE}" ]]; then
    echo "deployment directory not found: ${DEPLOYMENT_FILE}" >&2
    echo "Available chains:" >&2
    ls "${CONTRACTS_DIR}/deployments/" 2>/dev/null || echo "  (none)" >&2
    exit 1
fi

# Latest JSON dump in the deployment dir (lexicographic sort works for
# timestamped filenames).
JSON_FILE="$(find "${DEPLOYMENT_FILE}" -maxdepth 1 -name '*.json' | sort | tail -1)"
if [[ -z "${JSON_FILE}" ]]; then
    echo "no *.json deployment file found in ${DEPLOYMENT_FILE}" >&2
    exit 1
fi

log() { echo "[seed-assets] $*"; }
log "using deployment file: ${JSON_FILE}"

if [[ "${EMIT_ENV_MAP}" -eq 1 ]]; then
    # Lower-case symbol -> aggregator address, JSON object on one line.
    jq -c '
        .aggregators
        | map({ key: (.symbol | ascii_downcase), value: .address })
        | from_entries
    ' "${JSON_FILE}"
    exit 0
fi

# Defer to the hardhat task in the contracts repo. The repo ships a script
# `scripts/register-assets.ts` that reads the same JSON file and calls
# registerAsset for each missing entry.
if [[ ! -f "${CONTRACTS_DIR}/scripts/register-assets.ts" ]]; then
    cat >&2 <<EOF
contracts repo does not expose scripts/register-assets.ts yet.

Bridge it by running the equivalent hardhat task manually:
    cd ${CONTRACTS_DIR}
    npx hardhat run scripts/register-assets.ts --network ${CHAIN_NAME}

Or re-run with --emit-env-map to extract the aggregator address map for
direct use in CHAIN_AGGREGATOR_ADDRESSES.
EOF
    exit 1
fi

cd "${CONTRACTS_DIR}"
log "running hardhat register-assets on ${CHAIN_NAME}"
npx hardhat run scripts/register-assets.ts --network "${CHAIN_NAME}"
