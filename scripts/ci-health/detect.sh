#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# detect.sh — classify the infrastructure CI failure modes that repeatedly
# redden estate CI (diagnosed 2026-06-13). API-only; safe to run in CI with
# no local checkout. Emits TSV: <repo>\t<CLASS>\t<SEV>\t<detail → remedy>
#
# Classes:
#   A-BILLING      account Actions spending-limit/payment wall (OWNER-ONLY fix)
#   B-ALLOWLIST    selected mode whose patterns do not cover the canonical
#                  action superset (auto-remediable)
#   B-STARTUPFAIL  observed startup_failure runs (symptom; check allow-list)
#   D-BURN         workflow(s) on bare [push,pull_request] = 2x runs/PR
#                  (auto-remediable: scope push + concurrency-cancel)
#
# The API NEVER exposes the startup_failure reason; the GitHub web-UI red
# banner does (it names the blocked action). That is the human diagnostic.
set -euo pipefail
O="${OWNER:-metadatastician}"
R="$1"
HERE="$(cd "$(dirname "$0")" && pwd)" # for action-superset.txt (allow-list coverage)
STARTUP_FAILURE_SINCE="${STARTUP_FAILURE_SINCE:-$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)}"
emit() { printf '%s\t%s\t%s\t%s\n' "$R" "$1" "$2" "$3"; }
die_api() {
  emit E-INSTRUMENT CRITICAL "$1"
  exit 2
}
check_allowlist() {
  local scope="$1" aa cur req miss ntot nmiss first
  if ! aa=$(gh api "$scope/actions/permissions" --jq '.allowed_actions // empty'); then
    die_api "Actions-permissions query failed; allow-list health is unknown"
  fi
  [ "$aa" = selected ] || return 0
  if ! cur=$(gh api "$scope/actions/permissions/selected-actions" --jq '(.patterns_allowed // [])[]'); then
    die_api "selected-actions query failed; allow-list health is unknown"
  fi
  req=$({
    printf 'hyperpolymath/*\n'
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d;s/$/@*/' "$HERE/action-superset.txt"
  } | LC_ALL=C sort -u)
  cur=$(printf '%s\n' "$cur" | sed '/^$/d' | LC_ALL=C sort -u)
  miss=$(comm -23 <(printf '%s\n' "$req") <(printf '%s\n' "$cur"))
  if [ -n "$miss" ]; then
    ntot=$(printf '%s\n' "$req" | grep -c .)
    nmiss=$(printf '%s\n' "$miss" | grep -c .)
    first=$(printf '%s\n' "$miss" | head -n1)
    emit B-ALLOWLIST HIGH "ERR-SEC-003: selected + allow-list missing $nmiss/$ntot curated pattern(s) (e.g. $first) → apply curated superset"
  fi
}

if [ "$R" = @organization ]; then
  check_allowlist "orgs/$O"
  exit 0
fi

# diagnose_startup_failures — attribute each default-branch startup failure to a
# cause, using the same checkers the lock-sync gate runs. Emits one finding per
# cause; a failure with no attributable cause is still reported, aggregated, so
# the class can never be silently dropped.
diagnose_startup_failures() {
  local tmp drift_out dead_out path br p content n_unexplained=0 drift_status pin_status
  local paths=() drift_rows=() dead_pins=()
  tmp=$(mktemp -d) || die_api "cannot create a work directory for startup diagnosis"
  mkdir -p "$tmp/.github/workflows"

  for entry in "${sf_list[@]}"; do
    path=${entry%%$'\t'*}
    br=${entry#*$'\t'}
    br=${br%%$'\t'*}
    if [ -n "$br" ] && [ "$br" != "$default_branch" ]; then
      echo "NOTE $R $path startup_failure on $br (branch-scoped, not default-branch health)" >&2
      continue
    fi
    [ -n "$path" ] && paths+=("$path")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    rm -rf "$tmp"
    return 0
  fi

  # Mirror the repository's workflow directory + lock so the shared, offline
  # checkers can be run against the API view of the default branch.
  if ! wf_paths=$(gh api --paginate "repos/$O/$R/git/trees/$default_branch?recursive=1" --jq '.tree[]? | select(.type=="blob" and (.path | test("^\\.github/workflows/.*\\.ya?ml$"))) | .path'); then
    rm -rf "$tmp"
    die_api "workflow enumeration failed; startup-failure causes are unknown"
  fi
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! content=$(gh api "repos/$O/$R/contents/$p?ref=$default_branch" --jq '.content'); then
      rm -rf "$tmp"
      die_api "workflow-content query failed for $p; startup-failure causes are unknown"
    fi
    mkdir -p "$tmp/$(dirname "$p")"
    printf '%s' "$content" | base64 -d >"$tmp/$p"
  done <<<"$wf_paths"
  if lockb64=$(gh api "repos/$O/$R/contents/.github/workflows/actions.lock?ref=$default_branch" --jq '.content' 2>/dev/null); then
    printf '%s' "$lockb64" | base64 -d >"$tmp/.github/workflows/actions.lock"
  fi

  # NOTE the argument is a repo ROOT, not a workflows directory: the checker
  # derives <root>/.github/workflows itself. Passing the workflows dir (as an
  # earlier revision did) made the checker find no lockfile, report "out of the
  # enforcement cohort", exit 0, and silently disable this whole diagnosis.
  # `check-lock-sync.sh` exits 1 on drift and 2 when no check could be made;
  # both collapse to "nothing to report here" below, and the unexplained-failure
  # aggregate is what keeps a 2 from being read as a clean bill of health.
  if drift_out=$("$HERE/../check-lock-sync.sh" "$tmp" 2>&1); then
    drift_status=0
  else
    drift_status=$?
  fi
  if [ "$drift_status" -eq 2 ]; then
    rm -rf "$tmp"
    die_api "lock-sync check did not run: $drift_out"
  fi

  local -A seen_drift=()
  while IFS=$'\t' read -r path reason; do
    [ -z "$path" ] && continue
    seen_drift["$path"]=1
    emit B-LOCKFILE HIGH "ERR-SEC-004: $path $reason; failed run(s): $(printf '%s\n' "${sf_list[@]}" | awk -F '\t' -v p="$path" '$1==p {print $3}' | paste -sd, -) → regenerate actions.lock in the same commit as the ref change (gh actions-lock --no-migrate-local-actions; review the diff)"
  done < <(printf '%s\n' "$drift_out" | awk '
    /^FAIL / { p = $2; next }
    /^[[:space:]]+(refs missing from the lockfile:|stale lockfile entries:|stale lockfile entry: no such workflow file|no dependencies record|malformed dependency key|dependency has no resolvable commit|the recorded commit disagrees)/ {
      sub(/^[[:space:]]+/, "");
      if (p != "") { print p "\t" $0; p = "" }
    }')

  # A pin that resolves to no commit at all cannot be locked, so the lock can
  # never be brought back into sync until the workflow is re-pointed.
  if dead_out=$("$HERE/../check-lock-pins.sh" "$tmp" 2>&1); then
    pin_status=0
  else
    pin_status=$?
  fi
  if [ "$pin_status" -eq 2 ]; then
    rm -rf "$tmp"
    die_api "pin check did not run: $dead_out"
  fi
  while IFS= read -r line; do
    case "$line" in
    DEAD\ *) dead_pins+=("${line#DEAD }") ;;
    esac
  done <<<"$dead_out"
  if [ "${#dead_pins[@]}" -gt 0 ]; then
    for pin in "${dead_pins[@]}"; do
      emit B-BADPIN HIGH "ERR-SEC-005: $pin does not resolve to any commit (API 422) → re-point the workflow at the real commit for the version its comment names, then regenerate actions.lock"
    done
  fi

  for p in "${paths[@]}"; do
    if [ -z "${seen_drift[$p]:-}" ] && [ "${#dead_pins[@]}" -eq 0 ]; then
      n_unexplained=$((n_unexplained + 1))
    fi
  done
  if [ "$n_unexplained" -gt 0 ]; then
    emit B-STARTUPFAIL HIGH "$n_unexplained active workflow(s) have startup_failure as their latest run after policy epoch $STARTUP_FAILURE_SINCE and no lock cause was found → inspect the run banner in the web UI (the API does not expose it)"
  fi
  rm -rf "$tmp"
}

# --- Skip logic (own repos only; one API call for both flags)
if ! af=$(gh api "repos/$O/$R" --jq '[.archived, .fork, .default_branch] | @tsv'); then
  die_api "repository metadata query failed; no health conclusion drawn"
fi
IFS=$'\t' read -r is_archived is_fork default_branch <<<"$af"
case "$is_archived/$is_fork" in
true/true | true/false | false/true | false/false) ;;
*) die_api "repository metadata had an invalid shape: $af" ;;
esac
[ -n "$default_branch" ] || die_api "repository metadata omitted default_branch"
if [ "$is_archived" = "true" ] || [ "$is_fork" = "true" ]; then
  echo "SKIP $R archived/fork" >&2
  exit 0
fi

# --- A/B symptom scan: inspect the latest run of every active workflow. This
# is the explicit observation horizon: current workflow health, not an arbitrary
# page of historical runs.
if ! workflows=$(gh api --paginate "repos/$O/$R/actions/workflows?per_page=100" --jq '.workflows[] | select(.state=="active") | .id'); then
  die_api "active-workflow enumeration failed; run health is unknown"
fi
billing=false
sf_list=()      # "path<TAB>head_branch" for each active workflow whose latest run is a startup_failure
actor_refused=()  # "path<TAB>actor" for startup failures caused by an actor GitHub refuses to run
while IFS= read -r workflow_id; do
  [ -z "$workflow_id" ] && continue
  if ! latest=$(gh api "repos/$O/$R/actions/workflows/$workflow_id/runs?per_page=1" --jq '.workflow_runs[0] | [.id, (.path // ""), (.conclusion // ""), (.created_at // ""), (.head_branch // ""), (.actor.login // ""), (.triggering_actor.login // "")] | @tsv'); then
    die_api "latest-run query failed for workflow $workflow_id; run health is unknown"
  fi
  [ -z "$latest" ] && continue
  IFS=$'\t' read -r run_id wf_path conclusion created_at wf_branch actor trigger_actor <<<"$latest"
  if [ "$conclusion" = startup_failure ] && [[ "$created_at" > "$STARTUP_FAILURE_SINCE" ]]; then
    # ── Two DIFFERENT causes produce the identical `startup_failure` symptom ──
    #
    # 1. An invalid lockfile. Verified here 2026-09-28 on run 36295476367: the
    #    run page annotation reads "Invalid lockfile:
    #    .github/workflows/actions.lock#L1 — The lockfile could not be validated.
    #    Regenerate it by running `gh actions-lock`." Actor: a human, event:
    #    schedule.
    #
    # 2. An actor GitHub will not let run Actions at all. Verified on run
    #    36359814257: the annotation reads "Actor is not allowed to trigger
    #    Actions workflows. Workflow file: '.github/workflows/labels.yml'."
    #    Actor: a GitHub App (a coding agent). The affected workflow had NO
    #    `uses:` and its lock entry was `[]`, and it still could not start —
    #    and the same happened in repos carrying no lockfile at all. No YAML or
    #    lockfile change can fix this; it is settled before any file is read.
    #
    # Both are `startup_failure` with zero jobs and no REST-visible reason, so
    # only the actor distinguishes them from the API. Classifying them together
    # makes the whole class unfixable-by-reading-the-files, which is how it
    # survived four rolling issues.
    case "$actor" in
    *"[bot]")
      # App-triggered. Scheduled and human-triggered runs are the ones a lock
      # fault can actually kill; record app-triggered ones separately.
      actor_refused+=("$wf_path"$'\t'"$actor")
      ;;
    *)
      sf_list+=("$wf_path"$'\t'"$wf_branch"$'\t'"$run_id")
      ;;
    esac
  fi
  [ "$conclusion" = failure ] || continue
  if ! job_ids=$(gh api --paginate "repos/$O/$R/actions/runs/$run_id/jobs?per_page=100" --jq '.jobs[].id'); then
    die_api "job enumeration failed for run $run_id; billing health is unknown"
  fi
  while IFS= read -r job_id; do
    [ -z "$job_id" ] && continue
    if ! msg=$(gh api --paginate "repos/$O/$R/check-runs/$job_id/annotations?per_page=100" --jq '.[].message // empty'); then
      die_api "annotation enumeration failed for job $job_id; billing health is unknown"
    fi
    if printf '%s\n' "$msg" | grep -qiE 'payments have failed|spending limit'; then
      billing=true
      break
    fi
  done <<<"$job_ids"
done <<<"$workflows"
if [ "$billing" = true ]; then
  emit A-BILLING CRITICAL "Actions billing/spending-limit wall blocks billable jobs → OWNER: GitHub Settings -> Billing & plans"
fi

# --- B: repository allow-list under-coverage, when explicitly requested.
# The estate sweep checks the centrally enforced organization policy once.
# Fire when selected-mode and the allow-list does NOT cover the full curated
# superset that remediate.sh PUTs. Catches BOTH an empty list (post-wipe:
# hyperpolymath/* absent) AND an incomplete one (has hyperpolymath/* but is
# missing a third-party action, e.g. gitleaks — previously only B-STARTUPFAIL,
# which has no remediation). The required set mirrors remediate.sh's PUT body
# exactly (hyperpolymath/* + each superset line as owner/repo@*), so a remediate
# converges this to zero-missing and detect stops re-firing (idempotent).
[ "${CHECK_ALLOWLIST:-true}" = true ] && check_allowlist "repos/$O/$R"

# --- B: active startup failures, diagnosed.
# The API never exposes the startup failure's reason, but the two causes that
# dominate this estate are both checkable from the repository files, so report
# the cause instead of sending a human to read a web banner (which is what made
# this class re-fire, unactionable, through four rolling issues):
#
#   * lock drift  - a workflow whose `uses:` refs are not recorded under its own
#                   path in .github/workflows/actions.lock. GitHub refuses the
#                   run at creation: zero jobs, no log. Fix by regenerating the
#                   lock in the same commit as the ref change.
#   * a dead pin  - a `uses:` ref that resolves to no commit at all (a re-pointed
#                   SHA that does not exist). Unlockable until re-pointed.
#
# A third cause shares the identical symptom and is reported separately as
# B-ACTOR: GitHub refusing the *actor* outright ("Actor is not allowed to
# trigger Actions workflows"). It is decided before any workflow file is read,
# so it is invisible to every file-based check, and it is the cause of the
# app-authored failures this sweep previously could not explain.
#
# Branch-scoped failures (a run on a feature branch) are not this repository's
# default-branch health and are skipped rather than reported.
if [ "${#actor_refused[@]}" -gt 0 ]; then
  n_actor=${#actor_refused[@]}
  first=${actor_refused[0]}
  emit B-ACTOR HIGH "ERR-SEC-006: $n_actor active workflow(s) refused at startup because GitHub does not allow the triggering actor to run Actions (run-page annotation: 'Actor is not allowed to trigger Actions workflows'); latest: ${first%%$'\t'*} triggered by ${first#*$'\t'} → OWNER/SETTINGS: permit this app to trigger workflows in the org or repository Actions policy. This is not a YAML or lockfile fault and no file change can fix it."
fi

[ "${#sf_list[@]}" -gt 0 ] && diagnose_startup_failures


# --- D: burn anti-pattern (bare [push, pull_request] double-trigger), via API
#
# A repository with no commits has no workflow files, so there is nothing to
# classify. GitHub answers the tree query for it with 409 "Git Repository is
# empty." (409 is a documented response of this endpoint:
# docs.github.com/en/rest/git/trees). That is a DETERMINATE answer about the
# repository, not a failure to ask -- the distinction check-lock-pins.sh draws
# between a 404 and a 503 -- and treating it as E-INSTRUMENT let ONE empty
# repository refuse the whole estate report on every daily sweep from
# 2026-09-21 (runs 35562513590, 35688334220, 35819928020, 36379748097 and
# 36523577570: each job log ends "gh: Git Repository is empty. (HTTP 409)" and
# then "Detection was incomplete for 1 repo(s)").
#
# Only that exact answer is excused. Any other tree failure -- 403, 404, 422,
# 5xx, no network, or a 409 that says something else (GitHub also returns 409
# for a repository that is unavailable) -- is still an E-INSTRUMENT, so the
# sweep still refuses to call an estate healthy on the strength of a query it
# could not make.
tree_err=$(mktemp) || die_api "cannot create a scratch file for the repository-tree query"
if ! paths=$(gh api "repos/$O/$R/git/trees/$default_branch?recursive=1" --jq '.tree[]? | select(.type=="blob" and (.path | test("^\\.github/workflows/.*\\.ya?ml$"))) | .path' 2>"$tree_err"); then
  if grep -qF 'Git Repository is empty' "$tree_err"; then
    rm -f "$tree_err"
    echo "SKIP $R empty repository (no commits, so no workflows to classify)" >&2
    exit 0
  fi
  cat "$tree_err" >&2 # keep gh's own error text in the log, exactly as before
  rm -f "$tree_err"
  die_api "repository-tree query failed; workflow trigger health is unknown"
fi
rm -f "$tree_err"
while IFS= read -r path; do
  [ -z "$path" ] && continue
  if ! content=$(gh api "repos/$O/$R/contents/$path" --jq '.content'); then
    die_api "workflow-content query failed for $path; trigger health is unknown"
  fi
  if printf '%s' "$content" | base64 -d |
    grep -qE '^on:[[:space:]]*\[[[:space:]]*(push[[:space:]]*,[[:space:]]*pull_request|pull_request[[:space:]]*,[[:space:]]*push)[[:space:]]*\]'; then
    emit D-BURN MEDIUM "ERR-WF-014: $path on bare [push,pull_request] (2x runs/PR) → scope push to default branch + concurrency-cancel"
  fi
done <<<"$paths"
