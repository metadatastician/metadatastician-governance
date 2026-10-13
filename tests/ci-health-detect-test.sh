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

# ── Non-lock startup_failure fixtures (SF_SCENARIO) ──────────────────────────
# One active workflow, governance.yml, whose latest run is a startup_failure by
# a human actor on the default branch. It calls a cross-repo reusable workflow
# in hyperpolymath/standards at a full-length SHA. The SCENARIO chooses which
# of the file-decidable faults the call carries:
#   perms     caller grants lack a scope the callee requires -> B-PERMS
#   offbranch the SHA compares diverged against the callee default -> B-OFFBRANCH
#   deadref   the SHA names no commit at all (compare 404)   -> B-OFFBRANCH
#   clean     no file-decidable fault -> falls through to the generic aggregate
#   callee503 the callee fetch fails transiently -> indeterminate, also generic
caller_yaml() {
  if [ "${SF_SCENARIO:-none}" = offbranch ] || [ "${SF_SCENARIO:-none}" = clean ] || [ "${SF_SCENARIO:-none}" = callee503 ]; then
    cat <<'YAML'
name: governance
on: schedule
permissions:
  contents: read
  actions: read
  security-events: write
jobs:
  call-standards:
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@092dedada188f56c5915f74a5fd40aac093742c3
YAML
  else
    cat <<'YAML'
name: governance
on: schedule
permissions:
  contents: read
  security-events: write
jobs:
  call-standards:
    uses: hyperpolymath/standards/.github/workflows/governance-reusable.yml@092dedada188f56c5915f74a5fd40aac093742c3
YAML
  fi
}
callee_yaml() {
  cat <<'YAML'
name: governance-reusable
on: workflow_call
permissions:
  contents: read
jobs:
  audit:
    runs-on: ubuntu-24.04
    permissions:
      actions: read
      security-events: write
    steps: []
YAML
}

case "$endpoint" in
  repos/metadatastician/sample) emit '{"archived":false,"fork":false,"default_branch":"main"}' ;;
  repos/metadatastician/sample/actions/workflows/42/runs*)
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run() { # run <id> <conclusion> <actor>
      printf '{"id":%s,"path":".github/workflows/governance.yml","conclusion":"%s","created_at":"%s","head_branch":"main","actor":{"login":"%s"},"triggering_actor":{"login":"%s"}}' "$1" "$2" "$now" "$3" "$3"
    }
    # RUNS chooses the run history, newest first (the API's order).
    case "${RUNS:-human-sf}" in
      human-sf) emit "{\"total_count\":1,\"workflow_runs\":[$(run 777000 startup_failure hyperpolymath)]}" ;;
      fenced-then-ok) emit "{\"total_count\":3,\"workflow_runs\":[$(run 777002 startup_failure 'dependabot[bot]'),$(run 777001 startup_failure 'coderabbitai[bot]'),$(run 777000 success hyperpolymath)]}" ;;
      fenced-only) emit "{\"total_count\":2,\"workflow_runs\":[$(run 777001 startup_failure 'coderabbitai[bot]'),$(run 777000 startup_failure 'arena-ai-coding-agent[bot]')]}" ;;
      unfenced-bot) emit "{\"total_count\":2,\"workflow_runs\":[$(run 777001 startup_failure 'some-other-app[bot]'),$(run 777000 success hyperpolymath)]}" ;;
      fenced-ok-run) emit "{\"total_count\":2,\"workflow_runs\":[$(run 777001 success 'dependabot[bot]'),$(run 777000 startup_failure hyperpolymath)]}" ;;
    esac ;;
  repos/metadatastician/sample/actions/workflows*)
    case "${SF_SCENARIO:-none}" in
      none) emit '{"total_count":0,"workflows":[]}' ;;
      *) emit '{"total_count":1,"workflows":[{"id":42,"state":"active"}]}' ;;
    esac ;;
  repos/metadatastician/sample/git/trees/main*)
    case "${TREE:-plain}" in
      plain) emit '{"tree":[{"path":"README.md","type":"blob"},{"path":"src","type":"tree"}],"truncated":false}' ;;
      burn) emit '{"tree":[{"path":"README.md","type":"blob"},{"path":".github/workflows/ci.yml","type":"blob"}]}' ;;
      sf) emit '{"tree":[{"path":".github/workflows/governance.yml","type":"blob"},{"path":"README.md","type":"blob"}],"truncated":false}' ;;
      empty) echo "gh: Git Repository is empty. (HTTP 409)" >&2; exit 1 ;;
      other409) echo "gh: Conflict (HTTP 409)" >&2; exit 1 ;;
      forbidden) echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;;
      notfound) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      unavailable) echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1 ;;
    esac ;;
  repos/metadatastician/sample/contents/.github/workflows/ci.yml*)
    emit "{\"content\":\"$(printf 'on: [push, pull_request]\njobs: {}\n' | base64 -w0)\"}" ;;
  repos/metadatastician/sample/contents/.github/workflows/governance.yml*)
    emit "{\"content\":\"$(caller_yaml | base64 -w0)\"}" ;;
  repos/metadatastician/sample/contents/.github/workflows/actions.lock*)
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  repos/hyperpolymath/standards) emit '{"default_branch":"main","archived":false,"fork":false}' ;;
  repos/hyperpolymath/standards/compare/*)
    case "${SF_SCENARIO:-none}" in
      offbranch) emit '{"status":"diverged","ahead_by":1,"behind_by":6}' ;;
      deadref) echo "gh: No commit found for SHA: 092dedada188f56c5915f74a5fd40aac093742c3 (HTTP 404)" >&2; exit 1 ;;
      *) emit '{"status":"ahead","ahead_by":2,"behind_by":0}' ;;
    esac ;;
  repos/hyperpolymath/standards/contents/.github/workflows/governance-reusable.yml?ref=*)
    case "${SF_SCENARIO:-none}" in
      callee503) echo "gh: upstream connect error (HTTP 503)" >&2; exit 1 ;;
      *) emit "{\"content\":\"$(callee_yaml | base64 -w0)\"}" ;;
    esac ;;
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

# run_detect_sf <detect.sh path> <SF_SCENARIO> -> sets rc, out, err. Drives the
# non-lock startup_failure diagnoses: the tree fixture is sf (one workflow,
# no actions.lock), and the scenario chooses the call-graph fault.
run_detect_sf() {
  local script="$1" scenario="$2"
  out="" err="" rc=0
  out="$(env PATH="$TMP/bin:$PATH" TREE=sf SF_SCENARIO="$scenario" OWNER=metadatastician CHECK_ALLOWLIST=false \
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
#
# A mutant runs from a MIRRORED layout, not from $TMP directly: detect.sh
# sources "$HERE/../lib/yaml.sh" at startup for the parser-first diagnoses,
# so the copy must sit where that relative path still resolves. Flat copies
# used to die with exit 1 at the source line and the mutation could never be
# observed — a test that cannot kill a mutant is not a test.
mutant() { # mutant <name> <sed expression>
  local name="$1" expr="$2" copy
  mkdir -p "$TMP/mutants/scripts/ci-health"
  [ -e "$TMP/mutants/scripts/lib" ] || ln -s "$ROOT/scripts/lib" "$TMP/mutants/scripts/lib"
  copy="$TMP/mutants/scripts/ci-health/$1-detect.sh"
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

# ── Non-lock startup_failure classes: B-PERMS / B-OFFBRANCH ─────────────────
# The 2026-09-29 census read every unclassified default-branch startup_failure
# banner off the public run pages: 7 of 13 were the standards#451 caller
# under-grant ("requesting 'actions: read', but is only allowed 'actions:
# none'"), and the zero-job off-branch pin was measured live in
# metadatastician-governance run 36361142305. detect.sh now names both from
# the mirrored files instead of leaving them in the generic bucket. These
# fixtures pin each behaviour down: firing, silence (no false positives), the
# indeterminate middle (transient API faults fall back to the generic line,
# never to a guess), and mutants for both predicates.
echo "detect.sh — non-lock startup_failure classes"

run_detect_sf "$DETECT" perms
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qP '\tB-PERMS\t' && printf '%s' "$out" | grep -q "actions: read required, none granted"; then
  ok "firing: caller under-grant is named B-PERMS with the exact missing scope"
else
  bad "B-PERMS missing: rc=$rc out=[$out] err=[$err]"
fi
if printf '%s' "$out" | grep -qP '\tB-STARTUPFAIL\t'; then
  bad "B-PERMS firing but the generic B-STARTUPFAIL aggregate still fired (the cause is attributed, it should not double-count)"
else
  ok "firing: B-PERMS replaces the generic aggregate for its workflow"
fi
if printf '%s' "$out" | grep -qP '\tB-OFFBRANCH\t'; then
  bad "B-PERMS fixture also emitted B-OFFBRANCH (compare was ahead/0: the pin is an ancestor)"
else
  ok "silence: an ancestor pin does not B-OFFBRANCH"
fi

run_detect_sf "$DETECT" offbranch
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qP '\tB-OFFBRANCH\t' && printf '%s' "$out" | grep -q 'diverged'; then
  ok "firing: diverged pin is named B-OFFBRANCH with the compare verdict"
else
  bad "B-OFFBRANCH missing: rc=$rc out=[$out] err=[$err]"
fi
if printf '%s' "$out" | grep -qP '\tB-PERMS\t'; then
  bad "B-OFFBRANCH fixture also emitted B-PERMS (the caller grant covers the callee requirement)"
else
  ok "silence: a sufficient grant does not B-PERMS"
fi

run_detect_sf "$DETECT" deadref
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qP '\tB-OFFBRANCH\t' && printf '%s' "$out" | grep -q 'does not resolve'; then
  ok "firing: a ref that names no commit is named B-OFFBRANCH, not left to the lock checker"
else
  bad "B-OFFBRANCH (unresolvable) missing: rc=$rc out=[$out] err=[$err]"
fi

run_detect_sf "$DETECT" clean
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qP '\tB-(OFFBRANCH|PERMS)\t'; then
  ok "silence: a healthy cross-repo call emits neither new class"
else
  bad "false positive in clean scenario: rc=$rc out=[$out]"
fi
if printf '%s' "$out" | grep -qP '\tB-STARTUPFAIL\t'; then
  ok "clean scenario still lands in the generic aggregate (honest: the API cannot name this one)"
else
  bad "clean scenario lost the generic B-STARTUPFAIL aggregate: out=[$out]"
fi

run_detect_sf "$DETECT" callee503
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qP '\tB-(OFFBRANCH|PERMS)\t'; then
  ok "indeterminate: a transient callee fetch fault emits no guess"
else
  bad "callee503 should fail open to the generic aggregate: rc=$rc out=[$out]"
fi
if printf '%s' "$out" | grep -qP '\tB-STARTUPFAIL\t'; then
  ok "indeterminate: the workflow stays counted in the generic aggregate, where a human will look"
else
  bad "callee503 dropped the generic B-STARTUPFAIL aggregate: out=[$out]"
fi

# ── Mutants for the two new predicates ───────────────────────────────────────
m3="$(mutant accept-diverged 's/^\s*diverged | behind)$/        behind)/')" && {
  run_detect_sf "$m3" offbranch
  if ! printf '%s' "$out" | grep -qP '\tB-OFFBRANCH\t'; then
    ok "mutant accept-diverged killed (a pin off the default line would pass silently)"
  else
    bad "mutant accept-diverged SURVIVED (out=[$out])"
  fi
}
m4="$(mutant never-undergrant 's/select(\$req\[\$k\] > \$g)/select($req[$k] > $g and false)/')" && {
  run_detect_sf "$m4" perms
  if ! printf '%s' "$out" | grep -qP '\tB-PERMS\t'; then
    ok "mutant never-undergrant killed (an under-grant would pass silently)"
  else
    bad "mutant never-undergrant SURVIVED (out=[$out])"
  fi
}

# ── Fenced actors: owner-ruled refusals are policy, not health ──────────────
# Owner ruling 2026-10-13 (metadatastician-governance#30, booked on
# hyperpolymath/standards#787): GitHub refusing dependabot[bot],
# coderabbitai[bot] and arena-ai-coding-agent[bot] is intended. Their startup
# refusals must not hold the rolling issue open, but nothing else may hide
# behind them: an unlisted app is still B-ACTOR, a human's startup_failure is
# still diagnosed, and with no fence configured the old behaviour is unchanged.
echo "detect.sh — fenced actors"

FENCE='dependabot[bot] coderabbitai[bot] arena-ai-coding-agent[bot]'

# run_detect_actor <detect.sh path> <RUNS scenario> <fence list> -> rc, out, err
run_detect_actor() {
  local script="$1" runs="$2" fence="$3"
  out="" err="" rc=0
  out="$(env PATH="$TMP/bin:$PATH" TREE=sf SF_SCENARIO=clean RUNS="$runs" CI_HEALTH_FENCED_ACTORS="$fence" \
    OWNER=metadatastician CHECK_ALLOWLIST=false bash "$script" sample 2>"$TMP/err")" || rc=$?
  err="$(cat "$TMP/err")"
}

run_detect_actor "$DETECT" fenced-then-ok ""
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qP '\tB-ACTOR\t' && printf '%s' "$out" | grep -qF 'dependabot[bot]'; then
  ok "no fence configured: a bot refusal is still B-ACTOR (behaviour unchanged)"
else
  bad "no fence: rc=$rc out=[$out] err=[$err]"
fi

run_detect_actor "$DETECT" fenced-then-ok "$FENCE"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "fenced refusals stepped over: the workflow is judged on its latest real run (success), no finding"
else
  bad "fenced-then-ok: rc=$rc out=[$out] err=[$err]"
fi
if printf '%s' "$err" | grep -qF 'stepped over 2 fenced-actor startup refusal(s)'; then
  ok "fenced refusals stepped over: the skip is announced on stderr with its count"
else
  bad "fenced-then-ok: no NOTE line; stderr=[$err]"
fi

run_detect_actor "$DETECT" fenced-only "$FENCE"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "only fenced refusals: no health signal, no finding (and no E-INSTRUMENT)"
else
  bad "fenced-only: rc=$rc out=[$out] err=[$err]"
fi

run_detect_actor "$DETECT" unfenced-bot "$FENCE"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qP '\tB-ACTOR\t' && printf '%s' "$out" | grep -qF 'some-other-app[bot]'; then
  ok "an app outside the fence is still B-ACTOR"
else
  bad "unfenced-bot: rc=$rc out=[$out] err=[$err]"
fi

run_detect_actor "$DETECT" human-sf "$FENCE"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qP '\tB-STARTUPFAIL\t'; then
  ok "a human's startup_failure is still diagnosed with the fence in place"
else
  bad "human-sf under fence: rc=$rc out=[$out] err=[$err]"
fi

run_detect_actor "$DETECT" fenced-ok-run "$FENCE"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && ! printf '%s' "$err" | grep -qF 'stepped over'; then
  ok "only refusals are stepped over: a fenced actor's successful run still counts as the latest run"
else
  bad "fenced-ok-run: rc=$rc out=[$out] err=[$err]"
fi

run_detect_actor "$DETECT" fenced-then-ok 'dependabot[bot] not;a-login'
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'E-INSTRUMENT' && printf '%s' "$out" | grep -qF 'not;a-login'; then
  ok "a malformed fence entry stops detection (E-INSTRUMENT) instead of guessing"
else
  bad "malformed fence: rc=$rc out=[$out]"
fi

m5="$(mutant fence-never-matches 's/any(\. == \$a or \. == \$t)/any(false)/')" && {
  run_detect_actor "$m5" fenced-then-ok "$FENCE"
  if printf '%s' "$out" | grep -qP '\tB-ACTOR\t'; then
    ok "mutant fence-never-matches killed (fenced refusals would hold the issue open again)"
  else
    bad "mutant fence-never-matches SURVIVED (out=[$out])"
  fi
}
m6="$(mutant fence-skips-everything 's/map(\.conclusion == "startup_failure"/map(true/')" && {
  run_detect_actor "$m6" fenced-ok-run "$FENCE"
  if printf '%s' "$out" | grep -qP '\tB-STARTUPFAIL\t'; then
    ok "mutant fence-skips-everything killed (a fenced actor's success would hide the failure behind it)"
  else
    bad "mutant fence-skips-everything SURVIVED (out=[$out])"
  fi
}

echo
if [ "$fail" -ne 0 ]; then
  echo "ci-health-detect-test: $fail failure(s), $pass passed"
  exit 1
fi
echo "ci-health-detect-test: all $pass check(s) passed"
