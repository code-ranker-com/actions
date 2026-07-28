#!/usr/bin/env python3
"""Dump the two delivery steps' guards from report.yml for tests/run.sh.

Delivery is either the legacy synchronous POST (callers whose stub still grants
`id-token: write`) or the `code-ranker-report` artifact the backend picks up by
webhook. Exactly one must run: both would post the report twice, neither would
lose it silently while the job stays green. Those guards are an `if:` expression
apiece, so the test reads them out of the live workflow rather than restating
them and drifting.

Writes <outdir>/{legacy_if,artifact_if,detect_run,step_names}.txt; exits 1 with
a message on stderr if a step is missing.
"""
import pathlib
import sys

import yaml

LEGACY = "Deliver report (legacy OIDC callers)"
ARTIFACT = "Upload code-ranker-report artifact"
DETECT = "Detect delivery path"


def main() -> int:
    workflow, outdir = sys.argv[1], pathlib.Path(sys.argv[2])
    steps = yaml.safe_load(open(workflow))["jobs"]["code-ranker"]["steps"]
    by_name = {s.get("name"): s for s in steps if s.get("name")}

    missing = [n for n in (LEGACY, ARTIFACT, DETECT) if n not in by_name]
    if missing:
        print(f"missing step(s) in {workflow}: {missing}", file=sys.stderr)
        return 1

    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "legacy_if.txt").write_text(str(by_name[LEGACY].get("if", "")))
    (outdir / "artifact_if.txt").write_text(str(by_name[ARTIFACT].get("if", "")))
    (outdir / "detect_run.txt").write_text(str(by_name[DETECT].get("run", "")))
    (outdir / "step_names.txt").write_text("\n".join(by_name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
