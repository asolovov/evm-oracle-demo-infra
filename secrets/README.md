# `secrets/` — local-dev reporter keys

Three private ECDSA keys mounted read-only into `oracle-service`. In
production the same files live at `/etc/lighthouse/secrets/` on the VPS,
owned by the deploy user, mode `0400`.

## What goes here

| File            | Format                                                | Mode  |
|-----------------|-------------------------------------------------------|-------|
| `reporter1.key` | one line: `0x<64 hex chars>` — secp256k1 private key  | 0400  |
| `reporter2.key` | same                                                  | 0400  |
| `reporter3.key` | same                                                  | 0400  |

Each `*.key.example` here is the format. Drop your real keys in alongside
them (filename without `.example`) — the `*.key` files are gitignored.

## Generate fresh keys

```bash
scripts/rotate-reporters.sh --secrets-dir ./secrets --owner $(id -u):$(id -g)
```

The script writes the three files at mode `0400`, prints the matching
addresses, and reminds you to register them on `ReporterSet` on chain.

## Manual key drop

If you already have a key from somewhere else:

```bash
echo "0xyourkey..." > secrets/reporter1.key
chmod 0400 secrets/reporter1.key
```

## Threshold + ordering

`SIGNER_THRESHOLD` (default 2) of the keys must sign each fulfillment.
File order matters only as far as deterministic boot — oracle-service
loads them in the order given by `SIGNER_REPORTER_KEY_PATHS`. The
defaults in `docker/env.example` list `reporter1.key`, then `reporter2.key`,
then `reporter3.key`. Adjust the env if your filenames differ.

## Production vs dev

Dev: `./secrets/` here, group-readable by your uid because
`oracle-service` runs as distroless uid `65532` in the container. If
`oracle-service` complains about file mode at startup, the dev escape
hatch is `SIGNER_ALLOW_INSECURE_PERMS=true` in `.env`. **Never set that
in production.**

Production: `/etc/lighthouse/secrets/`, mode `0400`, owned by `deploy`.
The container mounts the directory read-only.

See `docs/SECURITY.md` for the rotation procedure.
