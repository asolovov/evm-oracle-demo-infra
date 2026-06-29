#!/usr/bin/env bash
# backup.sh — nightly pg_dump of the 3 service databases. Designed to be
# called from cron on the VPS as the deploy user:
#
#     0 4 * * * /opt/lighthouse/scripts/backup.sh >> /var/log/lighthouse-backup.log 2>&1
#
# Dumps go to BACKUP_DIR (local) and are optionally uploaded to Backblaze B2
# via the b2 CLI if B2_BUCKET is set. Retention: keeps the last RETAIN_DAYS
# locally; B2 lifecycle policy handles remote retention.

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/etc/lighthouse/backup}"
RETAIN_DAYS="${RETAIN_DAYS:-7}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-evm-oracle-demo}"
B2_BUCKET="${B2_BUCKET:-}"

DATABASES=("evm_price" "evm_oracle" "evm_indexer")
TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

log() { echo "[backup] $(date -u -Iseconds) $*"; }

if [[ ! -d "${BACKUP_DIR}" ]]; then
    echo "backup directory not found: ${BACKUP_DIR}" >&2
    exit 1
fi

# pg_dump runs inside the postgres container so we don't need libpq on the
# host. docker exec is invoked through the deploy user; the user must be in
# the docker group (set up by bootstrap-vps.sh).
for db in "${DATABASES[@]}"; do
    out="${BACKUP_DIR}/${db}-${TIMESTAMP}.sql.gz"
    log "dumping ${db} -> ${out}"
    docker exec -i "${COMPOSE_PROJECT}-postgres-1" \
        pg_dump --no-owner --clean --if-exists "${db}" \
        | gzip -9 > "${out}"
done

# Prune old local copies.
log "pruning local backups older than ${RETAIN_DAYS} days"
find "${BACKUP_DIR}" -type f -name '*.sql.gz' -mtime "+${RETAIN_DAYS}" -delete

# Off-host upload (optional).
if [[ -n "${B2_BUCKET}" ]]; then
    if ! command -v b2 >/dev/null 2>&1; then
        echo "B2_BUCKET set but b2 CLI not installed; skipping remote upload" >&2
        exit 0
    fi
    for db in "${DATABASES[@]}"; do
        out="${BACKUP_DIR}/${db}-${TIMESTAMP}.sql.gz"
        log "uploading ${out} -> b2://${B2_BUCKET}/"
        b2 file upload "${B2_BUCKET}" "${out}" "$(basename "${out}")" >/dev/null
    done
fi

log "backup complete"
