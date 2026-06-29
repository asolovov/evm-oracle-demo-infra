# Troubleshooting

Operational failure modes and their fixes. New ones are appended over time.

## Edited the Caddyfile but the change didn't take effect

`docker compose up -d caddy` does **not** detect changes to the bind-mounted
`Caddyfile` (compose only diffs the service definition, not mounted file
content), and `docker exec oracle-caddy caddy reload …` has also proven
unreliable here. Force it with a restart:

```bash
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml \
  -f docker/docker-compose.smallbox.yml --env-file docker/.env restart caddy
```

Verify, e.g. that security headers are live:
```bash
curl -sI https://<domain>/ | grep -i strict-transport-security
```

---

## Caddy isn't running in dev — is that expected?

Yes. Caddy is gated behind the `tls` compose profile. The default dev
stack hits `rest-api` directly on `http://localhost:8080`. Bring Caddy up
explicitly only when you want to exercise the production-style TLS
edge:

```bash
docker compose -f docker/docker-compose.yml --profile tls up -d caddy
```

Production (`docker-compose.prod.yml`) always includes Caddy.

---

## Caddy returns the placeholder instead of the dashboard

**Symptom:** `https://<domain>/` shows "EVM Oracle Demo — backend up.
Dashboard pending (task 09)."

**Cause:** The frontend submodule + service isn't wired yet. Until task 09
ships, this is the intended state — only `/healthz`, `/api/*`, and `/ws/*`
have real handlers.

**Fix:** None until task 09 lands. See `docs/DEPLOY.md` § "Frontend wiring
(post task 09)" for the post-09 wiring steps.

---

## Caddy can't issue a Let's Encrypt cert

**Symptom:** `docker logs oracle-caddy` repeats `failed acme transport`,
`incomplete_authorization`, or `urn:ietf:params:acme:error:dns`.

**Cause:** DNS isn't resolving to the VPS yet, or ports 80/443 aren't
open, or the rate limit is hit (5 failed orders per hour per account).

**Fix:**

1. `dig <domain> @8.8.8.8` from your laptop — confirms the A record
   resolves to the VPS public IP.
2. `sudo ufw status` on the VPS — confirms 80 + 443 are allowed.
3. `nc -zv <public-ip> 80` from your laptop — confirms TCP reachability
   from outside the VPS.
4. If rate-limited, wait an hour and retry. For repeated testing set
   `CADDY_EMAIL=internal` in `.env`, which uses Caddy's internal CA
   (browser will warn but TLS works).

---

## Postgres healthcheck fails on first boot

**Symptom:** `docker compose ps` shows `postgres` as `unhealthy`, every
service `depends_on: postgres` is stuck in `Created`.

**Cause:** First boot has to run the init SQL — `pg_isready` succeeds
before `01-init.sh` finishes if the script is slow.

**Fix:** Wait. `start_period: 10s` + `interval: 5s` × `retries: 10`
gives postgres ~60s. Watch `docker logs oracle-postgres` for
`[postgres-init] created evm_price / evm_oracle / evm_indexer`. If it
doesn't appear, `docker exec oracle-postgres cat /docker-entrypoint-initdb.d/01-init.sh`
to confirm the script is present; volume-mounted as readonly so it
shouldn't be modified at runtime.

---

## Service crash-loops with `relation does not exist (SQLSTATE 42P01)`

**Symptom:** `price-service` / `oracle-service` / `indexer-service` logs
`relation "prices_aggregated" does not exist` (or `oracle_submissions`,
or `events`, etc.).

**Cause:** Schema migrations didn't run. Migrations are infra-owned via
the `price-migrate` / `oracle-migrate` / `indexer-migrate` sidecars; if
the sidecar fails or was removed from compose, the service hits empty
DBs.

**Fix:**

```bash
# Check the sidecar exited cleanly.
docker compose -f docker/docker-compose.yml logs price-migrate

# Re-run a specific sidecar.
docker compose -f docker/docker-compose.yml up -d --force-recreate price-migrate

# Confirm schema_migrations state.
docker exec oracle-postgres psql -U postgres -d evm_price \
    -c "SELECT version, dirty FROM schema_migrations"
```

If `dirty=t`, the previous migration failed mid-way — see the
`migrate/migrate` docs on `force` to recover, then re-run.

---

## Service crash-loops with `chain.rpc_url is required`

**Symptom:** `indexer-service` or `oracle-service` keeps restarting; logs
show `invalid configuration: chain.rpc_url is required` even though
`CHAIN_RPC_URL` is set in `.env`.

**Cause:** This is the bug captured in `local/architecture-rules.md` § rule 6:
`viper.AutomaticEnv()` alone does not populate nested keys (`chain.rpc_url`)
on `Unmarshal`. If a key isn't registered via `viper.SetDefault`, viper
returns the zero value.

**Fix:** This is a service-side bug, not an infra bug. Confirm the service
config init runs `viper.SetDefault("chain.rpc_url", "")`. Every service in
this stack should already do this; if a future service crash-loops with
this error, that's the first thing to check.

---

## Oracle-service can't read reporter keys

**Symptom:** `oracle-service` logs `permission denied:
/etc/lighthouse/secrets/reporter1.key` or `signer.allow_insecure_perms is
false and reporter1.key has mode 0644`.

**Cause:** Reporter key file permissions aren't `0400` or the container's
nonroot user can't read them.

**Fix:**

```bash
ssh deploy@<vps>
sudo chown deploy:deploy /etc/lighthouse/secrets/reporter*.key
sudo chmod 0400 /etc/lighthouse/secrets/reporter*.key
sudo chown deploy:deploy /etc/lighthouse/secrets
sudo chmod 0700 /etc/lighthouse/secrets
# oracle-service runs as nonroot uid 65532 inside the container; the host
# files just need read access. Compose mounts the directory read-only, so
# the container's uid mapping doesn't need to match.
cd /opt/lighthouse && ./scripts/deploy.sh --restart
```

In dev with `REPORTER_SECRETS_DIR=./secrets`, the distroless nonroot
user (uid 65532) needs read access on the host file — adjust group
ownership accordingly or set `SIGNER_ALLOW_INSECURE_PERMS=true` (dev
only — never in prod).

---

## `docker compose build` fails inside a service with `make: command not found`

**Symptom:** Builder stage crashes early with `make: command not found` or
`buf: command not found`.

**Cause:** The service's Dockerfile builder stage didn't install codegen
tools. All services in this stack do install them at pinned versions; if a
fork removes them, codegen + build fails.

**Fix:** Check the service repo's Dockerfile — it should `go install
github.com/bufbuild/buf/cmd/buf@v1.55.0` and friends. Architecture rule 9
forbids `@latest`.

---

## gRPC dial fails — `rest-api` can't reach `indexer-service`

**Symptom:** `rest-api` logs `rpc error: code = Unavailable desc =
connection refused` against `indexer-service:9090`.

**Cause:** Container DNS resolution issue, or the indexer hasn't finished
its DB migrations yet on first boot.

**Fix:**

```bash
# Confirm the service is actually listening.
docker exec oracle-indexer-service \
    /usr/local/bin/indexer-service --help >/dev/null 2>&1 && echo "binary ok"

# Confirm rest-api can resolve the service name.
docker exec oracle-rest-api nslookup indexer-service || true

# Restart rest-api after indexer's startup completes.
docker compose -f docker/docker-compose.yml restart rest-api
```

If the indexer is healthy but rest-api still can't reach it, the
`GRPC_CLIENT_INDEXER_SERVICE_ADDR` env var probably has a stale `localhost`
default — confirm `.env` overrides it to `indexer-service:9090`.

---

## Postgres backup script can't find the container

**Symptom:** `backup.sh` logs `Error response from daemon: No such
container: evm-oracle-demo-postgres-1`.

**Cause:** Docker compose container naming changed (compose v2 default vs
v1 default), or the compose project name was overridden.

**Fix:** Set the explicit container name in `docker-compose.yml`
(`container_name: oracle-postgres`) and reference that name in
`backup.sh`. The repo already does this — if you forked and removed the
explicit names, restore them.

---

## Submodule update pulls broken code

**Symptom:** After `make submodules-update`, one of the services fails to
build because its tracked branch has unmerged work.

**Cause:** `make submodules-update` runs `git submodule update --remote`,
which moves to the tip of each submodule's tracked branch. If a branch is
mid-development, you get unfinished code.

**Fix:** Don't track branches you don't trust. Pin to specific SHAs:

```bash
cd repos/evm-oracle-demo-<svc>
git checkout <known-good-sha>
cd ../..
git add repos/evm-oracle-demo-<svc>
git commit -m "chore(submodules): pin <svc> to <short-sha>"
```

Or set `branch = main` for each submodule in `.gitmodules` so `--remote`
tracks main only:

```ini
[submodule "repos/evm-oracle-demo-<svc>"]
    path = repos/evm-oracle-demo-<svc>
    url = git@github.com:asolovov/evm-oracle-demo-<svc>.git
    branch = main
```
