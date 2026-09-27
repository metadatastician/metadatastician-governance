#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# yaml.sh — resolve YAML with a real parser, then hand canonical JSON to jq.
#
# WHY THIS FILE EXISTS (upstream rule Y-1, `hyperpolymath/standards`
# 3-practice/YAML-POLICY.adoc, ruled 2026-09-22, IN FORCE):
#
#   "Any gate, check script, audit or census that needs a value out of a YAML
#    file MUST obtain it with `yq`. Reading YAML with `grep`, `sed`, `awk` or a
#    regex is forbidden in gate code."
#
# The rule is not hygiene. The estate's actions-lockfile failure class was
# *caused* by a line-oriented reader giving a confident, well-formed answer
# about a structure it could not see: `gh actions-lock`'s extractor saw
# step-level `uses:` only, so it classified every job-level reusable-workflow
# ref as an orphan pin. The same shape of defect — reading `.github/workflows/
# actions.lock` as text — is what this repository's first lock gates did.
#
# DESIGN
#   yaml_to_json <file>   resolves the document to canonical JSON on stdout.
#   Every call site then uses `jq`. One expression language, one code path.
#
# The parser is chosen in Y-1's order — `yq` first — and falls back only to
# other *real parsers*, following the precedent set by the estate's own
# `standards/tools/policy/check-workflows-parse.sh`, which falls back to ruby.
# There is no text-reading fallback, and there never will be: a text fallback
# would reproduce exactly the defect Y-1 exists to prevent.
#
# FAIL-CLOSED CONTRACT
#   No parser, or an unparseable document, returns 2 and prints a reason to
#   stderr. Callers MUST propagate 2 as "NO CHECK WAS PERFORMED" — never as a
#   pass and never as a finding. Reading a document that did not load as
#   "contains nothing" is the false pass this whole design exists to stop.
#
# Override for tests: YAML_PARSER_KIND=yq-mikefarah|yq-jqwrapper|ruby|python|none
#                    YAML_TOOLS_DIR=<dir>   # prepended to PATH for tool lookup

# yaml_parser_kind — name the parser that will be used, or "none".
yaml_parser_kind() {
  if [ -n "${YAML_PARSER_KIND:-}" ]; then
    printf '%s\n' "$YAML_PARSER_KIND"
    return 0
  fi

  if command -v yq >/dev/null 2>&1; then
    # mikefarah/yq and kislyuk/yq are different programs that share a name and
    # take different flags. Distinguish them rather than guess: guessing wrong
    # here turns into "no output" and a silent pass.
    if yq --version 2>&1 | grep -qi 'mikefarah'; then
      printf 'yq-mikefarah\n'
    else
      printf 'yq-jqwrapper\n'
    fi
    return 0
  fi

  if command -v ruby >/dev/null 2>&1; then
    printf 'ruby\n'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    printf 'python\n'
    return 0
  fi

  printf 'none\n'
}

# yaml_to_json <file> — canonical JSON on stdout.
# 0 = resolved; 2 = NO CHECK POSSIBLE (no parser, unreadable, or unparseable).
yaml_to_json() {
  local file="$1"
  local kind
  kind="$(yaml_parser_kind)"

  if [ ! -f "$file" ]; then
    printf 'yaml: no such file: %s\n' "$file" >&2
    return 2
  fi

  case "$kind" in
    yq-mikefarah)
      yq -o=json '.' "$file" 2>/dev/null || {
        printf 'yaml: %s did not parse as YAML (mikefarah yq)\n' "$file" >&2
        return 2
      }
      ;;
    yq-jqwrapper)
      yq -j '.' "$file" 2>/dev/null || {
        printf 'yaml: %s did not parse as YAML (jq-wrapper yq)\n' "$file" >&2
        return 2
      }
      ;;
    ruby)
      ruby -ryaml -rjson -e '
        doc = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        puts JSON.generate(doc)
      ' "$file" 2>/dev/null || {
        printf 'yaml: %s did not parse as YAML (ruby/psych)\n' "$file" >&2
        return 2
      }
      ;;
    python)
      python3 -c '
import json, sys, yaml
json.dump(yaml.safe_load(open(sys.argv[1], encoding="utf-8")), sys.stdout)
' "$file" 2>/dev/null || {
        printf 'yaml: %s did not parse as YAML (python/pyyaml)\n' "$file" >&2
        return 2
      }
      ;;
    none | *)
      printf 'yaml: NO YAML PARSER AVAILABLE (tried yq, ruby, python3+pyyaml).\n' >&2
      printf 'yaml: upstream rule Y-1 forbids a grep/sed/awk fallback for YAML,\n' >&2
      printf 'yaml: so this is exit 2 — NO CHECK WAS PERFORMED — not a pass.\n' >&2
      return 2
      ;;
  esac
}

# jq_read <json> <jq-filter> [args...] — jq that reports "no jq" as exit 2.
jq_read() {
  local json="$1"
  shift
  if ! command -v jq >/dev/null 2>&1; then
    printf 'yaml: jq is required to read parser output\n' >&2
    return 2
  fi
  printf '%s' "$json" | jq "$@"
}

# yaml_uses_in <file> — every external action ref a workflow requests, one per
# line, normalised to OWNER/REPO@REF (sub-paths stripped, so
# `github/codeql-action/init@v1` and `github/codeql-action@v1` agree).
# Local refs (`./…`, `$/…`) and container refs (`docker://…`) are not lockable
# workflow dependencies and are dropped.
# 0 = listed (possibly empty); 2 = NO CHECK POSSIBLE.
yaml_uses_in() {
  local file="$1" json
  json="$(yaml_to_json "$file")" || return 2
  jq_read "$json" -r '
    [ .. | objects | select(has("uses")) | .uses ]
    | map(select(type == "string"))
    | map(select(contains("@")))
    | map(select((startswith("./") or startswith("$/") or startswith("docker://")) | not))
    | map(sub("^(?<slug>[^/]+/[^/@]+)(/[^@]*)?@"; "\(.slug)@"))
    | unique
    | .[]
  '
}

# yaml_lock_get <lockfile> <jq-filter> [args...] — read the lockfile by parser.
yaml_lock_get() {
  local lock="$1"
  shift
  local json
  json="$(yaml_to_json "$lock")" || return 2
  jq_read "$json" "$@"
}
