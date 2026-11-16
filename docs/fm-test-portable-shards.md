# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.
This fork runs no hosted Linux suite: the local no-mistakes gate runs the same lanes (CONTRIBUTING.md "Fork divergence: no hosted Linux suite").
The measurements below were captured from upstream Ubuntu CI runs before the workflow was deleted, and they remain the packing weights the gate uses.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial lane duration.
Local timings are not interchangeable with hosted-runner timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covered all 24 parallel and 201 serial members at that refresh; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The supervision-host suite is four serial members so no one file occupies a whole serial shard: `tests/fm-supervision-host-drain.test.sh` (report, dispatch, BRANCH OUTCOMES; 17 tests, local 19978 ms, hint 45950 ms), `tests/fm-supervision-host-hook.test.sh` (Claude Stop-hook re-arm and hand-back; 24 tests, local 175562 ms, hint 403793 ms), `tests/fm-supervision-host.test.sh` (host loop wakes, closes, mirror, return; 29 tests, local 189383 ms, hint 435581 ms), and `tests/fm-supervision-host-park.test.sh` (latch, park boundary, compaction, lock ownership; 20 tests, local 143185 ms, hint 329326 ms). Packing weights are local `duration_ms` scaled by ~2.3 for CI, replacing the 1192918 ms single-file sample from run [39642852135](https://github.com/kunchenguid/firstmate/actions/runs/39642852135) that sat alone in a serial shard and still overran: run 39765114423 cancelled that script at the 30-minute job cap. Refresh these four from recorded timing artifacts on the next green run or measured refresh.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The 2026-10-07 polytoken adapter tests carry provisional local measurements instead - 21090 ms for `tests/fm-polytoken-harness.test.sh` and the 103 ms live-guard skip for `tests/fm-polytoken-signals-live-e2e.test.sh`, both measured on the adapter-verification macOS host - until a later measured refresh replaces them with Ubuntu measurements, because they postdate the 2026-09-30 baseline.
The 2026-10-23 `tests/fm-approval-failover.test.sh` serial hint is a provisional local measurement of 5410 ms, the slowest of five local `bin/fm-test-run.sh` samples (4991-5410 ms), until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-11-08 `tests/fm-capacity-auto.test.sh` (36243 ms), `tests/fm-lane-capacity-integration.test.sh` (48000 ms), and `tests/fm-lane-vitals.test.sh` (5077 ms) serial hints are provisional local measurements from one `bin/fm-test-run.sh` run on a loaded macOS host, until a later measured refresh replaces them with Ubuntu timing-artifact maxima.
The 2026-11-09 `tests/fm-stow-guard.test.sh` serial hint is a provisional local measurement of 30000 ms, above a 27436 ms `bin/fm-test-run.sh` sample on this macOS host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-23 Kimi folder-prompt live guard, `tests/fm-kimi-trust-prompt-live-e2e.test.sh`, carries a provisional 60 ms skip measured on the Linux host that recorded its captures, until a later measured refresh replaces it with an Ubuntu measurement.
The 2026-11-03 `tests/fm-herdr-projected-cd-live-e2e.test.sh` serial hint is provisionally 28000 ms, above a successful 27692 ms local runner sample exercising Herdr 0.9.5 on macOS arm64, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-27 `tests/fm-claude-account-quota.test.sh` serial hint is a provisional local measurement of 2492 ms, the slowest of five local `bin/fm-test-run.sh` samples (1930-2492 ms) on a Linux host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-11-04 `tests/fm-install-herdr.test.sh` serial hint is a provisional local measurement of 1000 ms, above the slowest of five `bin/fm-test-run.sh` samples (155-223 ms) on a Linux host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-26 `tests/fm-test-tap-verify.test.sh` serial hint is a provisional local measurement of 1000 ms, above a 238 ms `bin/fm-test-run.sh` sample on this Linux host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-11-08 `tests/fm-lavish-url.test.sh` serial hint is a provisional local measurement of 30000 ms, above the slowest of three `bin/fm-test-run.sh` samples (25148-26650 ms) on a Linux host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-27 read-repetition suites carry provisional Linux x86_64 local runner maxima: 602 ms for `tests/fm-read-repetition.test.sh` (six successful samples, 528-602 ms) and 1110 ms for `tests/fm-read-repetition-live.test.sh` (five successful samples, 949-1110 ms).
`tests/fm-park.test.sh` is now a portable parallel member; its 70085 ms parallel hint is its completed passing Ubuntu `FM_TEST_END` sample from CI run [42730709201](https://github.com/kunchenguid/firstmate/actions/runs/42730709201), and `tests/fm-arm-pretool-check.test.sh` moved to parallel lane 2 to keep the lanes within 5%.
The live samples exercised installed Pi 1.4.0 RPC without capability skips; they are not CI timing evidence or timings for unavailable harnesses.
Both suites retain serial placement and full coverage; replace these provisional hints with Ubuntu timing-artifact maxima at the next measured refresh.
The 2026-10-29 `tests/fm-live-lab-isolation.test.sh` serial hint is a provisional local measurement of 6459 ms, the slowest of six `bin/fm-test-run.sh` samples (4308-6459 ms) taken inside a private `unshare -Urm` /tmp on this Linux host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-27 `tests/fm-codex-stop-park.test.sh` serial hint is a provisional local measurement of 35000 ms, above the slowest of the `bin/fm-test-run.sh` samples (20170-34700 ms) on a macOS arm64 host, until a later measured refresh replaces it with an Ubuntu timing-artifact maximum.
The 2026-10-28 Antigravity primary tests carry provisional serial hints - 45000 ms for `tests/fm-agy-primary.test.sh` and the 75 ms live-guard skip for `tests/fm-agy-primary-live-e2e.test.sh` - until a later measured refresh replaces them with Ubuntu timing-artifact maxima.
The wedge-cap suite carries the Ubuntu measurements from CI run [39597689178](https://github.com/kunchenguid/firstmate/actions/runs/39597689178) - 374225 ms for `tests/fm-watch-wedge-cap.test.sh` and the 74 ms live-guard skip for `tests/fm-watch-wedge-cap-live.test.sh` - in place of the provisional local measurements the suite first carried (1003000 ms and the 155 ms skip), which overstated the CI cost of both.
They are not a formality: without a hint the suite is packed on the 45000 ms default, which puts it beside a shard already holding about 17 minutes of measured work, so that shard would really have run for about 23 minutes - past the 20-minute target the guard reserves - while the coverage guard still passed.
The same run measured the wedge-cap parity suite at 27763 ms, which `bin/fm-test-run.sh` packs in place of the provisional 209000 ms local measurement.
`test_portable_serial_packing_budget_boundary` now pins every other fixture script to 1 ms, so packing exactly at the 1200000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
The session-start hint retains its pre-optimization maximum until a recorded measurement covers the shorter fixture-only home-summary bound; do not discount a local speedup from hosted packing weights.
The T3 Code backend suites carry the slowest successful Ubuntu samples from CI runs [39463576576](https://github.com/kunchenguid/firstmate/actions/runs/39463576576), [39814995718](https://github.com/kunchenguid/firstmate/actions/runs/39814995718), and [39883948163](https://github.com/kunchenguid/firstmate/actions/runs/39883948163) - 239245 ms for `tests/fm-backend-t3code.test.sh`, 57613 ms for `tests/fm-t3-mcp.test.sh`, 283 ms for `tests/fm-watch-inbox-meta.test.sh`, and the 51 ms and 52 ms live-guard skips for `tests/fm-backend-t3code-live-e2e.test.sh` and `tests/fm-backend-t3code-pr-tools-live-e2e.test.sh`.
`tests/fm-backend-t3code.test.sh` and `tests/fm-t3-mcp.test.sh` run in the portable parallel lanes, so those two values sit in `portable_parallel_weight_hints`: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

The new `tests/fm-remote-herdr-identity.test.sh` serial hint is provisionally 6158 ms, from a successful local macOS arm64 `bin/fm-test-run.sh` sample on 2026-11-08. Replace it with an Ubuntu timing-artifact maximum at the next measured refresh; this is not whole-shard CI timing evidence.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The local gate has no hosted job cap; [Gate execution bounds](#gate-execution-bounds) below owns the runner's own bounds.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green upstream-CI runs' `fm-test-timing-portable-parallel-*` artifacts where available, or from recorded local `bin/fm-test-run.sh --json` samples with their host and date, whenever the parallel set gains scripts or a member grows materially.

The remote-secondmate lifecycle hint is 1005249 ms, its completed, passing `FM_TEST_END` sample from Ubuntu run [41289019354](https://github.com/kunchenguid/firstmate/actions/runs/41289019354). Rex lifecycle coverage outgrew the previous 345655 ms hint; serial shard 9 then reached the 30-minute job cap while running later tests. Eleven serial shards accommodate the refreshed weight within the unchanged modeled budget and timeout policy. This is a completed-script measurement from a partial run, not a successful whole-shard timing or a guarantee of future headroom.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.
The gate's lane invocation then excludes the `live-harness-optin` and `hc` families; lane membership itself still includes them, so the coverage guard keeps its complete partition.

## Portable serial shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate shard runs, while the local gate runs the whole `portable-serial` lane in one serial pass.
Each shard is still strictly serial in itself, and separate shard runs mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it, so a caller cannot silently drop a shard or leave part of the portable suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.

A script whose `test_*` calls are independent and listed flat at the end of the file may also be split into slices, so one long suite no longer pins a whole shard.
`portable_serial_split_hints` in `bin/fm-test-run.sh` names each such script and its slice count, and `--list-split-hints` prints that table.
Each slice becomes its own packed unit, and a shard that receives several slices of one script runs them together.
`tests/fm-test-slice-gate.sh` is loaded through `BASH_ENV` for that one script and runs every n-th top-level `test_*` call, in call order, so the slices together run each call exactly once.
A script that registers its tests through `fm_test_run` in `tests/lib.sh` is numbered there instead, in registration order, under the same slice variables.
A slice that ran no call fails its shard unless the script declared its own capability skip, so a slice can never pass by doing nothing.
The coverage guard requires every slice of every split script to be assigned exactly once, and `tests/fm-test-run.test.sh` proves the gate runs each call once and that every split script has at least one call per slice.
Add a script to the split table only when its calls do not depend on one another's side effects.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and make a shard-runner split lopsided and slow.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The watch-triage suite is three serial members so no one file occupies a whole serial shard: `tests/fm-watch-triage.test.sh` (classifier, signal/turn-end absorb, wedge ladder, gone endpoints, TERM, busy-pane age, timer repair, procevent, heartbeat/afk hand-off, exit picker; hint 592950 ms), `tests/fm-watch-triage-pause.test.sh` (declared waits, captain-call holds, pause transitions, away/quiet holds, paused-until and background-job waits; hint 466750 ms), and `tests/fm-watch-triage-wedge-defer.test.sh` (wedge-threshold deferrals; 13 tests, hint 526980 ms).
Those hints are the per-file sums of per-test durations from the slowest CI sample, run [40280579086](https://github.com/kunchenguid/firstmate/actions/runs/40280579086), rounded up, replacing the 1074843 ms single-file sample that sat in a serial shard with about 27.8 minutes of tests against the 30-minute job cap.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
Even so, maxima from five runs do not establish a P95 or guarantee future headroom.
The hosted job timeouts referenced above remain hang tripwires; [Gate execution bounds](#gate-execution-bounds) below owns the local gate's bounds, and neither is the desired healthy duration.
`tests/fm-test-run.test.sh` holds the lane and shard contracts against the executable runner, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the hints by collecting recorded per-script `duration_ms` samples and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured value per `path`.
Where upstream CI artifacts are available, download them from several green runs:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable lanes skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial shards](#portable-serial-shards); neither replaces inspection of actual recorded timing artifacts.

## Timing artifacts

Each lane and each portable serial shard can emit runner-generated timing JSON, and the worker's no-mistakes evidence carries the Test run that used them.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`bin/fm-test-run.sh` owns the JSON fields and the aggregation wiring; this fork has no workflow wiring for them.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns the canonical lint partitions (`--partition KofN` for N from 2 to 8), each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
The full lint mode requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The partitioned mode emits each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout; more partitions and slices only spread the same checks across more partitions.

The upstream performance objective remains a complete green run under fifteen minutes including start delay, but the three watch-triage members still sum to about 26 minutes of hosted test time.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The upstream layout used long-lived Linux jobs for twelve serial shards, two parallel lanes (each running four scripts at a time, the bound proven in [fm-test-isolation-proof.md](fm-test-isolation-proof.md)), Herdr, and eight lint partitions, plus short checks and macOS; this fork runs only the macOS job, and the local gate runs the portable lanes serially.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The upstream workflow retained per-PR supersession and kept only the newest of close main pushes' runs, without changing the compliance workflow's event semantics; the fork's macOS workflow keeps per-pull-request supersession.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.
The gate's `commands.test` runs `--check-coverage` and then each portable lane with `--exclude-family live-harness-optin --exclude-family hc` under `FM_LIVE=0`, so a gate round exercises no live guard, live Herdr session, release download, or hc binary.

## Gate execution bounds

The hosted workflow's three-tier job timeouts died with it, and the macOS workflow keeps one normal-tier 30-minute tripwire on its own job.
The local gate runs the coverage guard and the three portable lanes serially with no hosted job cap.
no-mistakes bounds one Test-step agent invocation with its global `test_agent_timeout`, not with these runner flags; the full portable walk takes roughly 3.5-4 hours, so the gate host sets that global value to 5h. no-mistakes reads the key only from its global config, so a copy in `.no-mistakes.yaml` is ignored.
The runner's optional `--per-script-timeout-secs` and `--max-wall-ms` are per-script result checks or hang tripwires, never a packing estimate or a runtime target.
The 12 portable serial shards stay sequenced: they split hosted runners, and the gate walks the whole lane in one serial pass because stateful scripts never share a machine.
A lane that hangs is investigated and fixed rather than given a larger cap.
A passing coverage guard does not establish a healthy duration; refresh the healthy figures above from recorded timing artifacts.

## Manual backend and live lanes

Deleting the hosted workflow removed the only automation for the real-Herdr family and the pinned hc family, so neither is automated on every pull request any more.
Run them by hand before merging a change that touches Herdr, hc, or their pinned installers:

- `bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip herdr`, which needs an installed Herdr binary and the pinned Treehouse build.
- `bin/fm-test-run.sh --family hc --fail-on-gate-skip 'hc not found'` with `FM_HC_BIN` pointing at the pinned herdr-core build from `bin/fm-install-hc.sh`; its smokes need `jq`.

A hermetic gate sandbox carries neither binary, and the gate excludes both families rather than silently capability-skipping them.
The gate also excludes the live-harness opt-in family and sets `FM_LIVE=0`, so no default-on guard drives a live Herdr session or downloads release binaries; run those guards directly after a harness upgrade.
