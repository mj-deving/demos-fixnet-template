# Local Host Bootstrap

Use this path when you want to run a single DEMOS fixnet node on a local Linux machine without the full VPS automation wrapper.

## Clone upstream

```bash
git clone https://github.com/kynesyslabs/node.git
cd node
git checkout stabilisation
./scripts/install-deps.sh
```

## Configure identity

Either:

- restore an existing mnemonic into a private file such as `~/.secrets/demos-mnemonic`, or
- run a first boot once to generate `.demos_identity`, then move it to a private path outside git

## Write config

Create `.env`:

```env
PROD=true
EXPOSED_URL=http://<public-ip-or-dns>:53550
```

Create `demos_peerlist.json`:

```json
{
  "<anchor-pubkey>": "http://<anchor-host>:<anchor-port>"
}
```

## Start in fixnet mode

On the `stabilisation` branch, the TUI-disable form is:

```bash
./run -c false -u http://<public-ip-or-dns>:53550 -t -i ~/.secrets/demos-mnemonic
```

If you first booted locally before switching to fixnet mode:

```bash
rm -rf postgres_5332
```

## Verify

```bash
curl http://127.0.0.1:53550/info
curl http://<public-ip-or-dns>:53550/info
```
