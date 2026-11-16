== CONTRIBUTING.md:106-116
The reason is measured cost: the October 2026 usage report attributes 10,206 Linux minutes and 309 macOS minutes to that workflow, 83% of the account's 12,735 hosted minutes.
The local no-mistakes gate replaces the Linux suite: `commands.test` runs the coverage guard and the three portable lanes through `bin/fm-test-run.sh`, and the portable serial lane includes `tests/fm-repo-invariants.test.sh`.
Every lane excludes the live-harness-optin and hc-pinned families and runs under `FM_LIVE=0`, so a gate round never drives a live Herdr session, downloads release binaries, or uses a real hc binary.
The hermetic `tests/fm-backend-hc.test.sh` stays in the portable serial lane.
Deleting the workflow also removed the only automation for the real-Herdr and pinned-hc lanes: they are manual/pre-merge lanes now, run before merging a Herdr or hc change with `--family real-herdr-gated --fail-on-gate-skip herdr` and `--family hc-pinned --fail-on-gate-skip 'hc not found'` against the pinned build, and they are no longer automated on every pull request.
The full portable walk takes roughly 3.5-4 hours; the operator raised the gate host's global no-mistakes `test_agent_timeout` to 5h on 2026-11-16, and [fm-test-portable-shards.md](docs/fm-test-portable-shards.md#gate-execution-bounds) owns that bound.
Stock macOS Bash coverage is kept, not dropped: `.github/workflows/macos-bash.yml` runs its single stock Bash job only on a pull request that touches `bin/**`, `tests/**`, or `.github/workflows/**`, and on demand through `workflow_dispatch`.
No hosted job runs on a push to `main`.
CI prose elsewhere in this repository describes the public template rather than this fork, and this fork's externally configured ruleset still names checks the deleted workflow produced, so prune those names before relying on required checks.

## Development

== .no-mistakes.yaml:36-52
#
# The local no-mistakes gate owns broad deterministic regression. The coverage guard
# plus the three portable lanes below, composed by their single owner
# `bin/fm-test-run.sh`, cover the whole deterministic portable suite, including
# `tests/fm-repo-invariants.test.sh` and the hermetic `tests/fm-backend-hc.test.sh`.
# The real-Herdr family, the pinned hc family, and the live-harness opt-in family
# deliberately stay out: every lane excludes live-harness-optin and hc-pinned, and
# FM_LIVE=0 stops any remaining default-on fm_live_gate guard, so a gate round never
# drives a live Herdr session, uses a real hc binary, or downloads release binaries,
# and `--all` is never selected. This fork runs no hosted Linux suite;
# `.github/workflows/macos-bash.yml` keeps only the path-filtered stock macOS Bash
# check, and CONTRIBUTING.md "Fork divergence: no hosted Linux suite" owns the reason
# and the sync rule.
#
# The full portable walk takes roughly 3.5-4 hours. The operator raised the host's
# global no-mistakes `test_agent_timeout` to 5h on 2026-11-16; no-mistakes reads
# that key only from its global config, so a copy in this file is ignored.

== .agents/skills/firstmate-coding-guidelines/SKILL.md:117-128
The local no-mistakes gate owns broad deterministic regression through `commands.test`.
In this fork that command runs `bin/fm-test-run.sh --check-coverage` and the three portable lanes with `--exclude-family live-harness-optin --exclude-family hc-pinned` under `FM_LIVE=0`, and the portable serial lane includes `tests/fm-repo-invariants.test.sh` and the hermetic `tests/fm-backend-hc.test.sh`.
Never add `--all` or the real-Herdr family to that command: `--all` selects the live-Herdr family, and the family exclusions plus `FM_LIVE=0` keep every live Herdr session, release download, and hc binary out of the gate.
Targeted validation beyond that suite belongs to the no-mistakes evidence path; add a scenario only when no deterministic test reaches the behavior.
Firstmate PR #3644 demonstrated why an ad hoc script walk is not the alternative: pinning a 75-162-script walk took 32.7 minutes per validation, while the lane composition keeps broad regression bounded and reproducible.
Stock macOS Bash compatibility stays out of the gate and remains covered by the single path-filtered `.github/workflows/macos-bash.yml` workflow.
Other repositories keep their own suite-ownership policy rather than inheriting this fork's command.

## Repo style rules

- Put one full sentence per line in tracked Markdown.
- Never wrap multiple sentences onto one physical line.
