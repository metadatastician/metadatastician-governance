#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Fail-closed sweeps must retain actionable detector errors in their logs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/usr/bin/env bash
set -e
case "$*" in
  'api users/metadatastician') echo '{"login":"metadatastician"}';;
  'repo list metadatastician --source --no-archived --limit 1000 --json name') echo '[]';;
  'api orgs/metadatastician/actions/permissions --jq .allowed_actions // empty')
    echo 'HTTP 403: Resource not accessible by integration' >&2
    exit 1
    ;;
  'variable get CI_HEALTH_POLICY_EPOCH --org metadatastician') exit 1;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1;;
esac
SH
chmod +x "$T/bin/gh"
set +e
output=$(PATH="$T/bin:$PATH" GH_TOKEN=fixture OWNER=metadatastician \
  "$ROOT/scripts/ci-health/sweep.sh" 2>&1)
status=$?
set -e
[ "$status" = 2 ] || { echo "expected exit 2, got $status: $output"; exit 1; }
[[ "$output" == *'Detection was incomplete for 1 repo(s)'* ]] || { echo "missing incomplete-scan summary: $output"; exit 1; }
[[ "$output" == *'@organization (CRITICAL): Actions-permissions query failed'* ]] || { echo "missing detector detail: $output"; exit 1; }
[[ "$output" == *'classic repo, workflow, and admin:org scopes'* ]] || { echo "missing token-scope guidance: $output"; exit 1; }
echo 'ok incomplete sweep reports detector scope, cause, and token guidance'
