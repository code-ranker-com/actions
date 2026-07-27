#!/usr/bin/env python3
"""Pull the exact jq HAS_LANGS filter out of report.yml's "Detect empty
analysis" step, so the test exercises the LIVE expression instead of a copy
that can silently drift from the real workflow.

Usage: extract_has_langs_expr.py path/to/report.yml
Prints the jq filter string to stdout (no trailing newline mangling beyond
what print() adds); exits 1 with a message on stderr if the step or the
`jq -e '...'` pattern inside it can't be found (fail loud, not empty).
"""
import re
import sys

import yaml


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract_has_langs_expr.py <report.yml>", file=sys.stderr)
        return 1
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        workflow = yaml.safe_load(f)

    run_script = None
    for job in (workflow.get("jobs") or {}).values():
        for step in job.get("steps") or []:
            if step.get("name") == "Detect empty analysis":
                run_script = step.get("run", "")
                break
        if run_script is not None:
            break

    if run_script is None:
        print("could not find the 'Detect empty analysis' step", file=sys.stderr)
        return 1

    # The step shells out to: jq -e '<filter>' snap.json ...
    m = re.search(r"jq\s+-e\s+'(.*?)'", run_script, re.DOTALL)
    if not m:
        print("could not find a jq -e '...' filter in that step", file=sys.stderr)
        return 1

    print(m.group(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
