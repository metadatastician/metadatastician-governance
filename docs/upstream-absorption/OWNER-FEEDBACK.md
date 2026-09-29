<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# What the maintainer has actually said

Joshua Jewell, on `JoshuaJewell/MetaManifold-WebUI`. Quoted so that nothing
in this register is guesswork, and so that no future push repeats a mistake
he has already named. Links are to his repository.

## Accepted, or close to it

| What | Where he said it | Quote |
|---|---|---|
| The statistics cluster | [PR #13](https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/13) | "the statistics cluster: `AnalysisConfig.jl`, `analysis_config.jl`, `numeric_policy.jl`, `scaling.jl`, `estimation.jl`, `exact_summaries.jl`, plus the `src/MetaManifold.jl` includes they need" |
| …is the point of the exercise | PR #13 | "Meet all six and I will review it properly, including real feedback on the statistics work, **which is the part we actually want**." |
| Typed contracts / DTOs | [PR #7](https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/7) | "I would be happy to see the typed `contracts/DTOs` and the new work under `frontend/tests/` in a future PR." |
| Frontend tests | PR #7 | (same sentence) |
| Benchmarks — in isolation | [PR #10](https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/10) | "Benchmarks are worth having, but not as a 293-file conflicting bundle. Please provide `bench/` + `frontend/bench/` only, but rebased on main." |
| Retry logic — in isolation | [PR #11](https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/11) | "Retry logic is a dozen lines of `ci.yml`. Again, please rebase on main first." |
| The 1x1 matrix fix — in isolation | [PR #8](https://github.com/JoshuaJewell/MetaManifold-WebUI/pull/8) | "The actual payload here is supposed to be the #38 status-check name, which is a two-line edit in ci.yml but the PR carries 319 new files and conflicts." |
| His own two real defects | [Issue #12](https://github.com/JoshuaJewell/MetaManifold-WebUI/issues/12) | "#38: the required status check embeds the Julia version … #30: CI installs four of six pipeline tools" — now upstream #14 and #15 |

## Refused

| What | Where | Quote |
|---|---|---|
| Genie / Stipple / StippleUI | PR #7 | "The Genie direction is rejected" |
| …and again, with the directory named | PR #13 | "delete `ui/` and the `Genie/Stipple/StippleUI` dependencies … Remove the directory and every reference to it." |
| Anything monolithic | PR #13 | "roughly 159 paths are add/add conflicts … An automated 'resolution' does not resolve anything: it folds my 89 commits into your 244 and produces a tree nobody has reviewed." |
| Editing his licence metadata | PR #13 | "Do not touch `LICENSE`, `CITATION.cff`, … Do not add a `NOTICE`, and do not add a `LICENSES/` directory. A `NOTICE` that restates how this project classifies its files is writing policy for a repository that is not yours." |
| Being credited by editing `CITATION.cff` | PR #13 | "If you want to be credited in `CITATION.cff`, ask for it explicitly in the PR description … It is not something to resolve by editing the file inside a PR." |

## What has made him unhappy

The single strongest signal is issue #12, where a hand-over note described
defects in **his** code that had in fact been introduced on **our** fork:

> "Before I can merge any of this, I have to push back on your comments,
> because they don't line up against this repository's actual history. … There
> never has been such code in this project. … `src/analysis/Execution.jl` was
> created on the fork … and the `0.01 + (hash(taxon_id) % 100) / 1000.0`
> placeholder arrived with it. … The fork introduced the stub and later
> replaced it, which is not a defect inherited from my code."

Two of the reported findings were real (#38, #30); the rest were artefacts of
comparing the fork against a stale base. **Lesson, and the reason this
register measures instead of asserting:** never describe upstream from the
fork's point of view. He also corrected two more that "can't be upstream
findings" (#32 `role="presentation"`, #37 commit-convention on merge commits)
and defended #31 as deliberate:

> "**#31** … is real behaviour but deliberate … an unannotated boxplot beats
> failing the request while the run holds the interpreter … personally, I
> would blame R, not me."

## Process requirements, restated as habits

1. **Rebase, never merge.** `behind_by: 0`, `merge_base` = current `main`,
   `mergeable: MERGEABLE`. He gave the exact self-check command.
2. **CI must run.** "A PR with no CI will not be reviewed."
3. **The description must exist.** What it does, which issues it closes, how
   to run the tests, and the Julia / R / bun versions tested against.
4. **Only the listed scope.** "Everything not on this list stays on your
   fork. If you think something else belongs here, please open an issue first
   and ask."
5. **Never let a unit carry a deletion of his current file.** That is how a
   stale base turns into a silent revert.
