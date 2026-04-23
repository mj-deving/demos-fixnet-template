# Monitoring

The upstream DEMOS monitoring stack consists of:

- Prometheus
- Grafana
- optional `node-exporter` for the full profile
- optional recurring host-local sync health checks through a systemd timer

## Profiles

### Basic

Starts Prometheus and Grafana.

### Full

Starts Prometheus, Grafana, and `node-exporter` for host-level metrics.

In this template, full monitoring is enabled by:

```bash
--monitoring-profile full
```

The bootstrap script translates that into:

```bash
COMPOSE_PROFILES=full
```

so the upstream `docker compose` invocation in `./run` starts the optional `node-exporter` service too.

## Bootstrap options

```bash
--fresh-host | --reuse-host
--monitoring-profile basic|full
--metrics-port 9090
--prometheus-port 9091
--grafana-port 3000
--node-exporter-port 9100
--grafana-admin-user admin
--grafana-admin-password <password>
--grafana-root-url http://localhost:3000
```

The script writes:

- node `.env` with `METRICS_ENABLED=true`
- `monitoring/.env` with Grafana and Prometheus settings

The recommended wrapper is:

```bash
./scripts/setup_fixnet_vps.sh
```

It can also load a shell-style config file:

```bash
./scripts/setup_fixnet_vps.sh --config my-host.env
```

## Safe access

Default recommendation:

- keep Grafana and Prometheus private
- access them through SSH tunnels

Example:

```bash
ssh -L 3000:127.0.0.1:3000 -L 9091:127.0.0.1:9091 root@<host>
```

Then open:

- `http://127.0.0.1:3000`
- `http://127.0.0.1:9091`

## Public exposure

Only expose Grafana publicly if you first:

1. change the default password
2. restrict firewall access to trusted admin IPs
3. preferably put TLS or a reverse proxy in front of it

You do not need to expose `node-exporter` publicly. Prometheus scrapes it internally.

## Continuous health automation

For ongoing fixnet burn-in, use the recurring host-local health check.

It evaluates:

- `demos-node.service` active state
- local `/info` reachability
- local self-peer detection using the node's own identity
- anchor reachability and expected identity
- sync lag against the anchor
- block progression compared to the previous check

Statuses:

- `healthy`: service is up and lag is inside threshold
- `syncing`: service is up and block height is still advancing toward the anchor
- `unhealthy` or `stalled`: service down, endpoint down, anchor mismatch, or no progress

Install it directly on a host:

```bash
sudo ./scripts/install_fixnet_health_monitor.sh \
  --anchor-url http://node3.demos.sh:60001/info \
  --expected-anchor-identity 0x412bee5548b43bc0a23429c06946c1eb990d900f6c0ed5c3ad001481e7f7a8ef \
  --interval-minutes 5 \
  --max-lag 100 \
  --run-now
```

The timer writes the latest status JSON to:

```bash
/var/lib/demos-fixnet-health/latest.json
```

If you use the wrapper from your admin machine, install it during setup with:

```bash
./scripts/setup_fixnet_vps.sh \
  --ssh-target root@<host> \
  --ssh-identity-file ~/.ssh/<admin-key> \
  --public-url http://<public-ip-or-dns>:53550 \
  --fresh-host \
  --install-health-monitor
```
