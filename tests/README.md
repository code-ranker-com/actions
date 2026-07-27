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

## Clean runs post nothing

A fully clean run — no findings, no metric changes, no improved/degraded verdict
— has nothing worth saying, so `scripts/build-comment.sh` writes only
`<!-- code-ranker:no-comment -->` into `comment.md`. Whoever posts skips it: the
backend for PR comments (`routes::webhook` and, for legacy OIDC callers,
`routes::upload`), the job summary for pushes. The report is still published and
reachable from the dashboard — a green PR just doesn't get nagged.

Test case 1 pins exactly that: the sentinel is present, and the header, the
`View report` link and the AI fix-prompt are all absent.

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
