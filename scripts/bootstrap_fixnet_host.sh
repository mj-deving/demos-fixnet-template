#!/usr/bin/env bash
set -euo pipefail

USER_NAME="demos"
REPO_DIR="/home/${USER_NAME}/node"
BRANCH="stabilisation"
UPSTREAM_REPO="https://github.com/kynesyslabs/node.git"
PUBLIC_URL=""
IDENTITY_FILE=""
IDENTITY_MODE="auto"
DISABLE_MONITORING=false
HOST_MODE=""
MONITORING_PROFILE="basic"
METRICS_PORT="9090"
PROMETHEUS_PORT="9091"
GRAFANA_PORT="3000"
NODE_EXPORTER_PORT="9100"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD="demos"
GRAFANA_ROOT_URL="http://localhost:3000"
MIN_DOCKER_VERSION="24.0.0"
MIN_BUN_VERSION="1.0.0"
MIN_RUST_VERSION="1.75.0"
ARCHIVE_ROOT="/var/backups/demos-fixnet"
ANCHOR_PUBKEY="0x680464e81ff8a088611d91eb97c40326dc3d8981bd29cf2721b47daa60f56274"
ANCHOR_URL="http://node3.demos.sh:60001"

usage() {
	cat <<'EOF'
Bootstrap a fresh DEMOS fixnet host.

Run as root on the target host.

Required:
  --public-url http://<public-ip-or-dns>:53550
  --fresh-host | --reuse-host

Optional:
  --user demos
  --repo-dir /home/demos/node
  --branch stabilisation
  --upstream-repo https://github.com/kynesyslabs/node.git
  --identity-file /home/demos/.secrets/demos-mnemonic
  --identity-mode auto|existing|generate
  --monitoring-profile basic|full
  --metrics-port 9090
  --prometheus-port 9091
  --grafana-port 3000
  --node-exporter-port 9100
  --grafana-admin-user admin
  --grafana-admin-password demos
  --grafana-root-url http://localhost:3000
  --anchor-pubkey 0x...
  --anchor-url http://node3.demos.sh:60001
  --disable-monitoring

Notes:
  - This script assumes one DEMOS node per host.
  - You must choose either --fresh-host or --reuse-host.
  - It repairs or installs Docker, Bun, and Rust/Cargo if they are absent or below policy.
  - In reuse-host mode it archives replaceable state under /var/backups/demos-fixnet.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--public-url)
		PUBLIC_URL="${2:-}"
		shift 2
		;;
	--user)
		USER_NAME="${2:-}"
		REPO_DIR="/home/${USER_NAME}/node"
		shift 2
		;;
	--repo-dir)
		REPO_DIR="${2:-}"
		shift 2
		;;
	--branch)
		BRANCH="${2:-}"
		shift 2
		;;
	--upstream-repo)
		UPSTREAM_REPO="${2:-}"
		shift 2
		;;
	--identity-file)
		IDENTITY_FILE="${2:-}"
		shift 2
		;;
	--identity-mode)
		IDENTITY_MODE="${2:-}"
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
	--grafana-admin-user)
		GRAFANA_ADMIN_USER="${2:-}"
		shift 2
		;;
	--grafana-admin-password)
		GRAFANA_ADMIN_PASSWORD="${2:-}"
		shift 2
		;;
	--grafana-root-url)
		GRAFANA_ROOT_URL="${2:-}"
		shift 2
		;;
	--anchor-pubkey)
		ANCHOR_PUBKEY="${2:-}"
		shift 2
		;;
	--anchor-url)
		ANCHOR_URL="${2:-}"
		shift 2
		;;
	--disable-monitoring)
		DISABLE_MONITORING=true
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

if [[ -z "${PUBLIC_URL}" ]]; then
	echo "--public-url is required" >&2
	exit 1
fi

if [[ -z "${HOST_MODE}" ]]; then
	echo "Choose exactly one of --fresh-host or --reuse-host" >&2
	exit 1
fi

if [[ "${MONITORING_PROFILE}" != "basic" && "${MONITORING_PROFILE}" != "full" ]]; then
	echo "--monitoring-profile must be 'basic' or 'full'" >&2
	exit 1
fi

if [[ "${IDENTITY_MODE}" != "auto" && "${IDENTITY_MODE}" != "existing" && "${IDENTITY_MODE}" != "generate" ]]; then
	echo "--identity-mode must be 'auto', 'existing', or 'generate'" >&2
	exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run this script as root" >&2
	exit 1
fi

HOME_DIR="/home/${USER_NAME}"
SECRETS_DIR="${HOME_DIR}/.secrets"
FIRST_RUN_LOG="${HOME_DIR}/first-run.log"
FIRST_RUN_PID="${HOME_DIR}/first-run.pid"
ARCHIVE_DIR=""

user_shell() {
	sudo -u "${USER_NAME}" -H bash -lc "$*"
}

version_ge() {
	local current="$1"
	local minimum="$2"
	[[ "$(printf '%s\n%s\n' "${minimum}" "${current}" | sort -V | head -n1)" == "${minimum}" ]]
}

docker_version() {
	docker version --format '{{.Server.Version}}' 2>/dev/null | head -n1
}

user_bun_version() {
	user_shell 'if [[ -x "$HOME/.bun/bin/bun" ]]; then "$HOME/.bun/bin/bun" --version; elif command -v bun >/dev/null 2>&1; then bun --version; fi' 2>/dev/null | head -n1
}

user_rust_version() {
	user_shell 'if [[ -x "$HOME/.cargo/bin/cargo" ]]; then "$HOME/.cargo/bin/cargo" --version | awk "{print \$2}"; elif command -v cargo >/dev/null 2>&1; then cargo --version | awk "{print \$2}"; fi' 2>/dev/null | head -n1
}

repair_apt_state() {
	dpkg --configure -a >/dev/null 2>&1 || true
	apt-get -f install -y >/dev/null 2>&1 || true
}

service_exists() {
	systemctl list-unit-files demos-node.service --no-legend 2>/dev/null | grep -q '^demos-node\.service'
}

assert_fresh_host() {
	local residue=0

	if service_exists; then
		echo "Fresh-host check failed: demos-node.service already exists" >&2
		residue=1
	fi

	if [[ -e "${REPO_DIR}" ]]; then
		echo "Fresh-host check failed: repo path already exists at ${REPO_DIR}" >&2
		residue=1
	fi

	if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Eq '^(postgres_5332|tlsn-notary-7047|demos-prometheus|demos-grafana|demos-node-exporter)$'; then
		echo "Fresh-host check failed: DEMOS-related Docker containers already exist" >&2
		residue=1
	fi

	if [[ "${residue}" -ne 0 ]]; then
		echo "Use --reuse-host if you intend to replace an existing install." >&2
		exit 1
	fi
}

cleanup_existing_install() {
	archive_existing_install
	if service_exists; then
		systemctl stop demos-node.service >/dev/null 2>&1 || true
		systemctl disable demos-node.service >/dev/null 2>&1 || true
	fi

	rm -f /etc/systemd/system/demos-node.service
	systemctl daemon-reload >/dev/null 2>&1 || true
	cleanup_runtime_artifacts
	rm -rf "${REPO_DIR}"
}

archive_existing_install() {
	local ts
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	ARCHIVE_DIR="${ARCHIVE_ROOT}/${ts}"

	install -d -m 700 "${ARCHIVE_DIR}"

	if service_exists; then
		cp /etc/systemd/system/demos-node.service "${ARCHIVE_DIR}/demos-node.service.bak" 2>/dev/null || true
		systemctl cat demos-node.service >"${ARCHIVE_DIR}/demos-node.service.cat" 2>/dev/null || true
		systemctl status demos-node.service --no-pager >"${ARCHIVE_DIR}/demos-node.service.status.txt" 2>/dev/null || true
	fi

	if [[ -d "${REPO_DIR}" ]]; then
		tar -C "${REPO_DIR}" -cf "${ARCHIVE_DIR}/repo-config.tar" \
			.env monitoring/.env demos_peerlist.json fnode.sh .demos_identity 2>/dev/null || true
		git -C "${REPO_DIR}" status --short >"${ARCHIVE_DIR}/repo-status.txt" 2>/dev/null || true
		git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD >"${ARCHIVE_DIR}/repo-branch.txt" 2>/dev/null || true
	fi

	find "${HOME_DIR}/.secrets" -maxdepth 1 -type f -printf '%f\n' >"${ARCHIVE_DIR}/secrets-file-list.txt" 2>/dev/null || true
	docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' >"${ARCHIVE_DIR}/docker-ps.txt" 2>/dev/null || true
	docker volume ls >"${ARCHIVE_DIR}/docker-volumes.txt" 2>/dev/null || true
	cat >"${ARCHIVE_DIR}/manifest.json" <<EOF
{
  "timestamp": "${ts}",
  "repo_dir": "${REPO_DIR}",
  "home_dir": "${HOME_DIR}",
  "service_name": "demos-node.service",
  "archive_root": "${ARCHIVE_ROOT}",
  "branch": "$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)",
  "service_file_present": $([[ -f /etc/systemd/system/demos-node.service ]] && echo true || echo false),
  "repo_config_tar_present": $([[ -f "${ARCHIVE_DIR}/repo-config.tar" ]] && echo true || echo false),
  "repo_status_file_present": $([[ -f "${ARCHIVE_DIR}/repo-status.txt" ]] && echo true || echo false)
}
EOF
}

ensure_base_packages() {
	repair_apt_state
	local waited=0
	while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
		fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
		fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
		if (( waited == 0 )); then
			echo "Waiting for apt/dpkg locks to clear..."
		fi
		sleep 5
		waited=$((waited + 5))
		if (( waited > 600 )); then
			echo "Timed out waiting for apt/dpkg locks" >&2
			exit 1
		fi
	done
	apt-get update
	apt-get install -y curl git wget build-essential ca-certificates gnupg lsb-release netcat-openbsd unzip
}

ensure_docker() {
	local current=""
	local compose_ok=false

	if command -v docker >/dev/null 2>&1; then
		current="$(docker_version)"
		if docker compose version >/dev/null 2>&1; then
			compose_ok=true
		fi
	fi

	if [[ -n "${current}" ]] && version_ge "${current}" "${MIN_DOCKER_VERSION}" && [[ "${compose_ok}" == "true" ]]; then
		systemctl enable --now docker
		return
	fi

	apt-get remove -y docker docker-engine docker.io containerd runc || true
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	chmod a+r /etc/apt/keyrings/docker.gpg
	echo \
		"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
		>/etc/apt/sources.list.d/docker.list
	apt-get update
	apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
	systemctl enable --now docker
}

ensure_user() {
	id -u "${USER_NAME}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${USER_NAME}"
	usermod -aG docker,sudo "${USER_NAME}"
	install -d -m 700 -o "${USER_NAME}" -g "${USER_NAME}" "${SECRETS_DIR}"
}

ensure_bun() {
	local current=""
	current="$(user_bun_version)"
	if [[ -n "${current}" ]] && version_ge "${current}" "${MIN_BUN_VERSION}"; then
		return
	fi
	user_shell 'curl -fsSL https://bun.sh/install | bash'
}

ensure_rust() {
	local current=""
	current="$(user_rust_version)"
	if [[ -n "${current}" ]] && version_ge "${current}" "${MIN_RUST_VERSION}"; then
		return
	fi
	user_shell 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
}

ensure_repo() {
	install -d -m 755 -o "${USER_NAME}" -g "${USER_NAME}" "$(dirname "${REPO_DIR}")"
	user_shell "git clone ${UPSTREAM_REPO} ${REPO_DIR}"
	user_shell "cd ${REPO_DIR} && git checkout ${BRANCH}"
}

install_deps() {
	user_shell "export PATH=\"\$HOME/.bun/bin:\$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\" && cd ${REPO_DIR} && ./scripts/install-deps.sh"
}

cleanup_runtime_artifacts() {
	pkill -KILL -f "${REPO_DIR}/scripts/run" || true
	pkill -KILL -f "src/index.ts --no-tui" || true
	docker rm -f postgres_5332 neo4j-cgc tlsn-notary-7047 demos-prometheus demos-grafana demos-node-exporter >/dev/null 2>&1 || true
	rm -rf "${REPO_DIR}/postgres_5332" "${REPO_DIR}/logs" >/dev/null 2>&1 || true
}

generate_identity_if_needed() {
	if [[ "${IDENTITY_MODE}" == "existing" ]]; then
		if [[ -z "${IDENTITY_FILE}" || ! -f "${IDENTITY_FILE}" ]]; then
			echo "identity-mode existing requires a valid --identity-file" >&2
			exit 1
		fi
		return
	fi

	if [[ "${IDENTITY_MODE}" == "auto" && -n "${IDENTITY_FILE}" && -f "${IDENTITY_FILE}" ]]; then
		return
	fi

	if [[ "${IDENTITY_MODE}" == "generate" && -n "${IDENTITY_FILE}" && -f "${IDENTITY_FILE}" ]]; then
		echo "identity-mode generate refuses to overwrite an existing identity file at ${IDENTITY_FILE}" >&2
		exit 1
	fi

	user_shell "export PATH=\"\$HOME/.bun/bin:\$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\" && cd ${REPO_DIR} && rm -f ${FIRST_RUN_LOG} ${FIRST_RUN_PID} && nohup ./run -t >${FIRST_RUN_LOG} 2>&1 & echo \$! >${FIRST_RUN_PID}"

	for _ in $(seq 1 60); do
		if user_shell "test -f ${REPO_DIR}/.demos_identity" >/dev/null 2>&1; then
			break
		fi
		sleep 5
	done

	if ! user_shell "test -f ${REPO_DIR}/.demos_identity" >/dev/null 2>&1; then
		echo "Timed out waiting for first-run identity generation" >&2
		exit 1
	fi

	if [[ -z "${IDENTITY_FILE}" ]]; then
		IDENTITY_FILE="${SECRETS_DIR}/$(hostname)-mnemonic"
	fi
	user_shell "install -m 600 ${REPO_DIR}/.demos_identity ${IDENTITY_FILE}"

	if user_shell "test -f ${FIRST_RUN_PID}" >/dev/null 2>&1; then
		local pid
		pid=$(user_shell "cat ${FIRST_RUN_PID}")
		kill -INT "${pid}" || true
		sleep 5
	fi
	cleanup_runtime_artifacts
}

write_fixnet_config() {
	local run_flags
	run_flags="-c false -n true -u ${PUBLIC_URL} -t"
	if [[ -n "${IDENTITY_FILE}" ]]; then
		run_flags="${run_flags} -i ${IDENTITY_FILE}"
	fi
	if [[ "${DISABLE_MONITORING}" == true ]]; then
		run_flags="${run_flags} -m"
	fi

	cat > "${REPO_DIR}/.env" <<ENV
PROD=true
EXPOSED_URL=${PUBLIC_URL}
METRICS_ENABLED=true
METRICS_PORT=${METRICS_PORT}
ENV

	cat > "${REPO_DIR}/monitoring/.env" <<ENV
PROMETHEUS_PORT=${PROMETHEUS_PORT}
PROMETHEUS_RETENTION=15d
GRAFANA_PORT=${GRAFANA_PORT}
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
GRAFANA_ROOT_URL=${GRAFANA_ROOT_URL}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT}
ENV

	cat > "${REPO_DIR}/demos_peerlist.json" <<JSON
{
  \"${ANCHOR_PUBKEY}\": \"${ANCHOR_URL}\"
}
JSON

	rm -rf "${REPO_DIR}/postgres_5332"

	cat > "${REPO_DIR}/fnode.sh" <<SH
#!/usr/bin/env bash
export PATH=\"${HOME_DIR}/.bun/bin:${HOME_DIR}/.cargo/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\"
if [[ \"${MONITORING_PROFILE}\" == \"full\" ]]; then
export COMPOSE_PROFILES=full
fi
cd ${REPO_DIR}
exec ./run ${run_flags}
SH
	chown "${USER_NAME}:${USER_NAME}" "${REPO_DIR}/.env" "${REPO_DIR}/monitoring/.env" "${REPO_DIR}/demos_peerlist.json" "${REPO_DIR}/fnode.sh"
	chmod +x "${REPO_DIR}/fnode.sh"
}

install_service() {
	cat > /etc/systemd/system/demos-node.service <<EOF
[Unit]
Description=DEMOS node
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
WorkingDirectory=${REPO_DIR}
Environment=HOME=${HOME_DIR}
Environment=PATH=${HOME_DIR}/.bun/bin:${HOME_DIR}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -lc ./fnode.sh
ExecStop=/bin/kill -INT \$MAINPID
Restart=on-failure
RestartSec=10
TimeoutStopSec=120
KillMode=control-group
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable --now demos-node.service
}

if [[ "${HOST_MODE}" == "fresh" ]]; then
	assert_fresh_host
else
	cleanup_existing_install
fi

ensure_base_packages
ensure_docker
ensure_user
ensure_bun
ensure_rust
ensure_repo
install_deps
generate_identity_if_needed
write_fixnet_config
install_service

echo "Bootstrap complete for ${PUBLIC_URL}"
echo "Identity file: ${IDENTITY_FILE}"
if [[ -n "${ARCHIVE_DIR}" ]]; then
	echo "Archived prior install state to: ${ARCHIVE_DIR}"
fi
