#!/usr/bin/env bash
# Self-tests for code-ranker-ci. This is the ONLY reusable workflow + script
# pair that every code-ranker client runs on the v1 tag move, so a silent
# regression here ships to everyone at once. Run by hand with:
#
#   bash tests/run.sh
#
# Covers (see tests/README.md for the "why" and how to add a case):
#   1) scripts/build-comment.sh: the actual comment.md/errors.n it produces
#      for clean / findings (advisory+gate) / singular wording / baseline
#      diff + verdict + unchanged-language omission / malformed-input cases.
#   2) the HAS_LANGS gate expression used in report.yml's "Detect empty
#      analysis" step -- extracted LIVE from the workflow file (not copied),
#      so this can't silently drift from what actually runs.
#   3) referential integrity: every scripts/<file> that report.yml or
#      scripts/*.sh reference actually exists.
#
# Dependencies: bash, jq (build-comment.sh needs jq anyway), python3+PyYAML
# (only for the HAS_LANGS extraction -- see README). No network access.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD_COMMENT="$ROOT/scripts/build-comment.sh"
REPORT_YML="$ROOT/.github/workflows/report.yml"
FIXTURES="$HERE/fixtures"

PASS=0
FAIL=0

# ---------------------------------------------------------------- helpers --
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  local name="$1"; shift
  printf '  \033[31mFAIL\033[0m  %s\n' "$name"
  for m in "$@"; do printf '        %s\n' "$m"; done
}
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

assert_contains() { # name file needle
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
    pass "$1"
  else
    fail "$1" "expected to find: $3" "--- actual $2 ---" "$(cat "$2" 2>/dev/null || echo '<missing file>')"
  fi
}
assert_not_contains() { # name file needle
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
    fail "$1" "expected NOT to find: $3" "--- actual $2 ---" "$(cat "$2")"
  else
    pass "$1"
  fi
}
assert_eq() { # name actual expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3] got [$2]"; fi
}
assert_exit0() { # name exit_code
  if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "expected exit 0, got $2"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Runs build-comment.sh against a copy of tests/fixtures/<fixture>, in a
# clean env (+ whatever KEY=VAL pairs are passed), cwd = the fixture copy.
# Leaves comment.md / errors.n / _stdout.log / _stderr.log in $WORK/case for
# the assertions that follow. Echoes the exit code.
run_build_comment() {
  local fixture="$1"; shift
  rm -rf "$WORK/case"
  mkdir -p "$WORK/case"
  cp -R "$FIXTURES/$fixture/." "$WORK/case/"
  local rc
  ( cd "$WORK/case" && env -i PATH="$PATH" HOME="${HOME:-}" "$@" bash "$BUILD_COMMENT" \
      >"$WORK/case/_stdout.log" 2>"$WORK/case/_stderr.log" )
  rc=$?
  echo "$rc"
}

# ============================================================================
section "1) build-comment.sh -- clean run (no findings, no baseline, no verdict)"
# ============================================================================
rc=$(run_build_comment clean URL=https://example.com/report.html)
assert_exit0                    "clean: exits 0"                              "$rc"
assert_eq "clean: errors.n == 0" "$(cat "$WORK/case/errors.n" 2>/dev/null)" "0"
assert_contains     "clean: plain header + View report link" "$WORK/case/comment.md" \
  '## code-ranker <a href="https://example.com/report.html"'
assert_not_contains  "clean: no 'finding' wording"   "$WORK/case/comment.md" "finding"
assert_not_contains  "clean: no 'error ❌' wording"   "$WORK/case/comment.md" "error ❌"
assert_contains      "clean: AI fix-prompt present"  "$WORK/case/comment.md" "Prompt for fix all with AI"
# KNOWN GAP, not a regression introduced here -- see tests/README.md "Known
# spec gap": a no-comment sentinel for clean runs already exists on branch
# draft/contents-read-only (commit 07966da) but has not landed on
# hotfix/empty-analysis-no-op, so scripts/build-comment.sh as tested here does
# NOT emit it yet. We assert the real, current behaviour and pin the absence
# of the sentinel so this test starts failing (loudly, on purpose) the day
# someone ports that feature without updating the fixture/assertions.
assert_not_contains  "clean: no-comment sentinel absent (see README: known gap)" \
  "$WORK/case/comment.md" "<!-- code-ranker:no-comment -->"

# ============================================================================
section "2) build-comment.sh -- findings, advisory (DO_CHECK unset)"
# ============================================================================
rc=$(run_build_comment findings URL=https://example.com/report.html)
assert_exit0 "advisory: exits 0" "$rc"
assert_eq "advisory: errors.n == 2" "$(cat "$WORK/case/errors.n")" "2"
assert_contains     "advisory: neutral '2 findings' header" "$WORK/case/comment.md" "code-ranker: 2 findings"
assert_not_contains "advisory: no 'error ❌'"                 "$WORK/case/comment.md" "error ❌"
assert_not_contains "advisory: no 'Violations:' collapsible" "$WORK/case/comment.md" "Violations:"
assert_contains     "advisory: View report link present"     "$WORK/case/comment.md" "View report"
assert_contains     "advisory: AI fix-prompt present"        "$WORK/case/comment.md" "Prompt for fix all with AI"
assert_not_contains "advisory: no sentinel"                  "$WORK/case/comment.md" "<!-- code-ranker:no-comment -->"

# ============================================================================
section "3) build-comment.sh -- findings, gate (DO_CHECK=true)"
# ============================================================================
rc=$(run_build_comment findings URL=https://example.com/report.html DO_CHECK=true)
assert_exit0 "gate: exits 0" "$rc"
assert_eq "gate: errors.n == 2" "$(cat "$WORK/case/errors.n")" "2"
assert_contains "gate: 'error ❌' header wording"        "$WORK/case/comment.md" "code-ranker: 2 errors ❌"
assert_contains "gate: collapsed 'Violations: 2' block"  "$WORK/case/comment.md" "<details><summary>Violations: 2</summary>"

# ============================================================================
section "4) build-comment.sh -- singular wording (one finding)"
# ============================================================================
rc=$(run_build_comment single-finding URL=https://example.com/report.html)
assert_exit0 "singular advisory: exits 0" "$rc"
assert_contains     "singular advisory: '1 finding' (not findings)" "$WORK/case/comment.md" "code-ranker: 1 finding "
assert_not_contains "singular advisory: never '1 findings'"         "$WORK/case/comment.md" "1 findings"

rc=$(run_build_comment single-finding URL=https://example.com/report.html DO_CHECK=true)
assert_exit0 "singular gate: exits 0" "$rc"
assert_contains     "singular gate: '1 error ❌' (not errors)" "$WORK/case/comment.md" "code-ranker: 1 error ❌"
assert_not_contains "singular gate: never '1 errors'"          "$WORK/case/comment.md" "1 errors"

# ============================================================================
section "5) build-comment.sh -- with baseline: diff table, verdict, unchanged-language omission"
# ============================================================================
# Fixture has two languages: python (stats + 1 violation changed vs baseline)
# and go (byte-identical stats, 0 violations in both) -- go must not appear.
rc=$(run_build_comment baseline-diff URL=https://example.com/report.html REPORT_KIND="diff report" VERDICT=degraded)
assert_exit0 "baseline+degraded: exits 0" "$rc"
assert_contains     "baseline+degraded: verdict badge in header" "$WORK/case/comment.md" "🔴 degraded"
assert_contains     "baseline+degraded: 'View diff report' link" "$WORK/case/comment.md" "View diff report"
assert_contains     "baseline+degraded: diff table header row"   "$WORK/case/comment.md" "| Metric |"
assert_contains     "baseline+degraded: python section present"  "$WORK/case/comment.md" "<details><summary>python:"
assert_not_contains "baseline+degraded: go section is OMITTED"   "$WORK/case/comment.md" "<details><summary>go"
assert_not_contains "baseline+degraded: no 'No metric changes.' noise" "$WORK/case/comment.md" "No metric changes."
assert_contains     "baseline+degraded: baseline info line"      "$WORK/case/comment.md" "<sub>baseline "

rc=$(run_build_comment baseline-diff URL=https://example.com/report.html VERDICT=neutral)
assert_exit0 "baseline+neutral: exits 0" "$rc"
assert_not_contains "baseline+neutral: verdict word 'neutral' never leaks into output" \
  "$WORK/case/comment.md" "neutral"
assert_not_contains "baseline+neutral: no verdict emoji badge" "$WORK/case/comment.md" "🟢"

rc=$(run_build_comment baseline-diff URL=https://example.com/report.html)
assert_exit0 "baseline+unset-verdict: exits 0" "$rc"
assert_not_contains "baseline+unset-verdict: no verdict emoji badge either" "$WORK/case/comment.md" "🔴"

# ============================================================================
section "6) build-comment.sh -- malformed input never crashes the job"
# ============================================================================
# snap.json = {} (no plugins/languages/git at all), viol.json = invalid JSON.
rc=$(run_build_comment malformed)
assert_exit0 "malformed: exits 0 despite garbage input" "$rc"
assert_eq "malformed: errors.n == 0" "$(cat "$WORK/case/errors.n" 2>/dev/null)" "0"
if [ -s "$WORK/case/comment.md" ]; then
  pass "malformed: comment.md was written and is non-empty"
else
  fail "malformed: comment.md was written and is non-empty" "file missing or empty"
fi
assert_contains "malformed: still emits a header" "$WORK/case/comment.md" "code-ranker"

# ============================================================================
section "7) HAS_LANGS gate expression (extracted LIVE from report.yml)"
# ============================================================================
HL_EXPR=""
if HL_EXPR="$(python3 "$HERE/lib/extract_has_langs_expr.py" "$REPORT_YML" 2>"$WORK/hl_err.log")"; then
  pass "has_langs: extracted the jq filter from report.yml"
else
  fail "has_langs: extracted the jq filter from report.yml" "$(cat "$WORK/hl_err.log")"
fi

if [ -n "$HL_EXPR" ]; then
  check_has_langs() { # name json expected(true|false)
    local name="$1" json="$2" expected="$3" actual
    if printf '%s' "$json" | jq -e "$HL_EXPR" >/dev/null 2>&1; then actual=true; else actual=false; fi
    assert_eq "$name" "$actual" "$expected"
  }
  check_has_langs "has_langs: plugins+languages populated -> true" \
    '{"plugins":["rust"],"languages":{"rust":{}}}' true
  check_has_langs "has_langs: both empty -> false" \
    '{"plugins":[],"languages":{}}' false
  check_has_langs "has_langs: only languages populated -> true" \
    '{"languages":{"python":{}}}' true
  check_has_langs "has_langs: empty object -> false" \
    '{}' false
fi

# ============================================================================
section "8) Referential integrity: report.yml / scripts/*.sh reference only existing files"
# ============================================================================
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if [ -f "$ROOT/$ref" ]; then
    pass "report.yml -> $ref exists"
  else
    fail "report.yml -> $ref exists" "referenced but missing on disk"
  fi
done < <(grep -oE 'scripts/[A-Za-z0-9_.-]+' "$REPORT_YML" | sort -u)

while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if [ -f "$ROOT/scripts/$ref" ]; then
    pass "scripts/*.sh -> \$HERE/$ref exists"
  else
    fail "scripts/*.sh -> \$HERE/$ref exists" "referenced but missing on disk"
  fi
done < <(grep -ohE '\$HERE/[A-Za-z0-9_.-]+' "$ROOT"/scripts/*.sh | sed 's#^\$HERE/##' | sort -u)

# ------------------------------------------------------------------ summary --
printf '\n%s\n' "----------------------------------------"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31mFAILED\033[0m\n'
  exit 1
fi
printf '\033[32mALL GREEN\033[0m\n'
exit 0
