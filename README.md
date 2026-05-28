# evm-oracle-demo-infra

Single-VPS deploy umbrella for the **EVM Oracle Demo** — a pull-based,
multi-source price oracle covering five crypto + five RWA assets in USD on
Ethereum Sepolia. This repo is the operational layer: it pins every other
repo as a git submodule and ships the docker-compose stack, TLS-terminating
reverse proxy, bootstrap script, deploy script, and operational docs that
turn a blank Ubuntu 24.04 box into a live TLS-protected dashboard in under
fifteen minutes.

> **Demo, not production.** Reporter signing keys live on disk; freshness
> ages flow through the dashboard but never gate updates; there is one VPS,
> no HA, no audit. The codebase documents what would change for production
> (see [`docs/SECURITY.md`](docs/SECURITY.md)).

## Repository layout

```
evm-oracle-demo-infra/
├── repos/                                # git submodules (pinned to SHAs)
│   ├── evm-oracle-demo-contracts/        # Solidity + Hardhat
│   ├── evm-oracle-demo-protocols/        # protobuf IDL
│   ├── evm-oracle-demo-price-service/    # off-chain aggregation
│   ├── evm-oracle-demo-oracle-service/   # on-chain submitter
│   ├── evm-oracle-demo-indexer-service/  # chain observer + StreamEvents
│   └── evm-oracle-demo-api/              # public REST + WS BFF
├── docker/
│   ├── docker-compose.yml                # dev defaults
│   ├── docker-compose.prod.yml           # GHCR pulls + resource limits
│   ├── Caddyfile                         # TLS reverse proxy
│   ├── env.example                       # template — copy to .env
│   └── postgres-init/01-init.sh          # 3 DBs + 3 users on first start
├── scripts/
│   ├── bootstrap-vps.sh                  # provision a blank Ubuntu 24.04
│   ├── deploy.sh                         # pull + up on the VPS
│   ├── seed-assets.sh                    # register the 10 assets on chain
│   ├── rotate-reporters.sh               # generate fresh reporter keys
│   └── backup.sh                         # nightly pg_dump + B2 upload
├── docs/
│   ├── DEPLOY.md
│   ├── SECURITY.md
│   └── TROUBLESHOOTING.md
├── .github/workflows/                    # CI: compose validate + shellcheck
└── Makefile
```

Frontend (`evm-oracle-demo-frontend`) is intentionally absent — task 09
hasn't shipped yet. Once it exists, add it as a submodule and uncomment the
`frontend` service in `docker/docker-compose.yml` + `docker/Caddyfile`.

## Quick start (local dev)

```bash
git clone --recursive git@github.com:asolovov/evm-oracle-demo-infra.git
cd evm-oracle-demo-infra
cp docker/env.example docker/.env
# edit docker/.env — fill CHAIN_WS_URL + CHAIN_RPC_URL + the API keys you have
make submodules
mkdir -p secrets
# write reporter1.key reporter2.key reporter3.key into ./secrets/
# (use scripts/rotate-reporters.sh --secrets-dir ./secrets for fresh keys)
make config           # validates compose YAML
make up-build         # build images + bring stack up
make logs             # tail every container

# rest-api on the host:
curl http://localhost:8080/api/v1/assets
```

**Caddy is opt-in locally.** The dev stack publishes `rest-api` directly
on `http://localhost:8080` so you can hit the REST surface without TLS.
To exercise the production-style TLS terminator:

```bash
docker compose -f docker/docker-compose.yml --profile tls up -d caddy
# https://localhost:443/api/v1/assets   (Caddy's internal CA — browser warning)
```

See [`docs/DEPLOY.md`](docs/DEPLOY.md) for the full production deploy
(Caddy is always on in prod via `docker-compose.prod.yml`).

## Architecture rules this repo enforces

The Go services follow the shared `andskur/go-microservice-template`
constraints (one binary per service, env-var-driven config, one database per
service, env-driven bootstrap). This repo translates those constraints into
operational shape:

- **Three Postgres databases, one instance** — `evm_price`, `evm_oracle`,
  `evm_indexer`. `rest-api` uses Redis only (no relational state). See
  `docker/postgres-init/01-init.sh`.
- **Migrations are infra's responsibility, not the services'.** The Go
  binaries don't link any migration library. This repo runs three
  one-shot `migrate/migrate` sidecars (`price-migrate`, `oracle-migrate`,
  `indexer-migrate`) that mount each submodule's `migrations/` directory
  read-only and run `migrate up` against the matching database. Services
  depend on the sidecar with `condition: service_completed_successfully`.
- **Generated code never committed** — every service Dockerfile installs
  pinned codegen tools (buf v1.55.0, protoc-gen-go v1.36.0,
  protoc-gen-go-grpc v1.5.1) and regenerates stubs on build.

## CI

`.github/workflows/compose-validate.yml` runs on every push:

- `docker compose config` against the dev + prod overrides.
- `shellcheck` against every bash script.
- All third-party actions are SHA-pinned per Gateway org policy.

## Author

Built by **Andrei Solovov** (Gateway.fm).

- LinkedIn — [in/andrei-solovov](https://www.linkedin.com/in/andrei-solovov/)
- GitHub — [@asolovov](https://github.com/asolovov)
- Upwork — link gated on `NEXT_PUBLIC_UPWORK_URL` in the frontend env

License: MIT.
