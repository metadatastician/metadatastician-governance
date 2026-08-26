#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# fix-pages-deadlock.sh — strip the unsatisfiable `required_deployments`
# ["github-pages"] rule from repository rulesets.
#
# THE DEADLOCK (measured 2026-08-26, metadatastician: 36 rulesets / ~34 repos)
#   Rulesets carry:
#       required_deployments: {"required_deployment_environments":["github-pages"]}
#   but `pages.yml` triggers on `push: [main]` + `workflow_dispatch` and NEVER
#   on `pull_request`. Measured deployment refs:
#       gossamer/burble/stapeln -> only `main`;  paint-type -> none at all.
#   So a PR head SHA can never carry a github-pages deployment and the rule can
#   never be satisfied on a PR.
#
# WHY IT MATTERS MORE THAN IT LOOKS
#   The only way to merge is then admin bypass — and bypass ignores EVERY OTHER
#   RULE in the same ruleset. One impossible rule silently disables the required
#   reviews, status checks and linear-history rules sitting beside it. A gate
#   nobody can pass is an off switch for the whole set, not a strict gate.
#
# WHAT THIS DOES
#   Removes ONLY the `required_deployments` rule. name, target, enforcement,
#   conditions and bypass_actors are round-tripped from the live ruleset
#   unchanged. Repos/rulesets without the rule are skipped, so it is idempotent.
#
# Usage:
#   ./fix-pages-deadlock.sh <owner> [dry_run:true|false]     # default: true
#
# Requires: gh with admin rights on the org, python3.
set -euo pipefail

OWNER="${1:?usage: fix-pages-deadlock.sh <owner> [dry_run]}"
DRY_RUN="${2:-true}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
changed=0; skipped=0

for repo in $(gh repo list "$OWNER" --limit 200 --json name,isArchived,isFork \
                -q '.[] | select(.isArchived==false and .isFork==false) | .name'); do
  for id in $(gh api "repos/$OWNER/$repo/rulesets" \
                --jq '.[]? | select(.source_type=="Repository") | .id' 2>/dev/null); do
    gh api "repos/$OWNER/$repo/rulesets/$id" > "$TMP/rs.json" 2>/dev/null || continue

    if ! python3 - "$TMP/rs.json" "$TMP/body.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
rules = d.get('rules', [])
if not any(r.get('type') == 'required_deployments' for r in rules):
    sys.exit(1)                      # nothing to do — signal skip
json.dump({
    'name': d['name'],
    'target': d['target'],
    'enforcement': d['enforcement'],
    'conditions': d.get('conditions', {}),
    'bypass_actors': d.get('bypass_actors', []),
    'rules': [r for r in rules if r.get('type') != 'required_deployments'],
}, open(dst, 'w'))
PY
    then skipped=$((skipped + 1)); continue
    fi

    name=$(python3 -c "import json;print(json.load(open('$TMP/rs.json'))['name'])")
    if [ "$DRY_RUN" = "true" ]; then
      echo "DRYRUN  $repo/$name — would strip required_deployments[github-pages]"
    else
      if gh api -X PUT "repos/$OWNER/$repo/rulesets/$id" --input "$TMP/body.json" >/dev/null 2>&1; then
        echo "FIXED   $repo/$name"
      else
        echo "FAILED  $repo/$name (check admin rights)"; continue
      fi
    fi
    changed=$((changed + 1))
  done
done

echo
echo "rulesets with the rule: $changed   rulesets already clean: $skipped"
if [ "$DRY_RUN" = "true" ]; then
  echo "dry run — re-run with 'false' as the second argument to apply."
fi
exit 0
