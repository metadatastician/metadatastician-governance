# Ready-to-post issue for hyperpolymath/standards

**Title:** Expose parser-first lock drift check and guarded lock repair via workflow_call

The metadatastician estate's CI-health sweep now mirrors each repo's workflows
and lock via API, checks them through parser-first lock-sync/pin gates, and
proposes a generated lock-only PR. `standards` already has
`lockfile-drift-detect.yml` for the hyperpolymath estate, but ~30 consuming
repositories should inherit one callable implementation, not copy 30 gates.

Please expose `workflow_call` entry points in standards for (1) a read-only
parser-first drift check and (2) an explicitly opt-in repair with a lock-only PR.
Requirements: Y-1 (YAML values only via the shared parser; no regex over YAML),
no KYAML conversion before #1021/#1023, exit 0 clean / 1 finding / 2 no check,
report exact refs and affected startup run IDs, no cross-repo mutation on default,
reject every generator diff touching workflow YAML (see #981), do not re-point
dead pins, do not attempt to repair actor refusals, cap PR count, dedupe branch
and PR, and publish proposed diffs as artifacts/summary. Test the silence,
firing, and exit-2 fixtures before rollout. Pin the tool version and document
required token permissions. Please keep uses-free gates uses-free; add a
separate caller rather than embedding a reusable call in those gates.

The authoring installation has no write access to standards, so this is a
request rather than a branch or push there.
