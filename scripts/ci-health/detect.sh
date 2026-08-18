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
sf=0
while IFS= read -r workflow_id; do
  [ -z "$workflow_id" ] && continue
  if ! latest=$(gh api "repos/$O/$R/actions/workflows/$workflow_id/runs?per_page=1" --jq '.workflow_runs[0] | [.id, (.conclusion // "")] | @tsv'); then
    die_api "latest-run query failed for workflow $workflow_id; run health is unknown"
  fi
  [ -z "$latest" ] && continue
  IFS=$'\t' read -r run_id conclusion <<<"$latest"
  [ "$conclusion" = startup_failure ] && sf=$((sf + 1))
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

# --- B: active startup failures (symptom).
[ "$sf" -gt 0 ] && emit B-STARTUPFAIL HIGH "$sf active workflow(s) have startup_failure as their latest run → inspect the run banner and policy/pinning inputs"

# --- D: burn anti-pattern (bare [push, pull_request] double-trigger), via API
if ! paths=$(gh api "repos/$O/$R/git/trees/$default_branch?recursive=1" --jq '.tree[]? | select(.type=="blob" and (.path | test("^\\.github/workflows/.*\\.ya?ml$"))) | .path'); then
  die_api "repository-tree query failed; workflow trigger health is unknown"
fi
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
