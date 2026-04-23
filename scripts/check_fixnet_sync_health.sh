#!/usr/bin/env bash
set -euo pipefail

LOCAL_URL="http://127.0.0.1:53550/info"
ANCHOR_URL=""
EXPECTED_ANCHOR_IDENTITY=""
SERVICE_NAME="demos-node.service"
STATE_FILE="/var/lib/demos-fixnet-health/state.json"
OUTPUT_FILE="/var/lib/demos-fixnet-health/latest.json"
MAX_LAG="100"

usage() {
	cat <<'EOF'
Check recurring DEMOS fixnet sync health on a host.

This script is intended for timer-based recurring checks. It writes a JSON
status file and exits non-zero only when the node looks unhealthy or stalled.

Optional:
  --local-url http://127.0.0.1:53550/info
  --anchor-url http://node3.demos.sh:60001/info
  --expected-anchor-identity 0x...
  --service-name demos-node.service
  --state-file /var/lib/demos-fixnet-health/state.json
  --output-file /var/lib/demos-fixnet-health/latest.json
  --max-lag 100

Exit codes:
  0  Healthy or actively syncing
  1  Unhealthy or stalled
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
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
	--service-name)
		SERVICE_NAME="${2:-}"
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
	--max-lag)
		MAX_LAG="${2:-}"
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

if [[ -n "${ANCHOR_URL}" && "${ANCHOR_URL}" != */info ]]; then
	ANCHOR_URL="${ANCHOR_URL%/}/info"
fi

install -d -m 755 "$(dirname "${STATE_FILE}")" "$(dirname "${OUTPUT_FILE}")"

service_state="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

local_payload_path="${tmpdir}/local.json"
anchor_payload_path="${tmpdir}/anchor.json"

errors=()
warnings=()

if ! curl -fsS --max-time 15 "${LOCAL_URL}" >"${local_payload_path}"; then
	errors+=("local_info_unreachable")
fi

if [[ -n "${ANCHOR_URL}" ]]; then
	if ! curl -fsS --max-time 15 "${ANCHOR_URL}" >"${anchor_payload_path}"; then
		errors+=("anchor_info_unreachable")
	fi
fi

if [[ "${service_state}" != "active" ]]; then
	errors+=("service_not_active:${service_state:-unknown}")
fi

python3 - "${local_payload_path}" "${anchor_payload_path}" "${STATE_FILE}" "${OUTPUT_FILE}" "${MAX_LAG}" "${EXPECTED_ANCHOR_IDENTITY}" "$(printf '%s\n' "${errors[@]}")" "$(printf '%s\n' "${warnings[@]}")" <<'PY'
import json
import os
import sys
import time
from pathlib import Path


def load_json(path: str):
    if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
        return None
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def find_self_peer(payload: dict | None):
    if not payload:
        return None
    identity = payload.get("identity")
    peerlist = payload.get("peerlist") or []
    for peer in peerlist:
        if peer.get("identity") == identity:
            return peer
    return None


local_payload = load_json(sys.argv[1])
anchor_payload = load_json(sys.argv[2])
state_file = Path(sys.argv[3])
output_file = Path(sys.argv[4])
max_lag = int(sys.argv[5])
expected_anchor_identity = sys.argv[6]
errors = [line for line in sys.argv[7].splitlines() if line]
warnings = [line for line in sys.argv[8].splitlines() if line]

previous = {}
if state_file.exists():
    try:
        previous = json.loads(state_file.read_text(encoding="utf-8"))
    except Exception:
        previous = {}

local_self = find_self_peer(local_payload)
anchor_self = find_self_peer(anchor_payload) if anchor_payload else None

if local_payload and not local_self:
    errors.append("local_self_peer_missing")
if anchor_payload and not anchor_self:
    errors.append("anchor_self_peer_missing")

now = int(time.time())
local_identity = (local_payload or {}).get("identity")
anchor_identity = (anchor_payload or {}).get("identity")

if expected_anchor_identity and anchor_identity and anchor_identity != expected_anchor_identity:
    errors.append("anchor_identity_mismatch")

local_block = None
local_ready = None
if local_self:
    local_block = (local_self.get("sync") or {}).get("block")
    local_ready = (local_self.get("status") or {}).get("ready")

anchor_block = None
anchor_ready = None
if anchor_self:
    anchor_block = (anchor_self.get("sync") or {}).get("block")
    anchor_ready = (anchor_self.get("status") or {}).get("ready")

lag = None
if isinstance(local_block, int) and isinstance(anchor_block, int):
    lag = max(anchor_block - local_block, 0)

previous_block = previous.get("local_block")
progressed = None
if isinstance(local_block, int) and isinstance(previous_block, int):
    progressed = local_block > previous_block

if local_ready is False:
    warnings.append("local_ready_false")

status = "unhealthy"
if errors:
    status = "unhealthy"
elif lag is not None and lag <= max_lag and local_ready is True:
    status = "healthy"
elif progressed is False:
    status = "stalled"
    errors.append("block_not_advancing")
else:
    status = "syncing"

if lag is not None and lag > max_lag:
    warnings.append(f"lag_above_threshold:{lag}")

payload = {
    "checked_at": now,
    "status": status,
    "service_state": "active" if "service_not_active:active" not in errors else "active",
    "local_url": local_payload.get("connectionString") if local_payload else None,
    "anchor_url": anchor_payload.get("connectionString") if anchor_payload else None,
    "local_identity": local_identity,
    "anchor_identity": anchor_identity,
    "expected_anchor_identity": expected_anchor_identity or None,
    "local_block": local_block,
    "anchor_block": anchor_block,
    "lag": lag,
    "local_ready": local_ready,
    "anchor_ready": anchor_ready,
    "previous_local_block": previous_block,
    "progressed_since_previous_check": progressed,
    "errors": errors,
    "warnings": warnings,
}

output_file.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
state_file.write_text(
    json.dumps(
        {
            "checked_at": now,
            "local_block": local_block,
            "status": status,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

print(json.dumps(payload, indent=2))

if status == "unhealthy" or status == "stalled":
    raise SystemExit(1)
PY
