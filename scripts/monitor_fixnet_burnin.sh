#!/usr/bin/env bash
set -euo pipefail

URL=""
SSH_TARGET=""
SSH_IDENTITY_FILE=""
SAMPLES=12
INTERVAL=30
TIMEOUT=10

usage() {
	cat <<'EOF'
Lightweight DEMOS fixnet burn-in monitor.

Usage:
  ./scripts/monitor_fixnet_burnin.sh --url http://<host>:53550/info [options]

Options:
  --url <url>          Required /info endpoint to poll
  --ssh-target <host>  Optional SSH target for systemd status checks
  --ssh-identity-file  Optional SSH identity file for the service check
  --samples <count>    Number of samples to collect (default: 12)
  --interval <secs>    Delay between samples (default: 30)
  --timeout <secs>     Curl timeout per sample (default: 10)

Exit codes:
  0  Burn-in window passed: endpoint reachable on all samples and block height advanced
  1  Burn-in window failed: endpoint unavailable, service unhealthy, or no block progress
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
	--samples)
		SAMPLES="${2:-}"
		shift 2
		;;
	--interval)
		INTERVAL="${2:-}"
		shift 2
		;;
	--timeout)
		TIMEOUT="${2:-}"
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

if ! [[ "${SAMPLES}" =~ ^[0-9]+$ ]] || ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]]; then
	echo "--samples, --interval, and --timeout must be integers" >&2
	exit 1
fi

if [[ "${SAMPLES}" -lt 2 ]]; then
	echo "--samples must be at least 2" >&2
	exit 1
fi

check_service() {
	local -a ssh_cmd
	if [[ -z "${SSH_TARGET}" ]]; then
		echo "n/a"
		return
	fi
	ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=5)
	if [[ -n "${SSH_IDENTITY_FILE}" ]]; then
		ssh_cmd+=(-i "${SSH_IDENTITY_FILE}")
	fi
	"${ssh_cmd[@]}" "${SSH_TARGET}" \
		'systemctl is-active demos-node.service 2>/dev/null || true' 2>/dev/null || echo "ssh-error"
}

extract_fields() {
	local payload="$1"
	python3 - "$payload" <<'PY'
import json
import sys

raw = sys.argv[1]
data = json.loads(raw)
identity = data.get("identity")
peerlist = data.get("peerlist") or []
self_peer = next((peer for peer in peerlist if peer.get("identity") == identity), {})
block = self_peer.get("sync", {}).get("block")
ready = self_peer.get("status", {}).get("ready")
print(identity or "")
print("" if block is None else block)
print("" if ready is None else str(ready).lower())
PY
}

last_block=""
first_block=""
successes=0
failures=0
service_failures=0

printf 'Monitoring %s for %s samples every %ss\n' "${URL}" "${SAMPLES}" "${INTERVAL}"
if [[ -n "${SSH_TARGET}" ]]; then
	printf 'Checking service on %s\n' "${SSH_TARGET}"
fi
echo

for sample in $(seq 1 "${SAMPLES}"); do
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	service_state="$(check_service)"

	if [[ "${service_state}" != "n/a" && "${service_state}" != "active" ]]; then
		service_failures=$((service_failures + 1))
	fi

	response="$(curl -fsS --max-time "${TIMEOUT}" "${URL}" 2>/dev/null || true)"
	if [[ -z "${response}" ]]; then
		failures=$((failures + 1))
		printf '[%s] sample=%s service=%s endpoint=down\n' "${timestamp}" "${sample}" "${service_state}"
	else
		mapfile -t fields < <(extract_fields "${response}")
		identity="${fields[0]}"
		block="${fields[1]}"
		ready="${fields[2]}"
		successes=$((successes + 1))
		if [[ -z "${first_block}" ]]; then
			first_block="${block}"
		fi
		last_block="${block}"
		printf '[%s] sample=%s service=%s block=%s ready=%s identity=%s\n' \
			"${timestamp}" "${sample}" "${service_state}" "${block}" "${ready}" "${identity}"
	fi

	if [[ "${sample}" -lt "${SAMPLES}" ]]; then
		sleep "${INTERVAL}"
	fi
done

echo
printf 'Summary: successes=%s failures=%s service_failures=%s first_block=%s last_block=%s\n' \
	"${successes}" "${failures}" "${service_failures}" "${first_block:-n/a}" "${last_block:-n/a}"

if [[ "${successes}" -ne "${SAMPLES}" ]]; then
	echo "Burn-in check failed: endpoint was not reachable on every sample" >&2
	exit 1
fi

if [[ "${service_failures}" -ne 0 ]]; then
	echo "Burn-in check failed: demos-node.service was not active on every sample" >&2
	exit 1
fi

if [[ -z "${first_block}" || -z "${last_block}" ]]; then
	echo "Burn-in check failed: block height was not captured" >&2
	exit 1
fi

if (( last_block <= first_block )); then
	echo "Burn-in check failed: block height did not advance" >&2
	exit 1
fi

echo "Burn-in check passed"
