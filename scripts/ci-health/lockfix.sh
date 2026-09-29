#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# B-LOCKFIX: API mirror -> parser checks -> generator -> lock-only PR.
# Usage: lockfix.sh REPO true|false [finding text]. Live requires explicit opt-in.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKERS_DIR="${LOCKFIX_CHECKERS_DIR:-$HERE/..}"
O="${OWNER:-metadatastician}" R="${1:?repo required}" DRY="${2:-true}"
DETAIL="${3:-}" BR=ci/ci-health-lockfix
fail() { echo "E-INSTRUMENT $R/B-LOCKFIX: $*" >&2; exit 2; }
[ -n "${GH_TOKEN:-}" ] || fail 'GH_TOKEN missing; no check or mutation performed'
[ "$DRY" = true ] || [ "${ENABLE_LOCKFIX_PRS:-false}" = true ] || fail 'live PRs require ENABLE_LOCKFIX_PRS=true'
for d in ${CI_HEALTH_DENYLIST:-}; do [ "$d" != "$R" ] || { echo "SKIP $R denylisted"; exit 0; }; done
meta=$(gh api "repos/$O/$R" --jq '[.fork,.archived,.default_branch] | @tsv') || fail 'metadata API failed'
IFS=$'\t' read -r fork archived def <<<"$meta"
[ "$fork/$archived" = false/false ] || { echo "SKIP $R fork/archived"; exit 0; }
[ -n "$def" ] || fail 'default branch missing'
tmp=$(mktemp -d) || fail 'mktemp failed'
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.github/workflows" "$tmp/before"
git -C "$tmp" init -q || fail "temporary git init failed"
git -C "$tmp" remote add origin "https://github.com/$O/$R.git" || fail "temporary origin failed"
paths=$(gh api --paginate "repos/$O/$R/git/trees/$def?recursive=1" --jq '.tree[]? | select(.type=="blob" and ((.path | test("^\\.github/workflows/.*\\.ya?ml$")) or .path==".github/workflows/actions.lock")) | .path') || fail 'tree API failed'
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in .github/workflows/*) ;; *) fail 'unsafe tree path';; esac
  data=$(gh api "repos/$O/$R/contents/$path?ref=$def" --jq '.content') || fail "content API failed: $path"
  printf '%s' "$data" | base64 -d >"$tmp/$path" || fail "invalid content: $path"
done <<<"$paths"
lock="$tmp/.github/workflows/actions.lock"
[ -f "$lock" ] || { echo "REPORT $R/B-LOCKFIX no lockfile (not in enforcement cohort)"; exit 0; }
# Never interpret a failed check as a clean result.
set +e
sync=$("$CHECKERS_DIR/check-lock-sync.sh" "$tmp" 2>&1); sync_rc=$?
pins=$("$CHECKERS_DIR/check-lock-pins.sh" "$tmp" 2>&1); pins_rc=$?
set -e
[ "$sync_rc" -ne 2 ] && [ "$pins_rc" -ne 2 ] || fail "parser/check failure: $sync $pins"
[ "$pins_rc" -eq 0 ] || { echo "REPORT $R/B-BADPIN dead pin; no regeneration: $pins"; exit 0; }
[ "$sync_rc" -eq 1 ] || { echo "SKIP $R/B-LOCKFIX clean; no PR"; exit 0; }
cp -a "$tmp/.github/workflows/." "$tmp/before/"
git -C "$tmp" add .github/workflows && git -C "$tmp" -c user.name=ci-health -c user.email=ci-health@users.noreply.github.com commit -qm 'Mirror API workflow snapshot' || fail 'temporary baseline commit failed'
command -v gh >/dev/null || fail 'gh unavailable'
# gh actions-lock operates on the mirrored root only; never on another checkout.
(cd "$tmp" && gh actions-lock --no-migrate-local-actions) || fail 'generator unavailable or failed'
yaml_restored=false
# Diff every workflow YAML byte-for-byte; a changed YAML is a standards#981
# judgement call, never an automated commit. Compare names as well as contents.
if ! diff -qr --exclude=actions.lock "$tmp/before" "$tmp/.github/workflows" >/dev/null; then
  # The generator touched workflow YAML (measured in burble#224: duplicate
  # management banners appended; bare SHAs de-pinned back to tags). Do not
  # abort: a lock-only repair still exists iff the ORIGINAL, untouched
  # workflow YAML and the newly generated actions.lock agree — the scratch-
  # copy discipline CI-CD-COVERAGE.adoc prescribes under its re-arm trigger.
  # Restore every mirrored workflow file byte-for-byte, keep ONLY the
  # regenerated lock, and let the parser-first gates decide.
  for f in "$tmp/before"/*.yml "$tmp/before"/*.yaml; do
    [ -f "$f" ] || continue
    cp -f -- "$f" "$tmp/.github/workflows/$(basename "$f")" || fail 'workflow YAML restore failed'
  done
  # A restore cannot repair a file the generator ADDED or DELETED: that is a
  # real rewrite, still a standards#981 report with no PR.
  if ! diff -qr --exclude=actions.lock "$tmp/before" "$tmp/.github/workflows" >/dev/null; then
    echo "REPORT $R/B-LOCKFIX standards#981: generator added or removed workflow files; NO PR"
    diff -ru --exclude=actions.lock "$tmp/before" "$tmp/.github/workflows" || true
    exit 0
  fi
  [ -f "$lock" ] || fail 'generator removed lockfile'
  # The decisive question: does the ORIGINAL workflow YAML pass the lock-sync
  # gate against the newly generated lock? If yes, the YAML change was noise
  # (banners, comment churn) and a safe lock-only repair exists. If no — the
  # canonical example: the generator de-pinned a SHA and keyed the lock entry
  # on the tag, so the untouched YAML's refs are not in the lock — then only a
  # YAML rewrite could close the gap, and that stays a human decision.
  set +e
  verified=$("$CHECKERS_DIR/check-lock-sync.sh" "$tmp" 2>&1); verified_rc=$?
  pinout=$("$CHECKERS_DIR/check-lock-pins.sh" "$tmp" --offline 2>&1); pin_rc=$?
  set -e
  # Never interpret a failed check as a clean result (exit 2 = NO CHECK).
  [ "$verified_rc" -ne 2 ] && [ "$pin_rc" -ne 2 ] || fail "parser/check failure after YAML restore: $verified $pinout"
  if [ "$verified_rc" -ne 0 ] || [ "$pin_rc" -ne 0 ]; then
    echo "REPORT $R/B-LOCKFIX standards#981: generator requires workflow YAML rewrite; NO PR"
    printf '%s\n' "$verified" "$pinout"
    exit 0
  fi
  yaml_restored=true
  echo "NOTE $R/B-LOCKFIX generator touched workflow YAML; original YAML restored, new lock verifies against it" >&2
fi
[ -f "$lock" ] || fail 'generator removed lockfile'
# Parser-first verification of generated lock; new unlisted workflows are notes.
if ! verified=$("$CHECKERS_DIR/check-lock-sync.sh" "$tmp" 2>&1); then
  fail "generated lock did not pass lock-sync: $verified"
fi
if cmp -s "$tmp/before/actions.lock" "$lock"; then
  echo "REPORT $R/B-LOCKFIX generator produced no lock change; inspect manually: $sync"
  exit 0
fi
if [ "$yaml_restored" = true ]; then
  echo "PROPOSED $R/B-LOCKFIX lock-only diff (workflow YAML restored unchanged):"
else
  echo "PROPOSED $R/B-LOCKFIX lock-only diff (workflow YAML unchanged):"
fi
diff -u "$tmp/before/actions.lock" "$lock" || true
if [ "$DRY" = true ]; then echo "DRYRUN $R/B-LOCKFIX no branch or PR"; exit 0; fi
sha=$(gh api "repos/$O/$R/git/ref/heads/$def" --jq '.object.sha') || fail 'default ref lookup failed'
# One stable branch per repo. Do not overwrite a branch based on an older base:
# human changes on the branch must be reviewed, never clobbered.
if gh api "repos/$O/$R/branches/$BR" >/dev/null 2>&1; then
  branch_sha=$(gh api "repos/$O/$R/git/ref/heads/$BR" --jq '.object.sha') || fail 'repair branch lookup failed'
  existing=$(gh api "repos/$O/$R/pulls?state=open&head=$O:$BR" --jq '.[0].html_url // empty') || fail 'PR lookup failed'
  if [ -n "$existing" ]; then echo "REUSE $R/B-LOCKFIX $existing"; exit 0; fi
  [ "$branch_sha" = "$sha" ] || fail 'existing repair branch differs from default; manual review required'
else
  gh api -X POST "repos/$O/$R/git/refs" -f ref="refs/heads/$BR" -f sha="$sha" >/dev/null || fail 'branch creation failed'
fi
cur=$(gh api "repos/$O/$R/contents/.github/workflows/actions.lock?ref=$BR") || fail 'branch lock lookup failed'
cur_sha=$(jq -r '.sha' <<<"$cur")
# Do not apply a proposal prepared against a changed base.
[ "$(jq -r '.content' <<<"$cur" | base64 -d | sha256sum | cut -d' ' -f1)" = "$(sha256sum "$tmp/before/actions.lock" | cut -d' ' -f1)" ] || fail 'branch lock differs from mirrored default'
encoded=$(base64 -w0 <"$lock")
gh api -X PUT "repos/$O/$R/contents/.github/workflows/actions.lock" -f message='ci: synchronize stale actions lock (workflow YAML unchanged)' -f content="$encoded" -f sha="$cur_sha" -f branch="$BR" >/dev/null || fail 'lock upload failed'
body=$(printf 'Automated B-LOCKFIX from metadatastician-governance. Only actions.lock changed; workflow YAML is byte-for-byte unchanged.\n\nExact drifted refs and failed run ids from detection:\n%s\n\nChecker output:\n%s\n\nReview the regenerated lock before merging. Dead pins and YAML-changing regeneration are excluded.\n' "$DETAIL" "$sync")
url=$(gh api "repos/$O/$R/pulls" -X POST -f title='ci: reconcile stale workflow lock refs' -f head="$BR" -f base="$def" -f body="$body" --jq '.html_url') || fail 'PR creation failed'
echo "FIXED $R/B-LOCKFIX -> $url"
