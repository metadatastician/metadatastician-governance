#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression cover for the repository-tree step of scripts/ci-health/detect.sh.
#
# What happened: from 2026-09-21 the daily CI-Health Sweep refused to publish
# for eight days because ONE repository in the organisation had no commits.
# GitHub answers the tree query for such a repository with
#     gh: Git Repository is empty. (HTTP 409)
# and detect.sh turned every failed query into E-INSTRUMENT (exit 2), which
# sweep.sh treats as "detection incomplete; refusing a false health report".
# Five runs ended with exactly that line and "incomplete for 1 repo(s)".
#
# The property under test is the DISTINCTION, in the shape check-lock-pins.sh
# already uses for pins:
#
#   409 "Git Repository is empty."  -> determinate: no commits, so no workflows;
#                                      nothing to classify; exit 0, no finding
#   anything else that fails        -> indeterminate: the query was not answered;
#                                      exit 2 with E-INSTRUMENT, as before
#
# Get it wrong towards leniency and an estate is called healthy on the strength
# of a query that never returned; get it wrong towards strictness and one empty
# repository blanks the estate report. Both directions are driven below, and two
# mutants prove the assertions are able to fail.
#
# The fake `gh` RUNS the --jq filter it is given against canned JSON. A stub that
# returns already-filtered text cannot see a broken filter, which is exactly how
# lockfix.sh shipped a precedence bug that made it fail for every repository.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECT="$ROOT/scripts/ci-health/detect.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required to drive the fake gh"
  exit 0
fi

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
[ "${1:-}" = api ] || { echo "unexpected gh: $*" >&2; exit 1; }
shift
endpoint="" jqexpr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    -*) shift ;;
    *) [ -n "$endpoint" ] || endpoint="$1"; shift ;;
  esac
done
emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s' "$1"; fi; }
case "$endpoint" in
  repos/metadatastician/sample) emit '{"archived":false,"fork":false,"default_branch":"main"}' ;;
  repos/metadatastician/sample/actions/workflows*) emit '{"total_count":0,"workflows":[]}' ;;
  repos/metadatastician/sample/git/trees/main*)
    case "${TREE:-plain}" in
      plain) emit '{"tree":[{"path":"README.md","type":"blob"},{"path":"src","type":"tree"}],"truncated":false}' ;;
      burn) emit '{"tree":[{"path":"README.md","type":"blob"},{"path":".github/workflows/ci.yml","type":"blob"}]}' ;;
      empty) echo "gh: Git Repository is empty. (HTTP 409)" >&2; exit 1 ;;
      other409) echo "gh: Conflict (HTTP 409)" >&2; exit 1 ;;
      forbidden) echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;;
      notfound) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      unavailable) echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1 ;;
    esac ;;
  repos/metadatastician/sample/contents/.github/workflows/ci.yml*)
    emit "{\"content\":\"$(printf 'on: [push, pull_request]\njobs: {}\n' | base64 -w0)\"}" ;;
  *) echo "unexpected endpoint: $endpoint" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# run_detect <detect.sh path> <TREE scenario>  ->  sets rc, out, err
run_detect() {
  local script="$1" scenario="$2"
  out="" err="" rc=0
  out="$(env PATH="$TMP/bin:$PATH" TREE="$scenario" OWNER=metadatastician CHECK_ALLOWLIST=false \
    bash "$script" sample 2>"$TMP/err")" || rc=$?
  err="$(cat "$TMP/err")"
}

echo "detect.sh — repository-tree step"

# ── Silence: a repository with files and no workflows says nothing ───────────
run_detect "$DETECT" plain
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "silence: files, no workflows -> exit 0, no finding"; else bad "silence: rc=$rc out=[$out]"; fi

# ── Firing: the D-BURN path still works through the tree + contents queries ──
run_detect "$DETECT" burn
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'D-BURN'; then ok "firing: bare [push,pull_request] is still reported as D-BURN"; else bad "firing: rc=$rc out=[$out]"; fi

# ── The fix: an empty repository is a determinate non-finding ────────────────
run_detect "$DETECT" empty
if [ "$rc" -eq 0 ]; then ok "empty repository: exit 0 (was exit 2)"; else bad "empty repository: rc=$rc (want 0) err=[$err]"; fi
if [ -z "$out" ]; then ok "empty repository: no finding, and in particular no E-INSTRUMENT"; else bad "empty repository emitted: [$out]"; fi
if printf '%s' "$err" | grep -q '^SKIP sample empty repository'; then ok "empty repository: the skip is announced on stderr, not silent"; else bad "empty repository: no SKIP line; stderr=[$err]"; fi

# ── The boundary: everything else that fails stays an instrument failure ─────
for scenario in other409 forbidden notfound unavailable; do
  run_detect "$DETECT" "$scenario"
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'E-INSTRUMENT'; then
    ok "$scenario: still exit 2 with E-INSTRUMENT (a query that was not answered is not a clean bill)"
  else
    bad "$scenario: rc=$rc out=[$out]"
  fi
  if printf '%s' "$err" | grep -q '^gh: '; then ok "$scenario: gh's own error text still reaches stderr"; else bad "$scenario: gh error text lost; stderr=[$err]"; fi
done

# ── Mutants: prove the assertions can fail ───────────────────────────────────
# M1 excuses nothing (the pre-fix behaviour); M2 excuses everything.
mutant() { # mutant <name> <sed expression>
  local name="$1" expr="$2" copy="$TMP/mutant-$1.sh"
  sed "$expr" "$DETECT" >"$copy"
  if cmp -s "$copy" "$DETECT"; then bad "mutant $name: expression did not change the script (stale test)"; return 1; fi
  printf '%s' "$copy"
}

m1="$(mutant excuse-nothing "s/grep -qF 'Git Repository is empty'/grep -qF 'Git Repository is NOT-A-MESSAGE-GITHUB-SENDS'/")" && {
  run_detect "$m1" empty
  if [ "$rc" -eq 2 ]; then ok "mutant excuse-nothing killed (empty repository exits 2 again)"; else bad "mutant excuse-nothing SURVIVED (rc=$rc)"; fi
}
m2="$(mutant excuse-everything "s/grep -qF 'Git Repository is empty'/grep -qF ''/")" && {
  run_detect "$m2" forbidden
  if [ "$rc" -eq 0 ]; then ok "mutant excuse-everything killed (a 403 would have been called healthy)"; else bad "mutant excuse-everything SURVIVED (rc=$rc)"; fi
}

echo
if [ "$fail" -ne 0 ]; then
  echo "ci-health-detect-test: $fail failure(s), $pass passed"
  exit 1
fi
echo "ci-health-detect-test: all $pass check(s) passed"
