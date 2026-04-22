#!/usr/bin/env bash
set -euo pipefail

URL=""
SSH_TARGET=""
SSH_IDENTITY_FILE=""
MONITORING_PROFILE="basic"
WAIT_SECONDS=90
INTERVAL=5

usage() {
	cat <<'EOF'
Post-bootstrap verifier for a DEMOS fixnet host.

Run from your admin machine after bootstrap.

Required:
  --url http://<public-ip-or-dns>:53550/info

Optional:
  --ssh-target root@<host>
  --ssh-identity-file ~/.ssh/<admin-key>
  --monitoring-profile basic|full
  --wait-seconds 90
  --interval 5
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--url)
		URL="${2:-}"
		shift 2
		;;
	--ssh-target)
		SSH_TARGET="${2:-}"
		shift 2
		;;
	--ssh-identity-file)
		SSH_IDENTITY_FILE="${2:-}"
		shift 2
		;;
	--monitoring-profile)
		MONITORING_PROFILE="${2:-}"
		shift 2
		;;
	--wait-seconds)
		WAIT_SECONDS="${2:-}"
		shift 2
		;;
	--interval)
		INTERVAL="${2:-}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unknown argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

if [[ -z "${URL}" ]]; then
	echo "--url is required" >&2
	exit 1
fi

if [[ "${MONITORING_PROFILE}" != "basic" && "${MONITORING_PROFILE}" != "full" ]]; then
	echo "--monitoring-profile must be basic or full" >&2
	exit 1
fi

ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_IDENTITY_FILE}" ]]; then
	ssh_cmd+=(-i "${SSH_IDENTITY_FILE}")
fi

ssh_run() {
	"${ssh_cmd[@]}" "${SSH_TARGET}" "$@"
}

deadline=$((SECONDS + WAIT_SECONDS))
external_ok=0

while (( SECONDS < deadline )); do
	if response="$(curl -fsS --max-time 10 "${URL}" 2>/dev/null)"; then
		external_ok=1
		break
	fi
	sleep "${INTERVAL}"
done

if [[ "${external_ok}" -ne 1 ]]; then
	echo "External verification failed: ${URL} did not become reachable within ${WAIT_SECONDS}s" >&2
	exit 1
fi

echo "PASS external /info is reachable"

if [[ -z "${SSH_TARGET}" ]]; then
	exit 0
fi

if [[ "$(ssh_run 'systemctl is-active demos-node.service || true')" != "active" ]]; then
	echo "Service verification failed: demos-node.service is not active" >&2
	exit 1
fi
echo "PASS demos-node.service is active"

if ! ssh_run 'curl -fsS --max-time 10 http://127.0.0.1:9090/metrics >/dev/null'; then
	echo "Metrics verification failed: node metrics endpoint is not reachable" >&2
	exit 1
fi
echo "PASS node metrics endpoint is reachable"

if ! ssh_run 'curl -fsS --max-time 10 http://127.0.0.1:3000/api/health >/dev/null'; then
	echo "Grafana verification failed: localhost health endpoint is not reachable" >&2
	exit 1
fi
echo "PASS Grafana health endpoint is reachable"

targets_json="$(ssh_run 'curl -fsS --max-time 10 http://127.0.0.1:9091/api/v1/targets')"
python3 - "${MONITORING_PROFILE}" "${targets_json}" <<'PY'
import json
import sys

profile = sys.argv[1]
payload = json.loads(sys.argv[2])
active = payload.get("data", {}).get("activeTargets", [])
jobs = {t.get("labels", {}).get("job"): t.get("health") for t in active}

if jobs.get("demos-node") != "up":
    raise SystemExit("Prometheus target check failed: demos-node is not up")

if profile == "full" and jobs.get("node-exporter") != "up":
    raise SystemExit("Prometheus target check failed: node-exporter is not up in full profile")

print("PASS Prometheus targets are healthy")
PY
