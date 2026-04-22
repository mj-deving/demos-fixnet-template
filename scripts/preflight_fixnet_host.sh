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
OUTPUT_JSON=false
EVENTS_FILE=""
MIN_DOCKER_VERSION="24.0.0"
MIN_BUN_VERSION="1.0.0"
MIN_RUST_VERSION="1.75.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
  --json
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
	--json)
		OUTPUT_JSON=true
		shift
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
EVENTS_FILE="$(mktemp)"
trap 'rm -f "${EVENTS_FILE}"' EXIT

service_exists=false
repo_exists=false
containers_exist=false
docker_installed=false
bun_installed=false
rust_installed=false
apt_healthy=false
reboot_required=false
identity_present=false
docker_version_value=""
bun_version_value=""
rust_version_value=""
docker_version_ok=false
bun_version_ok=false
rust_version_ok=false
docker_compose_ok=false
existing_branch=""
existing_service_active=false
classification="unknown"
recommended_strategy="unknown"
host_summary=""

record_event() {
	printf '%s\t%s\n' "$1" "$2" >>"${EVENTS_FILE}"
}

pass() {
	record_event "PASS" "$1"
	if [[ "${OUTPUT_JSON}" != "true" ]]; then
		printf 'PASS %s\n' "$1"
	fi
}

warn() {
	record_event "WARN" "$1"
	if [[ "${OUTPUT_JSON}" != "true" ]]; then
		printf 'WARN %s\n' "$1"
	fi
	warnings=$((warnings + 1))
}

fail() {
	record_event "FAIL" "$1"
	if [[ "${OUTPUT_JSON}" != "true" ]]; then
		printf 'FAIL %s\n' "$1" >&2
	fi
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

version_ge() {
	local current="$1"
	local minimum="$2"
	[[ -n "${current}" && "$(printf '%s\n%s\n' "${minimum}" "${current}" | sort -V | head -n1)" == "${minimum}" ]]
}

detect_bun_version() {
	if command -v bun >/dev/null 2>&1; then
		bun --version 2>/dev/null | head -n1
	elif [[ -x "/home/${USER_NAME}/.bun/bin/bun" ]]; then
		"/home/${USER_NAME}/.bun/bin/bun" --version 2>/dev/null | head -n1
	fi
}

detect_rust_version() {
	if command -v cargo >/dev/null 2>&1; then
		cargo --version 2>/dev/null | awk '{print $2}' | head -n1
	elif [[ -x "/home/${USER_NAME}/.cargo/bin/cargo" ]]; then
		"/home/${USER_NAME}/.cargo/bin/cargo" --version 2>/dev/null | awk '{print $2}' | head -n1
	fi
}

if dpkg --audit >/dev/null 2>&1 && apt-get -qq update >/dev/null 2>&1; then
	apt_healthy=true
	pass "package manager health is acceptable"
else
	fail "package manager is not healthy enough for autonomous install"
fi

if command -v docker >/dev/null 2>&1; then
	docker_installed=true
	docker_version_value="$(docker version --format '{{.Server.Version}}' 2>/dev/null | head -n1)"
	if version_ge "${docker_version_value}" "${MIN_DOCKER_VERSION}"; then
		docker_version_ok=true
	fi
	if docker compose version >/dev/null 2>&1; then
		docker_compose_ok=true
	fi
	pass "docker is installed"
else
	warn "docker is not installed"
fi

if command -v bun >/dev/null 2>&1 || [[ -x "/home/${USER_NAME}/.bun/bin/bun" ]]; then
	bun_installed=true
	bun_version_value="$(detect_bun_version)"
	if version_ge "${bun_version_value}" "${MIN_BUN_VERSION}"; then
		bun_version_ok=true
	fi
	pass "bun is installed or already present for the service user"
else
	warn "bun is not installed"
fi

if command -v cargo >/dev/null 2>&1 || [[ -x "/home/${USER_NAME}/.cargo/bin/cargo" ]]; then
	rust_installed=true
	rust_version_value="$(detect_rust_version)"
	if version_ge "${rust_version_value}" "${MIN_RUST_VERSION}"; then
		rust_version_ok=true
	fi
	pass "rust/cargo is installed or already present for the service user"
else
	warn "rust/cargo is not installed"
fi

if [[ -f /var/run/reboot-required ]]; then
	reboot_required=true
	warn "host reports reboot-required"
fi

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
		identity_present=true
		pass "identity file exists at ${IDENTITY_FILE}"
	else
		fail "identity file not found at ${IDENTITY_FILE}"
	fi
fi

if [[ "${HOST_MODE}" == "fresh" ]]; then
	if systemctl list-unit-files demos-node.service --no-legend 2>/dev/null | grep -q '^demos-node\.service'; then
		service_exists=true
		fail "demos-node.service already exists on fresh-host path"
	else
		pass "no existing demos-node.service"
	fi

	if [[ -e "${REPO_DIR}" ]]; then
		repo_exists=true
		fail "repo path already exists at ${REPO_DIR} on fresh-host path"
	else
		pass "repo path is absent"
	fi

	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(postgres_5332|tlsn-notary-7047|demos-prometheus|demos-grafana|demos-node-exporter)$'; then
		containers_exist=true
		fail "DEMOS-related containers already exist on fresh-host path"
	else
		pass "no DEMOS-related containers found"
	fi
else
	if systemctl list-unit-files demos-node.service --no-legend 2>/dev/null | grep -q '^demos-node\.service'; then
		service_exists=true
		if [[ "$(systemctl is-active demos-node.service 2>/dev/null || true)" == "active" ]]; then
			existing_service_active=true
		fi
		warn "existing demos-node.service detected and will be replaced"
	else
		pass "no existing demos-node.service"
	fi

	if [[ -e "${REPO_DIR}" ]]; then
		repo_exists=true
		if git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			existing_branch="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
		fi
		warn "repo path already exists and will be replaced"
	else
		pass "repo path is absent"
	fi

	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(postgres_5332|tlsn-notary-7047|demos-prometheus|demos-grafana|demos-node-exporter)$'; then
		containers_exist=true
		warn "DEMOS-related containers already exist and will be replaced"
	else
		pass "no DEMOS-related containers found"
	fi
fi

eval_payload="$(python3 - "${PUBLIC_URL}" "${HOST_MODE}" "${MONITORING_PROFILE}" "${REPO_DIR}" "${IDENTITY_FILE}" "${existing_branch}" \
	"${service_exists}" "${repo_exists}" "${containers_exist}" "${docker_installed}" "${docker_version_value}" "${docker_version_ok}" \
	"${docker_compose_ok}" "${bun_installed}" "${bun_version_value}" "${bun_version_ok}" "${rust_installed}" "${rust_version_value}" \
	"${rust_version_ok}" "${apt_healthy}" "${reboot_required}" "${identity_present}" "${existing_service_active}" <<'PY'
import json
import sys

payload = {
    "inputs": {
        "public_url": sys.argv[1],
        "host_mode": sys.argv[2],
        "monitoring_profile": sys.argv[3],
        "repo_dir": sys.argv[4],
        "identity_file": sys.argv[5],
        "desired_branch": "stabilisation",
    },
    "state": {
        "existing_branch": sys.argv[6],
        "service_exists": sys.argv[7] == "true",
        "repo_exists": sys.argv[8] == "true",
        "containers_exist": sys.argv[9] == "true",
        "docker_installed": sys.argv[10] == "true",
        "docker_version": sys.argv[11],
        "docker_version_ok": sys.argv[12] == "true",
        "docker_compose_ok": sys.argv[13] == "true",
        "bun_installed": sys.argv[14] == "true",
        "bun_version": sys.argv[15],
        "bun_version_ok": sys.argv[16] == "true",
        "rust_installed": sys.argv[17] == "true",
        "rust_version": sys.argv[18],
        "rust_version_ok": sys.argv[19] == "true",
        "apt_healthy": sys.argv[20] == "true",
        "reboot_required": sys.argv[21] == "true",
        "identity_present": sys.argv[22] == "true",
        "existing_service_active": sys.argv[23] == "true",
    },
}
print(json.dumps(payload))
PY
)"

eval_result="$(printf '%s' "${eval_payload}" | "${SCRIPT_DIR}/evaluate_host_state.py")"
classification="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["classification"])' <<<"${eval_result}")"
recommended_strategy="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["recommended_strategy"])' <<<"${eval_result}")"
host_summary="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["host_summary"])' <<<"${eval_result}")"

if [[ "${OUTPUT_JSON}" == "true" ]]; then
	python3 - "${EVENTS_FILE}" "${failures}" "${warnings}" "${PUBLIC_URL}" "${HOST_MODE}" "${MONITORING_PROFILE}" \
		"${classification}" "${recommended_strategy}" "${host_summary}" "${service_exists}" "${repo_exists}" \
		"${containers_exist}" "${docker_installed}" "${docker_version_value}" "${docker_version_ok}" "${docker_compose_ok}" \
		"${bun_installed}" "${bun_version_value}" "${bun_version_ok}" "${rust_installed}" "${rust_version_value}" \
		"${rust_version_ok}" "${apt_healthy}" "${reboot_required}" "${identity_present}" "${existing_branch}" \
		"${existing_service_active}" "${REPO_DIR}" "${IDENTITY_FILE}" <<'PY'
import json
import sys

events_file = sys.argv[1]
data = {
    "summary": {
        "failures": int(sys.argv[2]),
        "warnings": int(sys.argv[3]),
        "classification": sys.argv[7],
        "recommended_strategy": sys.argv[8],
        "host_summary": sys.argv[9],
    },
    "inputs": {
        "public_url": sys.argv[4],
        "host_mode": sys.argv[5],
        "monitoring_profile": sys.argv[6],
        "repo_dir": sys.argv[19],
        "identity_file": sys.argv[20],
    },
    "state": {
        "service_exists": sys.argv[10] == "true",
        "repo_exists": sys.argv[11] == "true",
        "containers_exist": sys.argv[12] == "true",
        "docker_installed": sys.argv[13] == "true",
        "docker_version": sys.argv[14],
        "docker_version_ok": sys.argv[15] == "true",
        "docker_compose_ok": sys.argv[16] == "true",
        "bun_installed": sys.argv[17] == "true",
        "bun_version": sys.argv[18],
        "bun_version_ok": sys.argv[19] == "true",
        "rust_installed": sys.argv[20] == "true",
        "rust_version": sys.argv[21],
        "rust_version_ok": sys.argv[22] == "true",
        "apt_healthy": sys.argv[23] == "true",
        "reboot_required": sys.argv[24] == "true",
        "identity_present": sys.argv[25] == "true",
        "existing_branch": sys.argv[26],
        "existing_service_active": sys.argv[27] == "true",
    },
    "events": [],
}
with open(events_file, "r", encoding="utf-8") as fh:
    for line in fh:
        level, message = line.rstrip("\n").split("\t", 1)
        data["events"].append({"level": level, "message": message})
print(json.dumps(data, indent=2))
PY
else
	printf '\nSummary: failures=%s warnings=%s classification=%s strategy=%s\n' \
		"${failures}" "${warnings}" "${classification}" "${recommended_strategy}"
fi

if (( failures > 0 )); then
	exit 1
fi
