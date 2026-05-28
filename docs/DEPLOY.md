# Deploy guide

End-to-end provisioning of a fresh Hetzner CCX13 (or any 4 vCPU / 8 GB
Ubuntu 24.04 box) to a live TLS-protected EVM Oracle Demo deployment.

Target time from blank image to dashboard reachable on HTTPS: **15 minutes**
(NFR-06).

## 1. Pre-flight on your laptop

You need:

- A registered domain or subdomain you can attach an A record to.
- A local clone of this repo with submodules.
- An SSH key pair (`~/.ssh/id_ed25519` works fine).
- Free-tier API keys for: The Graph Gateway (Uniswap V3 subgraph),
  Alpha Vantage, Twelve Data. CoinGecko / Binance public / Stooq need
  no keys.
- A chain RPC endpoint that supports WebSockets — Alchemy / Infura / Ankr
  / public node (rate-limited). Both `wss://` and `https://` URLs.
- Three reporter EOAs whose addresses are registered on `ReporterSet`
  on chain. Generate locally with `scripts/rotate-reporters.sh
  --secrets-dir ./secrets`; the script prints the addresses to register.

## 2. Spin up the VPS

Provider-specific. Example for Hetzner Cloud:

```bash
hcloud server create --type ccx13 --image ubuntu-24.04 \
    --location nbg1 --ssh-key <your-key-name> --name lighthouse-demo
```

Note the public IPv4 + IPv6.

## 3. Point DNS at the VPS

Create an A (and AAAA if you have IPv6) record for your apex/subdomain
pointing at the VPS. Caddy needs the DNS to resolve before it can issue
the Let's Encrypt cert via HTTP-01.

```
lighthouse-oracle.example.com   A    198.51.100.42
lighthouse-oracle.example.com   AAAA 2001:db8::42
```

Wait for propagation (`dig lighthouse-oracle.example.com` returns the new
IP).

## 4. Bootstrap the VPS

```bash
scp scripts/bootstrap-vps.sh root@198.51.100.42:/root/
ssh root@198.51.100.42 \
    "bash /root/bootstrap-vps.sh --ssh-pubkey \"$(cat ~/.ssh/id_ed25519.pub)\""
```

What this does:

- `apt update && upgrade` (security patches).
- Installs docker-ce, docker-compose-plugin, ufw, fail2ban,
  unattended-upgrades, jq, make, git.
- Creates the `deploy` user with passwordless sudo + your SSH key.
- Sets up the `/etc/lighthouse/{secrets,backup}/` tree owned by `deploy`.
- Opens 22/80/443 in ufw; denies everything else inbound.
- Enables fail2ban with the default SSH jail.
- Disables root + password SSH logins.

Idempotent — re-running is safe.

## 5. Place secrets + .env on the VPS

```bash
# Copy the env template and edit it locally before uploading.
cp docker/env.example /tmp/lighthouse.env
$EDITOR /tmp/lighthouse.env

# Upload as the deploy user.
scp /tmp/lighthouse.env deploy@198.51.100.42:/etc/lighthouse/.env
ssh deploy@198.51.100.42 'sudo chmod 0400 /etc/lighthouse/.env'

# Upload the three reporter keys. These were emitted by rotate-reporters.sh
# locally; their addresses must already be in ReporterSet on chain.
for n in 1 2 3; do
    scp ./secrets/reporter${n}.key deploy@198.51.100.42:/tmp/
    ssh deploy@198.51.100.42 \
        "sudo install -o deploy -g deploy -m 0400 /tmp/reporter${n}.key /etc/lighthouse/secrets/"
    ssh deploy@198.51.100.42 "rm /tmp/reporter${n}.key"
done
```

## 6. Clone + deploy

```bash
ssh deploy@198.51.100.42
sudo install -d -o deploy -g deploy /opt/lighthouse
git clone --recursive git@github.com:asolovov/evm-oracle-demo-infra.git /opt/lighthouse
cd /opt/lighthouse
./scripts/deploy.sh
```

`deploy.sh` defaults to the prod compose overrides (image pulls from GHCR,
resource limits applied). On first run it will:

1. `git pull` + `git submodule update --init --recursive --remote`.
2. `docker compose pull` — fetches images for all 4 services + Caddy.
3. `docker compose up -d --remove-orphans`.
4. `docker compose ps` — final status.

For local-build dev, pass `--build`.

## 7. Verify

```bash
# Postgres created the 3 DBs on first start.
ssh deploy@198.51.100.42 'docker exec oracle-postgres \
    psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false"'
# Expected: postgres, evm_price, evm_oracle, evm_indexer

# Healthchecks.
curl -fsS https://lighthouse-oracle.example.com/healthz
# Expected: 200 OK with author metadata.

# Live tail.
ssh deploy@198.51.100.42 'cd /opt/lighthouse && \
    docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml logs -f --tail=50'
```

## 8. Register assets on chain

If the contracts repo was deployed and assets registered as part of task 04,
**skip this**. Otherwise:

```bash
cd /opt/lighthouse/repos/evm-oracle-demo-contracts
npx hardhat run scripts/register-assets.ts --network ethereum-sepolia
```

`scripts/seed-assets.sh --emit-env-map` extracts the deployed aggregator
addresses as the `CHAIN_AGGREGATOR_ADDRESSES` JSON map for `.env`.

## 9. Schedule nightly backup

```bash
ssh deploy@198.51.100.42
crontab -e
# add:
# 0 4 * * * /opt/lighthouse/scripts/backup.sh >> /var/log/lighthouse-backup.log 2>&1
```

## Schema migrations

Migrations live in each service submodule (`repos/<svc>/migrations/` or
`repos/evm-oracle-demo-oracle-service/db/migrations/`). The service
binaries don't apply them — infra does.

Three one-shot containers in `docker/docker-compose.yml`
(`price-migrate`, `oracle-migrate`, `indexer-migrate`) run
`migrate/migrate:v4.18.1` against each database with the submodule's SQL
files volume-mounted read-only. Each runs `migrate up`, exits 0, and
unblocks the corresponding service via `depends_on:
condition: service_completed_successfully`.

Idempotent — `schema_migrations` tracks applied versions per database.
Re-running `docker compose up` (or `deploy.sh`) is a no-op once the
migrations land.

To roll back manually:

```bash
docker compose run --rm price-migrate \
    -path=/migrations \
    -database="postgres://price_user:${PRICE_DB_PASSWORD}@postgres:5432/evm_price?sslmode=disable" \
    down 1
```

To bump migration tooling, change the pinned tag on all three sidecars
in one go (`migrate/migrate:vX.Y.Z`).

## Submodule pinning workflow

Submodule pointers in this repo capture an exact SHA per submodule. To bump
a submodule to its tracking branch's tip:

```bash
# On your laptop:
cd /Users/asolovov/projects/upwork/evm-oracle-demo-infra
make submodules-update           # fetches remote tips
git status                       # shows submodules with bumped SHAs
git add repos/evm-oracle-demo-<svc>
git commit -m "chore(submodules): bump <svc> to <short-sha>"
```

On the VPS, `deploy.sh` runs `git submodule update --init --recursive
--remote` so a fresh `deploy.sh` invocation also bumps pins. To deploy a
specific committed SHA only, drop the `--remote` flag in `deploy.sh`.

## Frontend wiring (post task 09)

Once `evm-oracle-demo-frontend` exists:

1. `git submodule add git@github.com:asolovov/evm-oracle-demo-frontend.git \
   repos/evm-oracle-demo-frontend`.
2. Uncomment the placeholder block in `docker/docker-compose.yml` (add a
   `frontend` service with `build: ../repos/evm-oracle-demo-frontend`).
3. Replace the `respond` placeholder in `docker/Caddyfile` with
   `reverse_proxy frontend:3000`.
4. Add `IMAGE_TAG_FRONTEND` to `docker/env.example` and a matching
   `image: ghcr.io/asolovov/evm-oracle-demo-frontend:${IMAGE_TAG_FRONTEND}`
   override in `docker/docker-compose.prod.yml`.
