#!/usr/bin/env python3
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "fixtures" / "host-state"
EVALUATOR = ROOT / "scripts" / "evaluate_host_state.py"


def main() -> int:
    fixture_paths = sorted(FIXTURES.glob("*.json"))
    if not fixture_paths:
        raise SystemExit("No host-state fixtures found")

    failures = []
    for fixture_path in fixture_paths:
        fixture = json.loads(fixture_path.read_text())
        expected = fixture.pop("expected")
        result = subprocess.run(
            ["python3", str(EVALUATOR)],
            input=json.dumps(fixture),
            text=True,
            capture_output=True,
            check=True,
        )
        actual = json.loads(result.stdout)
        for key, value in expected.items():
            if actual.get(key) != value:
                failures.append(
                    f"{fixture_path.name}: expected {key}={value!r}, got {actual.get(key)!r}"
                )

    if failures:
        raise SystemExit("\n".join(failures))

    print(f"validated {len(fixture_paths)} host-state fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
