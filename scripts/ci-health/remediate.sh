#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# remediate.sh — apply the SAFE auto-remediations for the CI failure classes.
#   B-ALLOWLIST  -> PUT curated allow-list superset (hyperpolymath/* + pinned
#                   third-party), keep github-owned/verified/sha-pinning.
#   D-BURN       -> open an idempotent, signed burn-cut PR (scope push to the
#                   default branch + add concurrency-cancel) via the API.
#   A-BILLING    -> NEVER auto-fixed (account-level, owner-only); the driver
#                   aggregates these into the tracking issue.
#
# Guardrails (lessons from the 2026-06-13 sweep):
#   * own repos only: skip forks + archived.
#   * DENYLIST: skip ARR-special / cross-owner repos (e.g. 007).
#   * idempotent: detector compares the complete normalized set; branch/PR
#     operations are retried safely.
#   * dry-run honoured.
# Usage: remediate.sh <repo> <CLASS> <dry_run:true|false>
set -euo pipefail
O="${OWNER:-metadatastician}"
R="$1"
CLASS="$2"
DRY="${3:-true}"
BR="ci/ci-health-auto-remediation"
HERE="$(cd "$(dirname "$0")" && pwd)"
DENYLIST="${CI_HEALTH_DENYLIST:-}" # space-separated repo names to never touch

for d in $DENYLIST; do [ "$R" = "$d" ] && {
  echo "SKIP $R/$CLASS denylisted"
  exit 0
}; done
if [ "$R" != @organization ]; then
  if ! meta=$(gh api "repos/$O/$R" --jq '"\(.fork) \(.archived)"'); then
    echo "ERROR $R/$CLASS repository metadata query failed; refusing mutation" >&2
    exit 2
  fi
  read -r isfork isarch <<<"$meta"
  case "$isfork/$isarch" in
  true/true | true/false | false/true | false/false) ;;
  *)
    echo "ERROR $R/$CLASS repository metadata had invalid shape: $meta" >&2
    exit 2
    ;;
  esac
  { [ "$isfork" = "true" ] || [ "$isarch" = "true" ]; } && {
    echo "SKIP $R/$CLASS fork-or-archived"
    exit 0
  }
fi

case "$CLASS" in
B-ALLOWLIST)
  # Build body: hyperpolymath/* + each superset action as owner/repo@*
  body=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d;s/$/@*/' "$HERE/action-superset.txt" |
    {
      printf 'hyperpolymath/*\n'
      cat
    } |
    LC_ALL=C sort -u |
    jq -R -s -c 'split("\n") | map(select(length > 0)) as $pats | {"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":$pats}')
  if [ "$DRY" = "true" ]; then
    echo "DRYRUN $R/B-ALLOWLIST would PUT $(printf '%s' "$body" | jq '.patterns_allowed | length') patterns"
    exit 0
  fi
  if [ "$R" = @organization ]; then scope="orgs/$O"; else scope="repos/$O/$R"; fi
  printf '%s' "$body" | gh api -X PUT "$scope/actions/permissions/selected-actions" --input - >/dev/null
  n=$(gh api "$scope/actions/permissions/selected-actions" --jq '.patterns_allowed|length')
  if [ "$R" = @organization ]; then
    epoch=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    gh variable set CI_HEALTH_POLICY_EPOCH --org "$O" --body "$epoch" --visibility all
  fi
  echo "FIXED $R/B-ALLOWLIST -> $n patterns (sha-pinning unchanged)"
  ;;
D-BURN)
  def=$(gh api "repos/$O/$R" --jq '.default_branch')
  sha=$(gh api "repos/$O/$R/git/ref/heads/$def" --jq '.object.sha')
  if ! paths=$(gh api "repos/$O/$R/git/trees/$def?recursive=1" --jq '.tree[]? | select(.type=="blob" and (.path | test("^\\.github/workflows/.*\\.ya?ml$"))) | .path'); then
    echo "ERROR $R/D-BURN repository-tree query failed; refusing mutation" >&2
    exit 2
  fi
  targets=()
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! content=$(gh api "repos/$O/$R/contents/$p?ref=$def" --jq '.content'); then
      echo "ERROR $R/D-BURN workflow-content query failed for $p; refusing mutation" >&2
      exit 2
    fi
    printf '%s' "$content" | base64 -d |
      grep -qE '^on:[[:space:]]*\[[[:space:]]*(push[[:space:]]*,[[:space:]]*pull_request|pull_request[[:space:]]*,[[:space:]]*push)[[:space:]]*\]' && targets+=("$p")
  done <<<"$paths"
  [ "${#targets[@]}" -eq 0 ] && {
    echo "SKIP $R/D-BURN no-targets"
    exit 0
  }
  if [ "$DRY" = "true" ]; then
    echo "DRYRUN $R/D-BURN would patch ${#targets[@]} file(s) + open PR"
    exit 0
  fi
  if ! gh api "repos/$O/$R/branches/$BR" --jq '.name' >/dev/null 2>&1; then
    gh api -X POST "repos/$O/$R/git/refs" -f ref="refs/heads/$BR" -f sha="$sha" >/dev/null
  fi
  for p in "${targets[@]}"; do
    cur=$(gh api "repos/$O/$R/contents/$p?ref=$BR")
    ccontent=$(printf '%s' "$cur" | jq -r '.content' | tr -d '\n' | base64 -d)
    csha=$(printf '%s' "$cur" | jq -r '.sha')
    if [ -z "$ccontent" ]; then
      echo "SKIP $R/$p empty-decode (refusing to PUT an empty file)" >&2
      continue
    fi

    blk="on:
  push:
    branches: [$def]
  pull_request:"

    if ! printf '%s' "$ccontent" | grep -q '^[[:space:]]*concurrency:'; then
      blk="$blk

# Estate guardrail: scope push to default branches (PR fires once, not
# push+PR) and cancel superseded runs. Safe — read-only PR check.
concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true"
    fi

    patched=$(printf '%s' "$ccontent" | awk -v blk="$blk" '
        /^on:[ \t]*\[[ \t]*push[ \t]*,[ \t]*pull_request[ \t]*\][ \t]*$/ && !done {
          print blk
          done = 1
          next
        }
        { print }
      ')

    # printf '%s\n' restores the final newline the $( ) captures strip
    newc=$(printf '%s\n' "$patched" | base64 | tr -d '\n')
    gh api -X PUT "repos/$O/$R/contents/$p" -f message="ci: cut Actions burn in $p (scope push + concurrency-cancel)" \
      -f content="$newc" -f sha="$csha" -f branch="$BR" >/dev/null
  done
  url=$(gh api "repos/$O/$R/pulls?state=open&head=$O:$BR" --jq '.[0].html_url // empty')
  if [ -z "$url" ]; then
    url=$(gh api "repos/$O/$R/pulls" -X POST -f title="ci: cut Actions burn — scope push triggers + concurrency-cancel" \
      -f head="$BR" -f base="$def" -f body="Automated by metadatastician-governance ci-health-sweep. Scopes \`push\` to the default branch (kills push+PR double-runs) and adds \`concurrency: cancel-in-progress\` to read-only PR checks. No SPDX/logic changes." --jq '.html_url')
  fi
  echo "FIXED $R/D-BURN -> $url (${#targets[@]} file(s))"
  ;;
*) echo "SKIP $R/$CLASS no-auto-remediation" ;;
esac
