#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression cover for .github/workflows/estate-sweep-watchdog.yml.
#
# The watchdog's script lives inside a YAML block scalar, where it cannot be
# linted or run, and the lockfile rules forbid it a `uses:` — so it cannot borrow
# a test action either. This test extracts the script WITH A PARSER (scripts/lib/
# yaml.sh, upstream rule Y-1: never grep YAML), then executes that exact text
# against synthetic run histories with a fake `gh`. It is what PR #44 did by hand
# once; committed, it is what stops the next edit from shipping an untested one.
#
# Property under test (added 2026-09-29): when the sweep STARTED and then FAILED,
# the watchdog quotes the failed run's own check-run annotations in its comment,
# because a job log is a redirect to blob storage that many readers cannot fetch
# while annotations are plain REST — and the last three diagnoses of this sweep
# were reasoned from run durations for exactly that reason. The evidence is
# BEST EFFORT: if it cannot be read the issue must still be opened, because
# opening the issue is the watchdog's whole job.
#
# The fake `gh` RUNS every --jq filter against canned JSON, so a broken filter
# fails here rather than on the first real stale day.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$ROOT/.github/workflows/estate-sweep-watchdog.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# shellcheck source=scripts/lib/yaml.sh
. "$ROOT/scripts/lib/yaml.sh"
if [ "$(yaml_parser_kind)" = none ] || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: needs a YAML parser and jq to extract and drive the watchdog script"
  exit 0
fi

SCRIPT="$TMP/watchdog.sh"
if ! yaml_to_json "$WF" | jq -er '.jobs.watchdog.steps[0].run' >"$SCRIPT"; then
  echo "FAIL: could not extract the watchdog's run script from $WF" >&2
  exit 1
fi
bash -n "$SCRIPT" || { echo "FAIL: the extracted watchdog script does not parse" >&2; exit 1; }

# ── the fake gh ──────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
sub="${1:-}"
shift || true
case "$sub" in
  api)
    endpoint="" jqexpr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jqexpr="$2"; shift 2 ;;
        -*) shift ;;
        *) [ -n "$endpoint" ] || endpoint="$1"; shift ;;
      esac
    done
    echo "api $endpoint" >>"$CALLS"
    emit() { if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s' "$1"; fi; }
    default_jobs='{"jobs":[{"id":9001,"conclusion":"failure"},{"id":9002,"conclusion":"success"}]}'
    case "$endpoint" in
      */actions/workflows/ci-health-sweep.yml/runs*) emit "$RUNS_JSON" ;;
      */actions/runs/*/jobs*) emit "${JOBS_JSON:-$default_jobs}" ;;
      */check-runs/9001/annotations*)
        [ "${ANN_FAIL:-0}" = 1 ] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
        emit "$ANN_JSON" ;;
      */check-runs/*/annotations*) emit '[]' ;;
      *) echo "unexpected endpoint: $endpoint" >&2; exit 1 ;;
    esac ;;
  issue)
    action="${1:-}"
    echo "issue $*" >>"$CALLS"
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--body" ] && printf '%s' "${args[$((i + 1))]}" >"$CASE_DIR/body.md"
    done
    [ "$action" = list ] && [ -n "${EXISTING:-}" ] && printf '%s\n' "$EXISTING"
    exit 0 ;;
  *) echo "unexpected gh: $sub $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

ago() { date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ; }

# run_watchdog <script> [VAR=value ...]  -> sets rc out calls body
run_watchdog() {
  local script="$1"
  shift
  case_dir="$TMP/case$RANDOM$RANDOM"
  mkdir -p "$case_dir"
  : >"$case_dir/calls.log"
  rc=0
  out="$(env PATH="$TMP/bin:$PATH" GH_TOKEN=fixture REPO=metadatastician/metadatastician-governance \
    CASE_DIR="$case_dir" CALLS="$case_dir/calls.log" EXISTING=43 "$@" bash "$script" 2>&1)" || rc=$?
  calls="$(cat "$case_dir/calls.log")"
  body=""
  [ -f "$case_dir/body.md" ] && body="$(cat "$case_dir/body.md")"
}

FAIL_ANN='[
 {"annotation_level":"failure","title":"","message":"Process completed with exit code 2."},
 {"annotation_level":"failure","title":"CI-Health detection incomplete","message":"beta — repository-tree query failed; workflow trigger health is unknown [gh: Git Repository is empty. (HTTP 409)]"},
 {"annotation_level":"warning","title":"","message":"a warning worth keeping"},
 {"annotation_level":"notice","title":"","message":"The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026."}
]'

runs_failed="{\"workflow_runs\":[{\"id\":555,\"conclusion\":\"failure\",\"created_at\":\"$(ago '2 hours')\"},{\"id\":444,\"conclusion\":\"success\",\"created_at\":\"$(ago '60 hours')\"}]}"

has() { printf '%s' "$1" | grep -qF -- "$2"; }

# ── Scenario checks (each prints nothing; 0 = property holds) ────────────────
check_quotes_annotations() { # started-and-failed: the run's own annotations are quoted
  run_watchdog "$1" RUNS_JSON="$runs_failed" ANN_JSON="$FAIL_ANN"
  [ "$rc" -eq 0 ] && printf '%s' "$calls" | grep -q '^issue comment' \
    && has "$body" 'started and then failed' \
    && has "$body" 'What that run reported about itself' \
    && has "$body" 'failure: Process completed with exit code 2.' \
    && has "$body" 'failure: CI-Health detection incomplete — beta — repository-tree query failed' \
    && has "$body" '[gh: Git Repository is empty. (HTTP 409)]' \
    && has "$body" 'warning: a warning worth keeping' \
    && ! has "$body" 'ubuntu-latest label' \
    && has "$body" '~~~text'
}

check_best_effort() { # annotations unreadable: the issue is STILL opened, and says why
  run_watchdog "$1" RUNS_JSON="$runs_failed" ANN_JSON="$FAIL_ANN" ANN_FAIL=1
  [ "$rc" -eq 0 ] && printf '%s' "$calls" | grep -q '^issue comment' \
    && has "$body" 'started and then failed' \
    && has "$body" 'annotations could not be read from here'
}

check_nothing_recorded() { # a failure with no failure annotation says so instead of inventing one
  run_watchdog "$1" RUNS_JSON="$runs_failed" ANN_JSON='[{"annotation_level":"notice","title":"","message":"just a notice"}]'
  [ "$rc" -eq 0 ] && has "$body" 'no failure annotation was recorded beyond its exit status' && ! has "$body" '~~~text'
}

check_startup_no_evidence() { # a run that never started has no jobs: no evidence is fetched, lockfile guidance shown
  run_watchdog "$1" RUNS_JSON="{\"workflow_runs\":[{\"id\":555,\"conclusion\":\"startup_failure\",\"created_at\":\"$(ago '2 hours')\"},{\"id\":444,\"conclusion\":\"success\",\"created_at\":\"$(ago '60 hours')\"}]}"
  [ "$rc" -eq 0 ] && has "$body" 'did not start' && has "$body" 'An invalid lockfile' \
    && ! has "$body" 'What that run reported about itself' && ! printf '%s' "$calls" | grep -q '/jobs'
}

check_healthy_closes() { # fresh success on top: close the issue, fetch nothing
  run_watchdog "$1" RUNS_JSON="{\"workflow_runs\":[{\"id\":555,\"conclusion\":\"success\",\"created_at\":\"$(ago '2 hours')\"}]}"
  [ "$rc" -eq 0 ] && printf '%s' "$calls" | grep -q '^issue close' && ! printf '%s' "$calls" | grep -q '/annotations'
}

check_no_history() { # no runs at all
  run_watchdog "$1" RUNS_JSON='{"workflow_runs":[]}'
  [ "$rc" -eq 0 ] && has "$body" 'no run history at all' && ! has "$body" 'What that run reported about itself'
}

check_opens_when_absent() { # no rolling issue yet: create one rather than comment on nothing
  run_watchdog "$1" RUNS_JSON="$runs_failed" ANN_JSON="$FAIL_ANN" EXISTING=
  [ "$rc" -eq 0 ] && printf '%s' "$calls" | grep -q '^issue create' && has "$body" 'failure: Process completed with exit code 2.'
}

check_sanitised() { # quoted text cannot close its own fence, carry backticks, or run away in size
  local long
  long="$(printf 'x%.0s' $(seq 1 900))"
  run_watchdog "$1" RUNS_JSON="$runs_failed" ANN_JSON="$(jq -n --arg long "$long" '
    [ {"annotation_level":"failure","title":"","message":"closes ~~~ the fence and `injects` code"},
      {"annotation_level":"failure","title":"","message":$long} ]
    + [range(0;60) | {"annotation_level":"failure","title":"","message":("line \(.)")}]')"
  local quoted lines longest
  quoted="$(printf '%s\n' "$body" | sed -n '/^~~~text$/,/^~~~$/p' | sed '1d;$d')"
  lines="$(printf '%s\n' "$quoted" | wc -l)"
  longest="$(printf '%s\n' "$quoted" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  [ "$rc" -eq 0 ] && [ "$lines" -le 30 ] && [ "$longest" -le 600 ] \
    && ! printf '%s' "$quoted" | grep -q '`' && ! printf '%s' "$quoted" | grep -q '~~~' \
    && [ "$(printf '%s\n' "$body" | grep -c '^~~~$')" -eq 1 ]
}

echo "estate-sweep-watchdog.yml — extracted script, synthetic histories"

check_quotes_annotations "$SCRIPT" && ok "started-and-failed: the run's own annotations are quoted (failures and warnings; notices left out)" || bad "quotes annotations"
check_best_effort "$SCRIPT" && ok "best effort: unreadable annotations never stop the issue being posted, and the comment says why" || bad "best effort"
check_nothing_recorded "$SCRIPT" && ok "honest: a failure with no failure annotation says so" || bad "nothing recorded"
check_startup_no_evidence "$SCRIPT" && ok "startup_failure: no jobs to ask, lockfile guidance shown, no evidence block" || bad "startup_failure branch"
check_healthy_closes "$SCRIPT" && ok "silence: a fresh success closes the issue and fetches nothing" || bad "healthy closes"
check_no_history "$SCRIPT" && ok "no runs: says so, no evidence block" || bad "no history"
check_opens_when_absent "$SCRIPT" && ok "no rolling issue yet: opens one, evidence included" || bad "opens when absent"
check_sanitised "$SCRIPT" && ok "quoted text: at most 30 lines of 600 chars, no backticks, cannot close its fence" || bad "sanitised"

# ── Mutants: each must make its check fail ───────────────────────────────────
kill_with() { # kill_with <name> <check> <sed expression>
  local name="$1" check="$2" expr="$3" copy="$TMP/mutant-$1.sh"
  sed "$expr" "$SCRIPT" >"$copy"
  if cmp -s "$copy" "$SCRIPT"; then bad "mutant $name: expression no longer changes the script (stale test)"; return; fi
  if "$check" "$copy"; then bad "mutant $name SURVIVED $check"; else ok "mutant $name killed by $check"; fi
}
kill_with fatal-evidence check_best_effort 's/if evidence=\$(run_evidence "\$latest_id" 2>\/dev\/null); then/evidence=$(run_evidence "$latest_id" 2>\/dev\/null); if true; then/'
kill_with block-not-in-body check_quotes_annotations 's/^\( *\)\${evidence_block}$/\1/'
kill_with notices-leak check_quotes_annotations 's/select(.annotation_level=="failure" or .annotation_level=="warning")/select(.annotation_level != "")/'
kill_with fence-unsanitised check_sanitised 's/ | sed '"'"'s\/~~~\/---\/g'"'"'//'
kill_with no-line-limit check_sanitised 's/ | head -n 30 || true//'

echo
if [ "$fail" -ne 0 ]; then
  echo "estate-sweep-watchdog-test: $fail failure(s), $pass passed"
  exit 1
fi
echo "estate-sweep-watchdog-test: all $pass check(s) passed"
