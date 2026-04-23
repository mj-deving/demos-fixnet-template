#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PATH="/usr/local/bin/check_fixnet_sync_health.sh"
ENV_FILE="/etc/demos-fixnet-health.env"
SERVICE_NAME="demos-node.service"
LOCAL_URL="http://127.0.0.1:53550/info"
ANCHOR_URL=""
EXPECTED_ANCHOR_IDENTITY=""
INTERVAL_MINUTES="5"
MAX_LAG="100"
STATE_FILE="/var/lib/demos-fixnet-health/state.json"
OUTPUT_FILE="/var/lib/demos-fixnet-health/latest.json"
RUN_NOW=false

usage() {
	cat <<'EOF'
Install a recurring systemd health monitor for a DEMOS fixnet node.

Run on the target host as root.

Optional:
  --install-path /usr/local/bin/check_fixnet_sync_health.sh
  --env-file /etc/demos-fixnet-health.env
  --service-name demos-node.service
  --local-url http://127.0.0.1:53550/info
  --anchor-url http://node3.demos.sh:60001/info
  --expected-anchor-identity 0x...
  --interval-minutes 5
  --max-lag 100
  --state-file /var/lib/demos-fixnet-health/state.json
  --output-file /var/lib/demos-fixnet-health/latest.json
  --run-now
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--install-path)
		INSTALL_PATH="${2:-}"
		shift 2
		;;
	--env-file)
		ENV_FILE="${2:-}"
		shift 2
		;;
	--service-name)
		SERVICE_NAME="${2:-}"
		shift 2
		;;
	--local-url)
		LOCAL_URL="${2:-}"
		shift 2
		;;
	--anchor-url)
		ANCHOR_URL="${2:-}"
		shift 2
		;;
	--expected-anchor-identity)
		EXPECTED_ANCHOR_IDENTITY="${2:-}"
		shift 2
		;;
	--interval-minutes)
		INTERVAL_MINUTES="${2:-}"
		shift 2
		;;
	--max-lag)
		MAX_LAG="${2:-}"
		shift 2
		;;
	--state-file)
		STATE_FILE="${2:-}"
		shift 2
		;;
	--output-file)
		OUTPUT_FILE="${2:-}"
		shift 2
		;;
	--run-now)
		RUN_NOW=true
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

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run this script as root" >&2
	exit 1
fi

install -d -m 755 "$(dirname "${INSTALL_PATH}")" "$(dirname "${STATE_FILE}")" "$(dirname "${OUTPUT_FILE}")"
install -m 755 "${SCRIPT_DIR}/check_fixnet_sync_health.sh" "${INSTALL_PATH}"

cat >"${ENV_FILE}" <<EOF
SERVICE_NAME='${SERVICE_NAME}'
LOCAL_URL='${LOCAL_URL}'
ANCHOR_URL='${ANCHOR_URL}'
EXPECTED_ANCHOR_IDENTITY='${EXPECTED_ANCHOR_IDENTITY}'
MAX_LAG='${MAX_LAG}'
STATE_FILE='${STATE_FILE}'
OUTPUT_FILE='${OUTPUT_FILE}'
EOF
chmod 600 "${ENV_FILE}"

cat >/etc/systemd/system/demos-fixnet-health.service <<EOF
[Unit]
Description=DEMOS fixnet recurring health check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_PATH} --service-name "\${SERVICE_NAME}" --local-url "\${LOCAL_URL}" --anchor-url "\${ANCHOR_URL}" --expected-anchor-identity "\${EXPECTED_ANCHOR_IDENTITY}" --max-lag "\${MAX_LAG}" --state-file "\${STATE_FILE}" --output-file "\${OUTPUT_FILE}"
EOF

cat >/etc/systemd/system/demos-fixnet-health.timer <<EOF
[Unit]
Description=Run DEMOS fixnet health check every ${INTERVAL_MINUTES} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL_MINUTES}min
Unit=demos-fixnet-health.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now demos-fixnet-health.timer

if [[ "${RUN_NOW}" == "true" ]]; then
	systemctl start demos-fixnet-health.service
fi

echo "Installed DEMOS fixnet health monitor"
echo "Service: demos-fixnet-health.service"
echo "Timer:   demos-fixnet-health.timer"
echo "Status file: ${OUTPUT_FILE}"
echo "View latest status with:"
echo "  cat ${OUTPUT_FILE}"
