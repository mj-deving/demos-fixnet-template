#!/usr/bin/env python3
import json
import sys


def classify(payload: dict) -> dict:
    inputs = payload.get("inputs", {})
    state = payload.get("state", {})

    host_mode = inputs.get("host_mode", "")
    desired_branch = inputs.get("desired_branch", "stabilisation")
    existing_branch = state.get("existing_branch") or ""

    residue = any(
        [
            state.get("service_exists"),
            state.get("repo_exists"),
            state.get("containers_exist"),
        ]
    )
    runtime_unhealthy = any(
        [
            not state.get("docker_installed", False),
            not state.get("docker_version_ok", False),
            not state.get("docker_compose_ok", False),
            not state.get("bun_installed", False),
            not state.get("bun_version_ok", False),
            not state.get("rust_installed", False),
            not state.get("rust_version_ok", False),
        ]
    )

    if not state.get("apt_healthy", False):
        classification = "broken_package_manager"
        strategy = "abort_requires_human"
        summary = "package manager is unhealthy"
    elif host_mode == "fresh" and residue:
        classification = "residue_present"
        strategy = "abort_and_require_reuse_mode"
        summary = "fresh-host path found existing DEMOS residue"
    elif residue and existing_branch and existing_branch != desired_branch:
        classification = "legacy_demos_install"
        strategy = "archive_and_replace_install"
        summary = f"existing DEMOS install is on legacy branch {existing_branch}"
    elif residue:
        classification = "existing_demos_install"
        strategy = "replace_existing_install"
        summary = "existing DEMOS footprint detected"
    elif runtime_unhealthy:
        classification = "stale_or_partial_host"
        strategy = "repair_runtime_then_install"
        summary = "runtime components are missing, outdated, or partial"
    else:
        classification = "fresh_candidate"
        strategy = "fresh_install"
        summary = "host looks ready for a clean install"

    return {
        "classification": classification,
        "recommended_strategy": strategy,
        "host_summary": summary,
    }


def main() -> int:
    payload = json.load(sys.stdin)
    result = classify(payload)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
