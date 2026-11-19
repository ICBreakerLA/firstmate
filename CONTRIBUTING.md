# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and requires both the deterministic signature and a parseable structured attestation from no-mistakes v1.46.0 or newer.
The attestation must bind to the current PR head commit and report the review, test, and document steps as completed, so a stale attestation, a missing `head_sha`, or a skipped required step fails.
It evaluates every PR opening and body edit independently, reruns after head synchronization or reopening, and prevents a later edit from replacing an earlier pending compliance check.
GitHub Actions and Dependabot are exempt so their automation keeps working, but other contributor PRs that do not satisfy the attestation contract will not be reviewed or merged.

## Workflow

1. Fork the repo, then clone the parent repo or set your local `origin` back to the parent (`git@github.com:kunchenguid/firstmate.git`).
2. Create a branch and make your changes.
3. Initialize the gate with your fork as the push target: `no-mistakes init --fork-url git@github.com:<you>/firstmate.git` (contributing to firstmate requires **no-mistakes v1.46.0+** for structured attestation; without a fork, plain `no-mistakes init` still works for maintainers with push access).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push no-mistakes
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch to your fork and opens the PR against the parent repo for you.

### The `full-ci` label

This section describes the upstream template's hosted Linux workflow, which this fork does not run; see [Fork divergence: no hosted Linux suite](#fork-divergence-no-hosted-linux-suite).

CI on a pull request from an author without write access runs only the quick checks at first: `Test coverage guard`, `Repo invariants`, and the no-mistakes body check.
Lint and the behavior suites wait for a maintainer, or the maintainer's fleet, to add the `full-ci` label when the pull request is picked up for review.
Until then the `Full suite` check fails with a message naming the label; that is expected and needs no action from you.
Adding the label runs the full suite, and every later push to that pull request runs it again.
This keeps the repository's public CI within GitHub's limit on jobs running at once, while no-mistakes already reviews, tests, and lints your change locally.
Pull requests from this repository's own branches or from authors with write access run the full suite without the label.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Agent-driven contributions

Before dispatching an agent-driven contribution, follow the [Firstmate role and task-consent policy](docs/configuration.md#firstmate-role-configfirstmate-role); clone-and-run use alone grants no publication authority.

## Maintaining required checks

This section describes the public template's hosted checks; this fork no longer produces most of those contexts, so prune the retired names from its ruleset before relying on required checks (see [Fork divergence: no hosted Linux suite](#fork-divergence-no-hosted-linux-suite)).

GitHub required checks are configured in the repository's existing main ruleset, not activated by committing workflow YAML.
When applying this CI layout, preserve its existing pull-request, merge-method, linear-history, deletion, non-fast-forward, and administrator-bypass settings.
Add required status checks with `strict_required_status_checks_policy: false`; a main update alone must not force a branch update and retest.
Bind the checks to the GitHub Actions app already producing them, rather than accepting the same context from any integration.
No new app installation or manual runner setup is needed for that setting.

Require the actual job contexts: `Full suite`, `Lint 1` through `Lint 8`, `Test coverage guard`, `Repo invariants`, `Stock macOS Bash snapshot compatibility`, `Behavior portable parallel 1`, `Behavior portable parallel 2`, `Behavior portable serial 1` through `Behavior portable serial 12`, `Behavior tests (Herdr)`, `Behavior timing aggregate`, and `PR must be raised via no-mistakes`.
The last name is the compliance job context, not its workflow title; its existing automation exceptions remain unchanged.
The timing aggregate is not a substitute for individual jobs because it can succeed while collecting evidence from a failed run.
The individual lanes skip on an outside pull request until it has the `full-ci` label, and a skipped job satisfies a required check, so `Full suite` must be required too: it fails until the label is on and whenever a lane failed or was cancelled.

Apply the approved rule change only after the corresponding workflow is green and landed, confirming exact names and the Actions integration id from real checks first.
Snapshot the current ruleset, amend that same rule with the authenticated GitHub API or settings UI, and read back both the ruleset and effective branch rules.
Verify missing or red checks prevent ordinary merging without creating a test merge; administrator override intentionally remains available.
Coordinate any workflow rollback with its required-check names so a retired check cannot leave ordinary merges waiting forever.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  [`AGENTS.md`](AGENTS.md) owns the supervisor contract, role boundary, and bundled firstmate skill triggers; `CLAUDE.md` is a real `@AGENTS.md` pointer to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  `.claude/mods/` holds Claude Code mods, plugins whose behavior lives in one function-hooks module; each is reached through an `.agents/skills/<mod>` symlink because Claude Code adopts project plugins only from `.claude/skills`, carries no `SKILL.md` so every other harness's skill loader ignores that entry, and imports only files physically inside its own folder because Claude Code refuses anything else.
  A module may load through `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` or Claude Code's `tengu_plugin_hooks_modules` rollout flag, but the Calm mod activates only when `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` is exactly `1` and is otherwise a complete no-op; Firstmate never sets that variable in any settings file, and [`docs/calm.md`](docs/calm.md) owns the contract.
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces firstmate's routine backlog updates to hand-editing and stays gitignored; validated secondmate handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file stays gitignored; [runtime backend configuration](docs/configuration.md#runtime-backend-configbackend--fm_backend) owns supported values, selection, and limits.
  It does not make `data/` tracked.
- Shell helpers in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `bin/fm-lint.sh` must pass: it is the single owner of the lint definition (the shellcheck file set, config, pinned shellcheck version, pinned actionlint workflow lint, and the backend-purity check rejecting direct Beads CLI calls in core `bin/` scripts).
  The local no-mistakes gate uses its context-selected default; the full canonical partitions belonged to the deleted hosted workflow.
  `docs/fm-test-portable-shards.md` owns partition verification and performance evidence.
  Its header and `--help` output own the exact local lint modes, file-set selection, and analysis flags.
  Local runs take a host-wide slot (one at a time by default, shared by every checkout) so concurrent lint runs cannot exhaust memory; the header owns `FM_LINT_HOST_SLOTS` and its siblings.
  A malformed `.github/workflows/*.yml` fails that local lint path before merge.
  It pins one exact shellcheck version and one exact actionlint version and refuses to run under any other.
  Print the shellcheck pin with `bin/fm-lint.sh --required-version` and the actionlint pin with `bin/fm-lint-workflows.sh --required-version`.
  Use `bin/fm-install-shellcheck.sh` and `bin/fm-install-actionlint.sh` to install those exact builds locally; each installer's header owns its destination usage and supported platforms.
- Harness-adapter ownership spans detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, spawn-time Claude workspace-trust and external-CLAUDE.md-import pre-approval in `bin/fm-claude-trust.sh`, semantic busy sources and trust gates in `bin/fm-busy-lib.sh`, delivery-only rendered guards in `bin/fm-composer-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in the skill tree rooted at `.agents/skills/harness-adapters/SKILL.md`; the `firstmate-coding-guidelines` skill owns the validation policy for checks that depend on those harnesses.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) keep current setup and limits in the relevant backend guide and active empirical evidence in [`docs/verification/runtime-backends.md`](docs/verification/runtime-backends.md).
- [`docs/documentation-audiences.md`](docs/documentation-audiences.md) and its machine-consumed inventory own prose classification; run `bin/fm-doc-audience-check.sh` after documentation changes.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Fork divergence: no hosted Linux suite

This fork's `main` deliberately deletes `.github/workflows/ci.yml` while the public template keeps it.
An upstream template sync reintroduces that file, and the sync worker deletes it again on the same branch and keeps `commands.test` in `.no-mistakes.yaml`.
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

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
Firstmate adds this skill's load line to firstmate-repo briefs by hand; the [coding-guidelines skill](.agents/skills/firstmate-coding-guidelines/SKILL.md#trigger-hygiene) owns the scaffold's detection limits.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: crewmates route every `ask-user` finding to firstmate, which applies `ask-user-authority`, and crewmates never pass `--yes` or `-y` because either flag bypasses that check and any required captain escalation.
[`docs/configuration.md`](docs/configuration.md#gate-defaults-no-mistakesyaml) owns the tracked `.no-mistakes.yaml` gate defaults.
The `firstmate-coding-guidelines` skill owns the rule that the local no-mistakes gate runs broad deterministic regression through `commands.test`, while extra scenarios stay targeted.
Verify the same way the gate does: reach for `bin/fm-test-run.sh` with the subjects you care about rather than chaining `bash tests/a.test.sh && bash tests/b.test.sh`, because a list of script paths gets the same bounded concurrency as `--changed`.
The pipeline publishes that evidence itself, so never hand-commit `.no-mistakes/` paths onto a feature branch; the local gate's repo invariants test rejects them as tracked personal fleet paths.

Check and test the toolbelt before pushing:

```sh
while IFS= read -r script; do /bin/bash -n "$script" || exit; done < <(bin/fm-lint.sh --list-files)   # syntax-check the shell surface fm-lint.sh will cover (changed files locally, full set on main)
bin/fm-lint.sh   # lint that shell surface plus GitHub workflows via pinned actionlint; the single owner the no-mistakes gate runs
bin/fm-test-run.sh tests/<subject>.test.sh   # one script (primary local focus path, timed)
bin/fm-test-run.sh tests/<a>.test.sh tests/<b>.test.sh   # several subjects at once: bounded automatic concurrency
bin/fm-test-run.sh --family pure-contract-unit   # ordinary family-scoped local path (serial, timed)
bin/fm-test-run.sh --changed   # normal changed-file-informed path with automatic bounded concurrency
bin/fm-test-run.sh --changed --jobs 1   # explicit serial override
bin/fm-test-run.sh --changed --max-wall-ms 300000   # same automatic path with a post-run five-minute result check
bin/fm-test-run.sh --proven-isolated --jobs 4   # explicit local parallel of the individually proven set
bin/fm-test-run.sh --lane portable-serial   # portable serial remainder (watcher/AFK/tmux/stateful)
bin/fm-test-run.sh --list-lanes   # discover exact lane names, including the current serial shards
bin/fm-test-run.sh --check-coverage   # prove the portable lanes, the serial shards, and the Herdr lane equal the full inventory
bin/fm-test-run.sh --all   # deliberate complete regression (optional local full walk; not no-mistakes Test)
bin/fm-test-linux.sh   # opt-in: run the tests changed on this branch in a Debian container with GNU userland (needs docker or podman)
bin/fm-test-isolation-proof.sh --list   # proven portable parallel candidate set
bin/fm-test-isolation-proof.sh --jobs 4 --json /tmp/fm-isolation-proof.json   # re-run the portable candidate proof
bin/fm-test-isolation-proof.sh --pool watcher-wake-lock --jobs 4   # re-run an admitted family proof
[ ! -L CLAUDE.md ] && cmp -s CLAUDE.md - <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

`bin/fm-test-run.sh` is the single owner of behavior-suite selection, portable lane composition, bounded concurrency admission, per-script timing markers, family totals, the coverage guard, and the optional JSON timing artifact.
Its header and `--help` own the flags, family labels, lanes, and changed-file map; this section only documents the entry points.
`bin/fm-test-isolation-proof.sh` remains the single owner of the portable candidate proof and reusable family proof harness; see `docs/fm-test-isolation-proof.md`.
Portable shard balance evidence lives in `docs/fm-test-portable-shards.md`.
`bin/fm-test-linux.sh` is optional and never part of the gate: on macOS, run it before publishing a branch whose tests depend on `stat`, `date`, or process behavior, because BSD and GNU tools differ.
Its header owns selection, runtime detection, and exit codes.
Family selection is the ordinary local path; `--all` is deliberate full regression only.
The local no-mistakes gate owns broad deterministic regression: `commands.test` runs the coverage guard and the three portable lanes (both parallel lanes and the portable serial remainder, which includes `tests/fm-repo-invariants.test.sh`) through `bin/fm-test-run.sh`.
The gate excludes the real-Herdr, hc-pinned, and live-harness opt-in families and sets `FM_LIVE=0`, so a gate round never drives a live Herdr session or the real fleet; run those lanes directly when a change needs them, as [fm-test-portable-shards.md](docs/fm-test-portable-shards.md#manual-backend-and-live-lanes) describes.
This fork runs no hosted Linux suite, and [Fork divergence: no hosted Linux suite](#fork-divergence-no-hosted-linux-suite) owns the reason and the sync rule.
Stock macOS Bash compatibility stays covered by the single path-filtered [`.github/workflows/macos-bash.yml`](.github/workflows/macos-bash.yml) workflow.
Use `bin/fm-test-run.sh --list-lanes` for exact lane names and `--help` for `--jobs` rules and required gate-skip flags when reproducing a lane locally.
Leave the `sleep 0.1` cadence in the suites' bounded condition waits alone.
Those sleeps look like recoverable overhead - the watch-triage suite (`fm-watch-triage.test.sh`, `fm-watch-triage-pause.test.sh`, and `fm-watch-triage-wedge-defer.test.sh`) issues about 1,900 of them, each paying a flat ~100ms scheduler wake-up penalty on macOS - but they are not overhead added to the clock; they are how a test waits for a subject that only moves on `fm-watch.sh`'s own one-second `FM_POLL` cadence.
Sampling less often does not remove that wait, it only delays detection: raising the interval to 0.5s and charging each sample proportionally measured the unsplit suite at 435s and 440s against 390s and 393s for the unchanged script, back to back on 2026-09-03, because each of its ~40 poll-cycle waits and ~73 process-exit waits paid up to half a second more.
Some of those loops are also catching a transient rather than waiting for a settled condition, so a coarser sample can step over the state they assert on.
Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so pass one to `bin/fm-test-run.sh` to focus on a subject with canonical timing output.
Shared test helpers live in `tests/lib.sh` (reporters, temp roots, git fixtures), `tests/fixtures.sh` (fake toolchain and spawn-world builders), `tests/wake-helpers.sh`, `tests/secondmate-helpers.sh`, `tests/supervision-host-helpers.sh` (stub-engine fixtures for the split supervision-host suites), `tests/watch-triage-helpers.sh` (shared fixtures for the split watch-triage suites), and `tests/git-config-helpers.sh` (fixture Git isolation from the host's global and system configuration and from an inherited repository location such as `GIT_DIR`, already sourced by `tests/lib.sh` and `tests/herdr-test-safety.sh`; a suite that sources neither must source it itself before its first Git operation so a direct invocation stays isolated).
Source those instead of copying a fake toolchain into a new suite.
A suite that hands a `.ts` file to `node` (directly, through a Pi/OMP extension fixture, or through `bin/fm-branch-dispatch.mjs`) opts into `tests/ts-loader-helpers.sh` with one line, `fm_test_ts_loader || exit 1` (it is defined by `tests/lib.sh`): on a node without native type stripping, such as Debian's, it installs the TypeScript compiler pinned in `tests/fixtures/ts-loader/package-lock.json` once per host and exports a `NODE_OPTIONS` import that transpiles `.ts` on load, and on a node with native type stripping it does nothing. Never reach for `--experimental-strip-types` or `--input-type=module-typescript` in a suite instead.
Resolve every host tool a fixture execs with `command -v` instead of hardcoding a `/bin` path, and pass the result to the fake-tool shim either interpolated into the shim body (`tests/fm-backlog-atomicity.test.sh`) or through an environment variable (`tests/fm-watcher-lock.test.sh`): `/bin` holds only `sh` on some supported hosts, so a shim that execs a hardcoded `/bin/ln`, `/bin/rm`, or `/bin/ps` names a path that does not exist. The same host makes a `sleep` renamed through `exec -a` dispatch on `argv[0]` and exit at once, so a holder that only needs a distinguishing name gets it as a plain argument instead; keep `exec -a` only where `argv[0]` naming is itself the subject.
A fixture may shorten a production timeout to keep a failure path prompt, but never below what the real work inside that window costs on a loaded machine: a fork, an exec, a lock acquisition, a beacon publication, or a first-poll check.
Where a case's assertion is not about the timeout itself, give that window headroom over the measured loaded cost, and bound the test's own waiting with iteration-counted poll loops, which stretch under load where a wall-clock budget does not.
Supervision host and Stop-hook hand-back waits are the exception: use `wait_until_deadline` (a 60s wall-clock budget well above the loaded hand-back cost) so a timeout dumps `host.out`, `hook.out`/`hook.err`, the supervision-host log, health file, and a process tree.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux/paseo/rex/tern/hc smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the portable suite remains safe on machines without those tools.
The complete [`tests/fm-watch-triage-pause.test.sh`](tests/fm-watch-triage-pause.test.sh) suite requires compatible `tasks-axi` on `PATH`, as specified in [Backlog backend](docs/configuration.md#backlog-backend-taskstoml--configbacklog-backend).
[`tests/rex-test-safety.sh`](tests/rex-test-safety.sh) owns the real-Rex suites' private-server isolation and capability gates.
The [Herdr backend guide](docs/herdr-backend.md#destructive-lab-safety) owns the lane's isolation boundary, while [runtime backend verification](docs/verification/runtime-backends.md#herdr) owns active empirical evidence; live harness credential tests remain opt-in.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
