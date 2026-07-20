#!/usr/bin/env bash
# Builds the WHOLE PR comment (v5: one report/check over all languages) from a
# single snapshot. Reads (cwd): snap.json, baseline/snap.json (optional),
# viol.json. Env: URL (report url), REPORT_KIND ("diff report"|"report").
# Writes: comment.md  and  errors.n (total violations).
#
# This runs BEFORE the report is uploaded, so the real report URL isn't known
# yet: callers pass the literal placeholder string `{{CR_REPORT_URL}}` as URL,
# and comment.md is written with that placeholder inlined into the "View
# report" link. Whoever posts the comment (the code-ranker backend for PRs, the
# Job summary step for pushes) substitutes the real URL in afterwards -- this
# script never talks to the upload API and has no notion of upload failure.
#
# v5 snapshot nests each plugin under .languages.<lang>.graphs.<level>; violations
# carry a .language field. The comment is one header (ok / N errors), one "View
# report" button, a <details> per language (its violations + stat-diff), one
# baseline line, and one AI fix prompt. Metric labels/groups/directions are read
# from the snapshot — nothing hardcoded (see difftable.jq).
#
# No sticky-comment marker is written here: the backend prefixes its own
# identifying marker when it posts/updates the PR comment.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

fmtdate() { local s="$1"; if [ "${#s}" -ge 16 ]; then echo "${s:0:10} ${s:11:5} UTC"; else echo "$s"; fi; }

# Per-language accessors into the v5 snapshot ($1=lang $2=file).
lstats()  { jq -c --arg l "$1" '((.languages[$l].graphs // {}) | to_entries[0].value).stats // {}' "$2"; }
lmeta()   { jq -c --arg l "$1" '((.languages[$l].graphs // {}) | to_entries[0].value).node_attributes // {}' "$2"; }
lgroups() { jq -c --arg l "$1" '((.languages[$l].graphs // {}) | to_entries[0].value).attribute_groups // {}' "$2"; }
lcounts() {
  jq -c --arg l "$1" '
    ((.languages[$l].graphs // {}) | to_entries[0].value) as $g
    | ($g.node_kinds // {}) as $nk
    | [ $g.nodes[]? | select((.external != true) and (($nk[.kind].external // false) != true)) ] as $int
    | ($int | map(.id)) as $ids
    | { Files: ($int | length),
        Folders: ($ids | map(sub("/[^/]*$"; "")) | unique | length),
        Crates: (($g.ui.grouping.key // null) as $gk | if $gk == null then null
                 else ($int | map(.[$gk]) | map(select(. != null and . != "")) | unique | length) end),
        Edges: ([ $g.edges[]? | select((.source | IN($ids[])) and (.target | IN($ids[]))) ] | length),
        cycles: ([ $g.cycles[]?.nodes[]? ] | unique | length) }' "$2"
}
countrows() { # $1 lang -> [{label,b,c,dir}] (baseline vs current for that language)
  jq -nc --argjson b "$(lcounts "$1" baseline/snap.json)" --argjson c "$(lcounts "$1" snap.json)" '
    [ {label:"Files",b:$b.Files,c:$c.Files,dir:null},
      {label:"Folders",b:$b.Folders,c:$c.Folders,dir:null},
      {label:"Crates",b:$b.Crates,c:$c.Crates,dir:null},
      {label:"Edges",b:$b.Edges,c:$c.Edges,dir:null},
      {label:"Nodes in cycles",b:$b.cycles,c:$c.cycles,dir:true} ]
    | map(select(.b != null and .c != null)) '
}

CDATE="$(fmtdate "$(jq -r '.generated_at // ""' snap.json 2>/dev/null)")"
CORIGIN="$(jq -r '.git.origin // ""' snap.json 2>/dev/null)"
CCOMMIT="$(jq -r '.git.commit // ""' snap.json 2>/dev/null)"
KIND="${REPORT_KIND:-report}"

# Normalize violations to a flat array once.
jq 'if type=="array" then . else (.violations // []) end' viol.json > _viol.json 2>/dev/null || echo '[]' > _viol.json
TOTAL="$(jq 'length' _viol.json 2>/dev/null || echo 0)"

# Languages present in current (or baseline) snapshot, sorted.
langs="$(jq -rn --slurpfile a snap.json --slurpfile b baseline/snap.json \
  '([($a[0].languages // {}|keys[]), ($b[0].languages // {}|keys[])] | add | unique)[]' 2>/dev/null \
  || jq -r '.languages // {} | keys[]' snap.json)"

# Header. The actionable signal is the violation COUNT; the `neutral` verdict is
# noise (the per-language stat-diff already shows improved/degraded per metric), so
# it is dropped — only `improved`/`degraded` still tag the header. A clean run with
# nothing to flag is just `code-ranker` + the View-report link.
case "${VERDICT:-}" in
  improved) VE="🟢 improved" ;;
  degraded) VE="🔴 degraded" ;;
  *)        VE="" ;;            # neutral / unset → no verdict noise
esac
if [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null; then
  if [ -f baseline/snap.json ]; then W=new; else W=errors; [ "$TOTAL" -eq 1 ] && W=error; fi
  HEAD="code-ranker: ${VE:+${VE} · }${TOTAL} ${W} ❌"
elif [ -n "$VE" ]; then
  HEAD="code-ranker: ${VE}"
else
  HEAD="code-ranker"
fi

# Baseline line (one snapshot).
if [ -f baseline/snap.json ]; then
  BREF="$(jq -r '.git.branch // "baseline"' baseline/snap.json)"
  BCOMMIT="$(jq -r '.git.commit // ""' baseline/snap.json)"
  BORIGIN="$(jq -r '.git.origin // ""' baseline/snap.json)"
  BDATE="$(fmtdate "$(jq -r '.generated_at // ""' baseline/snap.json)")"
  if [ -n "$BORIGIN" ] && [ -n "$BCOMMIT" ]; then
    BLINK="[${BREF} @${BCOMMIT:0:7}](${BORIGIN}/commit/${BCOMMIT})"
  else
    BLINK="${BREF} @${BCOMMIT:0:7}"
  fi
  INFO="baseline ${BLINK} ${BDATE} · updated ${CDATE}"
  bbranch="$(jq -r '.git.branch // ""' baseline/snap.json)"
  cbranch="$(jq -r '.git.branch // ""' snap.json)"
else
  INFO="updated ${CDATE}"
fi

{
  # Title + report link on ONE line (the link is inlined into the H2 header).
  # URL is normally the literal {{CR_REPORT_URL}} placeholder at this point
  # (see the header comment above) -- whoever posts the comment fills it in.
  if [ -n "${URL:-}" ]; then
    echo "## ${HEAD} <a href=\"${URL}\" target=\"_blank\" rel=\"noopener noreferrer\">View ${KIND} ↗</a>"
  else
    echo "## ${HEAD}"
  fi
  echo

  for lang in $langs; do
    n="$(jq --arg l "$lang" '[.[] | select(.language == $l)] | length' _viol.json 2>/dev/null || echo 0)"
    # stat-diff for this language (computed first so a no-change language can be skipped).
    if [ -f baseline/snap.json ]; then
      DIFF="$(jq -rn \
        --argjson counts "$(countrows "$lang")" \
        --argjson bstats "$(lstats "$lang" baseline/snap.json)" \
        --argjson cstats "$(lstats "$lang" snap.json)" \
        --argjson meta   "$(lmeta "$lang" snap.json)" \
        --argjson groups "$(lgroups "$lang" snap.json)" \
        --arg bhdr "$( [ -n "${CORIGIN}" ] && [ -n "${bbranch:-}" ] && printf '[Baseline](%s/tree/%s)' "$CORIGIN" "$bbranch" || printf 'Baseline')" \
        --arg chdr "$( [ -n "${CORIGIN}" ] && [ -n "${cbranch:-}" ] && printf '[Current](%s/tree/%s)' "$CORIGIN" "$cbranch" || printf 'Current')" \
        -f "$HERE/difftable.jq")"
    else
      DIFF="_No baseline yet._"
    fi
    # Skip a language with nothing to report: no violations AND no metric/count
    # changes vs the baseline (keeps the comment focused on what actually moved).
    if [ "${n:-0}" -eq 0 ] 2>/dev/null && [ "$DIFF" = "_No metric changes._" ]; then
      continue
    fi
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      w=errors; [ "$n" -eq 1 ] && w=error
      sum="${lang}: ${n} ${w} ❌"
    else
      sum="${lang}: ok"
    fi
    echo "<details><summary>${sum}</summary>"
    echo
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
      echo "<details><summary>Violations: ${n}</summary>"
      echo
      jq -r --arg l "$lang" --arg origin "$CORIGIN" --arg sha "$CCOMMIT" '
        (($origin != "") and ($sha != "")) as $hl
        | [.[] | select(.language == $l)][]
        | (.location | sub("^\\{target\\}/";"")) as $loc
        | (if .line then ":"+(.line|tostring) else "" end) as $ln
        | (if .line then "#L"+(.line|tostring) else "" end) as $anchor
        | (if $hl then "[\($loc)\($ln)](\($origin)/blob/\($sha)/\($loc)\($anchor))" else "`\($loc)\($ln)`" end) as $loclink
        | (.message | if $hl then gsub("\\{target\\}/(?<p>[^\\s]+)"; "[\(.p)](" + $origin + "/blob/" + $sha + "/" + .p + ")") else gsub("\\{target\\}/"; "") end) as $msg
        | "- \($loclink) — \($msg)"' _viol.json 2>/dev/null | head -20
      echo
      echo "</details>"
      echo
    fi
    echo "$DIFF"
    echo
    echo "</details>"
    echo
  done

  # AI fix prompt first, then the baseline/updated line at the very bottom.
  if [ "${TOTAL:-0}" -gt 0 ] 2>/dev/null; then
    echo "<details>"
    echo "<summary>🤖 Prompt for fix all with AI</summary>"
    echo
    echo '```'
    echo "Run code-ranker check --top 1 and follow instructions to fix error. Loop until no errors left."
    echo '```'
    echo
    echo "</details>"
    echo
  fi
  echo "<sub>${INFO}</sub>"
} > comment.md

echo "${TOTAL:-0}" > errors.n
