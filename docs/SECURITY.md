# Security model

This is a **demo** oracle, not a production one. The README is loud about
that. This document spells out what the demo deliberately *doesn't* do and
what production would require.

## Threat model the demo addresses

| Attack                                              | Mitigation                                                                                                                |
|-----------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| Spoofed price update                                | M-of-N ECDSA signatures verified on-chain by `ReporterSet`; `PriceLib` enforces digest over `(reqId, assetId, price, ts)`.|
| Replay of a previous fulfillment                    | Monotonic `roundId` enforced on `PriceAggregator`; each `reqId` may only be fulfilled once.                               |
| Reorg-deep event reaches the oracle                 | `indexer-service` confirmation gate — `StreamEvents` only emits with `confirmations >= 5 && !orphaned`.                   |
| Web spam against the public REST surface            | Redis sliding-window rate limit on `rest-api` (60 req/min/IP default).                                                    |
| TLS downgrade / MITM                                | Caddy enforces HTTPS-only via HSTS (added in default Caddyfile); ACME-issued cert via HTTP-01.                            |
| SSH brute force                                     | `bootstrap-vps.sh` disables password + root login; fail2ban active on sshd.                                               |
| Bad config crashing into prod                       | Every service validates its config (rule 6 — `viper.SetDefault` + `Validate` fail-fast) and surfaces the error via crash-loop.|

## Demo-vs-production callouts

### Reporter private keys live on disk

`/etc/lighthouse/secrets/reporter{1,2,3}.key` — mode 0400, owned by `deploy`
user, mounted read-only into the `oracle-service` container. Per spec §3.2
this is a deliberate simplification.

| Property            | Demo (this repo)                                  | Production                                                |
|---------------------|---------------------------------------------------|-----------------------------------------------------------|
| Storage             | Plain hex private key in a file                   | HSM (Ledger / YubiHSM) or KMS (AWS KMS / GCP KMS) signer  |
| Signing surface     | Whole key material in process memory              | Signer-only surface; key never leaves HSM                 |
| Rotation            | `scripts/rotate-reporters.sh` (manual)            | Documented HSM rotation procedure; key versioning         |
| Distribution        | All three keys on the same VPS                    | One key per independent operator on independent infra     |
| Quorum              | 2-of-3 ECDSA                                      | Same (the contract layer doesn't change)                  |

If the VPS is compromised, the attacker can sign anything the contract
considers valid until the addresses are removed from `ReporterSet`. The
on-chain `Ownable2Step` admin path is the kill switch.

### Freshness is permissive

Off-chain prices flow to the dashboard with `age_sec` populated, but the
oracle never rejects a stale source. A `freshnessPolicy=strict` config flag
exists on `price-service`'s aggregator — flip it to reject sources past
`stale_after_crypto` / `stale_after_rwa` thresholds.

### One VPS, no HA

If the box goes down, the demo goes down. Production would run multiple
oracle nodes across regions with leader election and a chain-side timeout
that allows any reporter to submit if the previous round is past the
heartbeat window.

### Self-audit only

Slither + Hardhat property-based tests via `fast-check`. No external audit.
The threat model + access-control matrix live in
`repos/evm-oracle-demo-contracts/audit/`.

### Single-operator reporter set

All three reporter EOAs share the same VPS. Production-grade would
distribute them across mutually-untrusting operators so a single
infrastructure compromise can't reach 2-of-3.

## What this repo gets right

- **Least-privilege Postgres roles** — `price_user`, `oracle_user`,
  `indexer_user` each own only their own database, no shared schema, no
  `postgres` privilege on app DBs.
- **No outbound from indexer** — the indexer is a single chain-observer and
  has no gRPC client (rule 5 deviation called out in spec). Compromise of
  the indexer cannot reach other services as an actor.
- **Distroless runtime images** — every Go service runs as nonroot on
  `gcr.io/distroless/static-debian12:nonroot`; no shell, no package
  manager, no root.
- **TLS by default** — Caddy auto-renews Let's Encrypt certs; no plaintext
  HTTP listener except the well-known ACME challenge.
- **Read-only secret mount** — `oracle-service` mounts
  `/etc/lighthouse/secrets/` read-only; the container has no write surface
  on the host secrets directory.
- **SHA-pinned actions** — every CI workflow pins third-party GitHub
  Actions to commit SHA, not `@v4`. Matches Gateway's org policy.
- **fail2ban + ufw + no-password SSH** — VPS baseline hardening.

## Secrets lifecycle

```
laptop                               VPS
------                               ---
rotate-reporters.sh                  /etc/lighthouse/secrets/reporter*.key (0400)
   |                                       ^
   v                                       |
secrets/reporter*.key  --- scp --->  mounted read-only into oracle-service
                                           |
                                           v
                                     ephemeral process memory
                                     (signs; never persists)
```

Reporter rotation procedure:

1. `scripts/rotate-reporters.sh` generates fresh keys; outputs addresses.
2. Operator calls `ReporterSet.addReporter` for each new address.
3. Operator confirms 2-of-3 still works with old + new reporters in the
   set (no on-chain change yet).
4. Operator calls `ReporterSet.removeReporter` for each old address.
5. Operator deletes the old key files on the VPS.
6. `deploy.sh --restart` so oracle-service reloads with the new keys
   only.

## What would a real audit ask for?

- Independent code review by an audit firm (e.g. Trail of Bits, OpenZeppelin).
- Hardware-backed signers across mutually-untrusting operators.
- Insurance / bug bounty.
- Documented incident response runbook + on-call rotation.
- Cardinality limits on `requestPrice` to prevent griefing (current demo
  doesn't enforce a per-block rate limit on requests).
- Formal verification of `PriceLib.verifySignatures` and `fulfillPrice`
  state transitions.

None of those are appropriate for a portfolio demo, but they're the
checklist a reviewer evaluating this for production use should walk down.
