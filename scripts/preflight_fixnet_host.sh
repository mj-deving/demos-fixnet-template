#!/usr/bin/env bash
set -euo pipefail

PUBLIC_URL=""
HOST_MODE=""
USER_NAME="demos"
REPO_DIR=""
IDENTITY_FILE=""
MONITORING_PROFILE="basic"
METRICS_PORT="9090"
PROMETHEUS_PORT="9091"
GRAFANA_PORT="3000"
NODE_EXPORTER_PORT="9100"

usage() {
	cat <<'EOF'
Preflight checks for a DEMOS fixnet host.

Run on the target host as root before bootstrap.

Required:
  --public-url http://<public-ip-or-dns>:53550
  --fresh-host | --reuse-host

Optional:
  --user demos
  --repo-dir /home/demos/node
  --identity-file /home/demos/.secrets/demos-mnemonic
  --monitoring-profile basic|full
  --metrics-port 9090
  --prometheus-port 9091
  --grafana-port 3000
  --node-exporter-port 9100
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--public-url)
		PUBLIC_URL="${2:-}"
		shift 2
		;;
	--fresh-host)
		HOST_MODE="fresh"
		shift
		;;
	--reuse-host)
		HOST_MODE="reuse"
		shift
		;;
	--user)
		USER_NAME="${2:-}"
		shift 2
		;;
	--repo-dir)
		REPO_DIR="${2:-}"
		shift 2
		;;
	--identity-file)
		IDENTITY_FILE="${2:-}"
		shift 2
		;;
	--monitoring-profile)
		MONITORING_PROFILE="${2:-}"
		shift 2
		;;
	--metrics-port)
		METRICS_PORT="${2:-}"
		shift 2
		;;
	--prometheus-port)
		PROMETHEUS_PORT="${2:-}"
		shift 2
		;;
	--grafana-port)
		GRAFANA_PORT="${2:-}"
		shift 2
		;;
	--node-exporter-port)
		NODE_EXPORTER_PORT="${2:-}"
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

REPO_DIR="${REPO_DIR:-/home/${USER_NAME}/node}"

failures=0
warnings=0

pass() {
	printf 'PASS %s\n' "$1"
}

warn() {
	printf 'WARN %s\n' "$1"
	warnings=$((warnings + 1))
}

fail() {
	printf 'FAIL %s\n' "$1" >&2
	failures=$((failures + 1))
}

check_port_free() {
	local port="$1"
	if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q LISTEN; then
		return 1
	fi
	if ss -lun "( sport = :${port} )" 2>/dev/null | grep -q UNCONN; then
		return 1
	fi
	return 0
}

check_https() {
	local url="$1"
	curl -fsSIL --max-time 10 "$url" >/dev/null 2>&1
}

if [[ "$(id -u)" -ne 0 ]]; then
	fail "must run as root"
fi

if [[ -z "${PUBLIC_URL}" ]]; then
	fail "--public-url is required"
fi

if [[ -z "${HOST_MODE}" ]]; then
	fail "choose exactly one of --fresh-host or --reuse-host"
fi

if [[ "${MONITORING_PROFILE}" != "basic" && "${MONITORING_PROFILE}" != "full" ]]; then
	fail "--monitoring-profile must be basic or full"
fi

if [[ "${PUBLIC_URL}" =~ ^https?://(127\.0\.0\.1|localhost|0\.0\.0\.0)(:|/|$) ]]; then
	fail "public URL cannot use localhost, 127.0.0.1, or 0.0.0.0"
else
	pass "public URL is not loopback"
fi

ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
if (( ram_gb < 4 )); then
	fail "RAM ${ram_gb}GB is below the 4GB minimum"
else
	pass "RAM ${ram_gb}GB"
fi

cpu_cores=$(nproc)
if (( cpu_cores < 4 )); then
	fail "CPU cores ${cpu_cores} is below the 4-core minimum"
else
	pass "CPU cores ${cpu_cores}"
fi

if check_https "https://github.com"; then
	pass "outbound HTTPS to github.com"
else
	fail "cannot reach https://github.com"
fi

if check_https "https://bun.sh"; then
	pass "outbound HTTPS to bun.sh"
else
	fail "cannot reach https://bun.sh"
fi

if check_https "https://download.docker.com"; then
	pass "outbound HTTPS to download.docker.com"
else
	fail "cannot reach https://download.docker.com"
fi

for port in 5332 53550 "${METRICS_PORT}" "${PROMETHEUS_PORT}" "${GRAFANA_PORT}"; do
	if [[ "${HOST_MODE}" == "fresh" ]]; then
		if check_port_free "${port}"; then
			pass "port ${port} is free"
		else
			fail "port ${port} is already in use on a fresh-host path"
		fi
	else
		if check_port_free "${port}"; then
			pass "port ${port} is free"
		else
			warn "port ${port} is already in use and will rely on reuse-host replacement semantics"
		fi
	fi
done

if [[ "${MONITORING_PROFILE}" == "full" ]]; then
	if [[ "${HOST_MODE}" == "fresh" ]]; then
		if check_port_free "${NODE_EXPORTER_PORT}"; then
			pass "node-exporter port ${NODE_EXPORTER_PORT} is free"
		else
			fail "node-exporter port ${NODE_EXPORTER_PORT} is already in use on a fresh-host path"
		fi
	fi
fi

if [[ -n "${IDENTITY_FILE}" ]]; then
	if [[ -f "${IDENTITY_FILE}" ]]; then
		pass "identity file exists at ${IDENTITY_FILE}"
	else
		fail "identity file not found at ${IDENTITY_FILE}"
	fi
fi

if [[ "${HOST_MODE}" == "fresh" ]]; then
	if systemctl list-unit-files demos-node.service --no-legend 2>/dev/null | grep -q '^demos-node\.service'; then
		fail "demos-node.service already exists on fresh-host path"
	else
		pass "no existing demos-node.service"
	fi

	if [[ -e "${REPO_DIR}" ]]; then
		fail "repo path already exists at ${REPO_DIR} on fresh-host path"
	else
		pass "repo path is absent"
	fi

	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(postgres_5332|tlsn-notary-7047|demos-prometheus|demos-grafana|demos-node-exporter)$'; then
		fail "DEMOS-related containers already exist on fresh-host path"
	else
		pass "no DEMOS-related containers found"
	fi
else
	if systemctl list-unit-files demos-node.service --no-legend 2>/dev/null | grep -q '^demos-node\.service'; then
		warn "existing demos-node.service detected and will be replaced"
	else
		pass "no existing demos-node.service"
	fi
fi

printf '\nSummary: failures=%s warnings=%s\n' "${failures}" "${warnings}"

if (( failures > 0 )); then
	exit 1
fi
