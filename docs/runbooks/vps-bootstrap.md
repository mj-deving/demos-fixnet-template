# VPS Bootstrap

Use this path for a fresh public VPS where you want exactly one DEMOS node on the host.

## Network Requirements

Allow inbound:

- `22/tcp`
- `53550/tcp`
- `53551/tcp`
- `53551/udp`

## Bootstrap

Run as `root` on the target host:

```bash
ssh root@<host> 'bash -s -- --public-url http://<public-ip-or-dns>:53550' < scripts/bootstrap_fixnet_host.sh
```

If you want to reuse an existing mnemonic that already lives on the host:

```bash
ssh root@<host> 'bash -s -- \
  --public-url http://<public-ip-or-dns>:53550 \
  --identity-file /home/demos/.secrets/demos-mnemonic' < scripts/bootstrap_fixnet_host.sh
```

## Verification

```bash
curl http://<public-ip-or-dns>:53550/info
ssh root@<host> 'systemctl status demos-node.service --no-pager'
```

## Burn-in

```bash
./scripts/monitor_fixnet_burnin.sh \
  --url http://<public-ip-or-dns>:53550/info \
  --ssh-target root@<public-ip-or-dns> \
  --ssh-identity-file ~/.ssh/<admin-key> \
  --samples 12 \
  --interval 30
```

After `systemctl restart demos-node.service`, give the node roughly `20-30` seconds before expecting `/info` to return.

## Full monitoring

If you want upstream full-profile monitoring with `node-exporter`:

```bash
ssh root@<host> 'bash -s -- \
  --public-url http://<public-ip-or-dns>:53550 \
  --monitoring-profile full \
  --grafana-admin-password <strong-password>' < scripts/bootstrap_fixnet_host.sh
```

For safe access defaults, see [monitoring.md](monitoring.md).
