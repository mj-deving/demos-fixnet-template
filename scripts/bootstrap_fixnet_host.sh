#!/usr/bin/env bash
set -euo pipefail

USER_NAME="demos"
REPO_DIR="/home/${USER_NAME}/node"
BRANCH="stabilisation"
UPSTREAM_REPO="https://github.com/kynesyslabs/node.git"
PUBLIC_URL=""
IDENTITY_FILE=""
DISABLE_MONITORING=false
ANCHOR_PUBKEY="0x680464e81ff8a088611d91eb97c40326dc3d8981bd29cf2721b47daa60f56274"
ANCHOR_URL="http://node3.demos.sh:60001"

usage() {
	cat <<'EOF'
Bootstrap a fresh DEMOS fixnet host.

Run as root on the target host.

Required:
  --public-url http://<public-ip-or-dns>:53550

Optional:
  --user demos
  --repo-dir /home/demos/node
  --branch stabilisation
  --upstream-repo https://github.com/kynesyslabs/node.git
  --identity-file /home/demos/.secrets/demos-mnemonic
  --anchor-pubkey 0x...
  --anchor-url http://node3.demos.sh:60001
  --disable-monitoring

Notes:
  - This script assumes one DEMOS node per host.
  - It installs Bun and Rust/Cargo for the service user if needed.
  - If no identity file is supplied, it performs a first boot to generate one,
    backs it up under ~/.secrets, then switches into fixnet mode.
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

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run this script as root" >&2
	exit 1
fi

HOME_DIR="/home/${USER_NAME}"
SECRETS_DIR="${HOME_DIR}/.secrets"
FIRST_RUN_LOG="${HOME_DIR}/first-run.log"
FIRST_RUN_PID="${HOME_DIR}/first-run.pid"

user_shell() {
	sudo -u "${USER_NAME}" -H bash -lc "$*"
}

ensure_base_packages() {
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
	if command -v docker >/dev/null 2>&1; then
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
	if user_shell 'test -x "$HOME/.bun/bin/bun"'; then
		return
	fi
	user_shell 'curl -fsSL https://bun.sh/install | bash'
}

ensure_rust() {
	if user_shell 'command -v cargo >/dev/null 2>&1'; then
		return
	fi
	user_shell 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
}

ensure_repo() {
	rm -rf "${REPO_DIR}"
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
	docker rm -f postgres_5332 neo4j-cgc tlsn-notary-7047 demos-prometheus demos-grafana >/dev/null 2>&1 || true
	rm -rf "${REPO_DIR}/postgres_5332" "${REPO_DIR}/logs" >/dev/null 2>&1 || true
}

generate_identity_if_needed() {
	if [[ -n "${IDENTITY_FILE}" ]] && [[ -f "${IDENTITY_FILE}" ]]; then
		return
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

	IDENTITY_FILE="${SECRETS_DIR}/$(hostname)-mnemonic"
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

	user_shell "cd ${REPO_DIR} && cat > .env <<ENV
PROD=true
EXPOSED_URL=${PUBLIC_URL}
ENV"

	user_shell "cd ${REPO_DIR} && cat > demos_peerlist.json <<JSON
{
  \"${ANCHOR_PUBKEY}\": \"${ANCHOR_URL}\"
}
JSON"

	rm -rf "${REPO_DIR}/postgres_5332"

	user_shell "cd ${REPO_DIR} && cat > fnode.sh <<SH
#!/usr/bin/env bash
export PATH=\"${HOME_DIR}/.bun/bin:${HOME_DIR}/.cargo/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\"
cd ${REPO_DIR}
exec ./run ${run_flags}
SH
chmod +x fnode.sh"
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
