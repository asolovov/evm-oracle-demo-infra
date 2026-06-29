#!/usr/bin/env bash
# Creates the 3 per-service databases + users for the EVM Oracle Demo.
#
# Runs once on first postgres container start (postgres image executes
# every *.sh and *.sql in /docker-entrypoint-initdb.d/ alphabetically).
# Subsequent restarts skip this directory entirely because the data
# directory is already initialised.
#
# Architecture rule 7: one service = one database. rest-api uses Redis
# only (no relational DB; documented exception in its README).
#
# Per-service passwords come in from compose env vars
# (PRICE_DB_PASSWORD / ORACLE_DB_PASSWORD / INDEXER_DB_PASSWORD).
set -euo pipefail

: "${PRICE_DB_PASSWORD:?PRICE_DB_PASSWORD must be set}"
: "${ORACLE_DB_PASSWORD:?ORACLE_DB_PASSWORD must be set}"
: "${INDEXER_DB_PASSWORD:?INDEXER_DB_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
    CREATE USER price_user WITH PASSWORD '${PRICE_DB_PASSWORD}';
    CREATE DATABASE evm_price OWNER price_user;
    GRANT ALL PRIVILEGES ON DATABASE evm_price TO price_user;

    CREATE USER oracle_user WITH PASSWORD '${ORACLE_DB_PASSWORD}';
    CREATE DATABASE evm_oracle OWNER oracle_user;
    GRANT ALL PRIVILEGES ON DATABASE evm_oracle TO oracle_user;

    CREATE USER indexer_user WITH PASSWORD '${INDEXER_DB_PASSWORD}';
    CREATE DATABASE evm_indexer OWNER indexer_user;
    GRANT ALL PRIVILEGES ON DATABASE evm_indexer TO indexer_user;
EOSQL

echo "[postgres-init] created evm_price / evm_oracle / evm_indexer with role-scoped users"
