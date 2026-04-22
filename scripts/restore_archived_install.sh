#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_ROOT="/var/backups/demos-fixnet"
ARCHIVE_PATH=""
REPO_DIR=""
UPSTREAM_REPO="https://github.com/kynesyslabs/node.git"
BRANCH=""
SERVICE_NAME="demos-node.service"
START_SERVICE=false

usage() {
	cat <<'EOF'
Restore archived DEMOS install state captured by bootstrap_fixnet_host.sh reuse-host mode.

Run on the target host as root.

Optional:
  --archive-path /var/backups/demos-fixnet/<timestamp>
  --archive-root /var/backups/demos-fixnet
  --repo-dir /home/demos/node
  --upstream-repo https://github.com/kynesyslabs/node.git
  --branch stabilisation
  --service-name demos-node.service
  --start-service

Behavior:
  - restores archived config files and service unit when present
  - clones the upstream repo if the repo directory is missing
  - does not restore secrets; secret file inventory is only referenced from the archive
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--archive-path)
		ARCHIVE_PATH="${2:-}"
		shift 2
		;;
	--archive-root)
		ARCHIVE_ROOT="${2:-}"
		shift 2
		;;
	--repo-dir)
		REPO_DIR="${2:-}"
		shift 2
		;;
	--upstream-repo)
		UPSTREAM_REPO="${2:-}"
		shift 2
		;;
	--branch)
		BRANCH="${2:-}"
		shift 2
		;;
	--service-name)
		SERVICE_NAME="${2:-}"
		shift 2
		;;
	--start-service)
		START_SERVICE=true
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

if [[ -z "${ARCHIVE_PATH}" ]]; then
	ARCHIVE_PATH="$(find "${ARCHIVE_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n1)"
fi

if [[ -z "${ARCHIVE_PATH}" || ! -d "${ARCHIVE_PATH}" ]]; then
	echo "Archive directory not found" >&2
	exit 1
fi

manifest_value() {
	local key="$1"
	python3 - "${ARCHIVE_PATH}/manifest.json" "${key}" <<'PY'
import json
import sys
path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(key, "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

if [[ -f "${ARCHIVE_PATH}/manifest.json" ]]; then
	REPO_DIR="${REPO_DIR:-$(manifest_value repo_dir)}"
	BRANCH="${BRANCH:-$(manifest_value branch)}"
	SERVICE_NAME="${SERVICE_NAME:-$(manifest_value service_name)}"
fi

if [[ -z "${REPO_DIR}" ]]; then
	echo "Unable to determine repo directory; pass --repo-dir" >&2
	exit 1
fi

if [[ -z "${BRANCH}" ]]; then
	BRANCH="stabilisation"
fi

if systemctl list-unit-files "${SERVICE_NAME}" --no-legend 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
	systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
fi

if [[ ! -d "${REPO_DIR}" ]]; then
	install -d -m 755 "$(dirname "${REPO_DIR}")"
	git clone "${UPSTREAM_REPO}" "${REPO_DIR}"
	git -C "${REPO_DIR}" checkout "${BRANCH}"
fi

if [[ -f "${ARCHIVE_PATH}/repo-config.tar" ]]; then
	tar -C "${REPO_DIR}" -xf "${ARCHIVE_PATH}/repo-config.tar"
fi

if [[ -f "${ARCHIVE_PATH}/demos-node.service.bak" ]]; then
	cp "${ARCHIVE_PATH}/demos-node.service.bak" "/etc/systemd/system/${SERVICE_NAME}"
	systemctl daemon-reload
fi

echo "Restored archive: ${ARCHIVE_PATH}"
echo "Repo directory: ${REPO_DIR}"
if [[ -f "${ARCHIVE_PATH}/secrets-file-list.txt" ]]; then
	echo "Secret files referenced by archive:"
	sed 's/^/  - /' "${ARCHIVE_PATH}/secrets-file-list.txt"
	echo "Restore the required secret files manually before starting the service."
fi

if [[ "${START_SERVICE}" == "true" ]]; then
	systemctl enable --now "${SERVICE_NAME}"
fi
