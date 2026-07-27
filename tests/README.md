# tests/

Self-tests for this repo's reusable workflow. Every code-ranker client runs
`.github/workflows/report.yml` (and `scripts/build-comment.sh`) on the moving
`v1` tag, so a regression here ships to everyone at once. These tests exist to
catch that before the tag moves.

## Running

```sh
bash tests/run.sh
```

No flags, no setup. Dependencies: `bash`, `jq` (build-comment.sh itself needs
jq, so this adds nothing new), and `python3` with `PyYAML` installed
(`python3 -c "import yaml"` should not error) -- used only to pull the
HAS_LANGS jq filter live out of `report.yml` (see below). Everything else is
plain POSIX-ish bash. No network access, no writes outside a `mktemp -d`
scratch dir.

Output is PASS/FAIL per assertion, with the expected vs. actual `comment.md`
printed inline on failure. Exit code is 0 iff everything passed.

The rest of the CI checks (actionlint, YAML sanity, shellcheck) live directly
in `.github/workflows/ci.yml` as plain CLI invocations -- there was no benefit
to wrapping those in this runner too.

## What's covered

- `scripts/build-comment.sh` against realistic (small, hand-written, but real
  v5-shaped) snapshot fixtures under `tests/fixtures/*/snap.json` (+ optional
  `baseline/snap.json`, `viol.json`): clean run, advisory findings, gate
  findings, singular ("1 finding"/"1 error", never "1 findings"/"1 errors"),
  baseline diff table + verdict badge (`improved`/`degraded` show,
  `neutral`/unset never do) + an unchanged language being fully omitted
  (no "No metric changes." noise), and malformed/empty input (script must
  still exit 0 and write a sane `comment.md`).
- The `HAS_LANGS` gate expression from `report.yml`'s "Detect empty analysis"
  step, run against four snapshot shapes. The filter is **extracted live**
  from `report.yml` by `tests/lib/extract_has_langs_expr.py` (regex over the
  parsed YAML step body) rather than copy-pasted into the test, specifically
  so this can't quietly go stale if the expression in `report.yml` changes
  without the test being updated.
- Referential integrity: every `scripts/<file>` that `report.yml` invokes, and
  every `$HERE/<file>` that `scripts/*.sh` sources, actually exists on disk
  (catches a silent-breakage-by-rename).

## Known spec gap: the clean-run "no-comment" sentinel

While writing the clean-run fixture we found that `scripts/build-comment.sh`
on this branch (`hotfix/empty-analysis-no-op`, and `main`) does **not** emit a
`<!-- code-ranker:no-comment -->` sentinel for a fully clean run (no findings,
no metric changes, no verdict) -- it renders the normal header + AI-prompt +
baseline/updated line instead. That sentinel-based "skip posting a comment
entirely on a clean run" feature already exists, implemented, on branch
`draft/contents-read-only` (commit `07966da`, "feat: suppress the PR comment
on a clean run + per-branch baseline header") -- it just hasn't been merged
into this branch/`main` yet.

Test case 1 (`clean run`) therefore asserts the **real, current** behaviour
(no sentinel) and explicitly pins the sentinel's *absence*, with a comment
pointing back here, instead of quietly encoding the aspirational behaviour.
This is intentional, not an oversight: per the task scope, `build-comment.sh`'s
behaviour was not to be changed here beyond the optional `HAS_LANGS`
extraction. If/when `draft/contents-read-only` (or just that commit) lands on
this branch, flip that assertion to expect the sentinel and update this note.

## Adding a case

1. Add a fixture dir under `tests/fixtures/<name>/` with `snap.json` (v5
   shape: `plugins`, `git`, `languages.<lang>.graphs.<level>` with at least
   `node_attributes`/`attribute_groups`/`node_kinds`/`nodes`/`edges`/`cycles`/
   `stats` -- copy an existing fixture and edit rather than starting from
   scratch) and, if the case needs them, `baseline/snap.json` and/or
   `viol.json`.
2. In `tests/run.sh`, call `run_build_comment <name> KEY=VAL ...` (env vars
   map 1:1 to what `report.yml` sets: `URL`, `REPORT_KIND`, `DO_CHECK`,
   `VERDICT`) and assert against `$WORK/case/comment.md` / `errors.n` with
   `assert_contains` / `assert_not_contains` / `assert_eq` / `assert_exit0`.
3. Run `bash tests/run.sh` and confirm the new assertions actually fail when
   you'd expect them to (e.g. temporarily break the expected string) before
   trusting a PASS -- an assertion that can never fail is not a test.
