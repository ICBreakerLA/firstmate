# Sandbox verification broker

A sandboxed worker cannot reach the host's Android emulator, so a home that sets `verify=app` in [`config/worker-sandbox`](configuration.md#worker-sandbox-configworker-sandbox) gives its sandboxes a request spool instead.
The worker writes small typed requests into the spool, a host-side broker validates each one, runs the host's pinned `sm-verify` command for it, and writes a typed result back.
The worker never gets a shell on the host, never names a path or an option for `sm-verify`, and never writes Maestro YAML.
When the home also names an iOS host, the same verbs can be run against the Mac's iOS simulator by adding `"platform": "ios"` to a request, and the broker reaches the Mac over ssh instead of running anything locally.
This page is the contract a worker-side client implements against.
The broker is [`bin/fm-sbx-verify-broker.sh`](../bin/fm-sbx-verify-broker.sh), its grammar and validator are in [`bin/fm-sbx-verify-lib.sh`](../bin/fm-sbx-verify-lib.sh), and the byte-level copy and the one-file server are in [`bin/fm-sbx-verify-io.py`](../bin/fm-sbx-verify-io.py).

## Where the spool is

The sandbox gets two mounts and one environment variable.

| Item | Meaning |
| --- | --- |
| `FM_SBX_VERIFY_SPOOL` | The absolute path of the request spool. Its sibling directory `res` holds the results. |
| `$FM_SBX_VERIFY_SPOOL` (read-write) | The worker writes requests, and the optional bundle file, here. |
| `$FM_SBX_VERIFY_SPOOL/../res` (read-only) | The broker writes results and evidence here. The worker cannot change them. |

The environment variable is set only when the sandbox was launched with the opt-in, so its absence means there is no broker.
A client that finds it unset should say so and stop, not look for another path.

## Requests

A request is one file named `<seq>.json` in the spool, where `<seq>` is decimal digits only and the number is chosen by the client.
Use a fresh, increasing number for each request, because the result file reuses it.
Write the file somewhere else in the spool first, such as `.tmp.<seq>`, and `mv` it to `<seq>.json`, so the broker never sees a half-written request.
The broker ignores every name that is not all digits plus `.json`.

The file must be a regular file under 64 KiB.
A symlink, a FIFO, a directory, or a larger file is answered with a `rejected` result and is never read.
The broker copies the bytes into a host-only directory first and validates only that copy, so replacing or renaming the file afterwards changes nothing.
Each number is answered once.
The broker never writes into the spool, so it remembers answered numbers itself and ignores a number it has already answered, which means a client must never reuse a number.

The body is a JSON object with a `verb`, an optional `id`, and the keys of that verb, and any other key is rejected.
`id` is 1 to 64 characters of letters, digits, `_`, `.` and `-`, and the result echoes it so a client can match results to requests without relying on the number.

Every verb also accepts an optional `platform` of `android` (the default) or `ios`.
Any other value is `bad_request`, and `ios` is `platform_unavailable` when no iOS host is configured.
The verb's own keys, the step allowlist, the forbidden commands and the selector denylist are the same for both platforms, and `up` with `bundle: true` is refused for `ios` because there is no bundle server on the Mac.

## Results

The result for `<seq>.json` is `res/<seq>.json`, written atomically, so its appearance means it is complete.
It is a JSON object.

| Key | Meaning |
| --- | --- |
| `v` | The protocol version, currently `1`. |
| `seq` | The request number. |
| `id` | The request's `id`, or `null`. |
| `verb` | The verb, or `null` when the request was too malformed to read one. |
| `status` | `ok`, `failed`, `rejected`, `error`, or `queued`. |
| `code` | A machine-readable reason, or `null` on success. |
| `message` | A short human-readable reason, or `null`. |
| `platform` | `ios` on every result for an iOS request. An Android result has no `platform` key. |

`ok` means the verb ran and `sm-verify` exited 0.
`failed` means it ran and exited non-zero (`code: command_failed`) or ran out of time (`code: timeout`).
`rejected` means the broker refused the request and ran nothing.
`error` means the broker could not carry the request out, such as a missing pinned command, a bundle server that would not start, or an iOS host it could not reach.
`queued` means another task holds the emulator, and the request was not run.

A command result also carries these keys.

| Key | Meaning |
| --- | --- |
| `exit` | The exit code of `sm-verify`. |
| `stdout`, `stderr` | The command's output with control bytes removed and a size cap. |
| `evidence` | A list of `{name, path, bytes, sha256}` for each screenshot copied out. |
| `evidence_skipped` | How many files in the evidence directory were not copied. |
| `bundle_url` | Present after `up` with `bundle: true`. |

An evidence `path` is relative to `res/`, for example `7/shot.png`.
Only a regular file with PNG magic bytes, under 5 MiB, with a plain name, is copied, and at most 8 files per request.
Everything else is counted in `evidence_skipped` and dropped.
Treat `stdout` and `stderr` as untrusted text, since they come from the app and from whatever the worker put on screen.

## Verbs

| Verb | Keys | What the host runs |
| --- | --- | --- |
| `up` | `bundle` (optional boolean) | `sm-verify up`, after taking the lease. With `bundle: true` the broker first copies `index.bundle` out of the spool and serves it. |
| `doctor` | none | `sm-verify doctor` |
| `tab` | `name` | `sm-verify tab <name>` |
| `shot` | `name` (optional) | `sm-verify shot [name]` |
| `tree` | none | `sm-verify tree` |
| `metro-log` | `lines` (1 to 500, default 100) | `sm-verify metro-log <lines>` |
| `down` | none | `sm-verify down`, then the lease is released even when `sm-verify` exits non-zero, which it does when no run is up |
| `status` | none | Nothing. The broker answers from its own state. |
| `do` | `step` | A generated one-step flow through `sm-verify do <file>` |
| `flow` | `steps` (1 to 40) | A generated flow through `sm-verify flow <file>` |

`tab` takes a name of 1 to 40 letters, digits, spaces, `_` and `-`, and `shot` takes a name of 1 to 40 letters, digits, `_` and `-` that starts with a letter or digit.
There is no verb that types text, and there is no Enter keypress.
`inputText` is rejected on purpose, and `up` is the only verb that can start the emulator.

### Steps

A step is a JSON object with exactly one key, shaped like the Maestro command it becomes.
The broker generates all the YAML itself from these, so a request never carries YAML, a header, or a path.

| Step | Shape |
| --- | --- |
| `tapOn` | `{"tapOn": {"text": "Home"}}` or `{"tapOn": {"id": "home_tab"}}` |
| `assertVisible`, `assertNotVisible` | the same selector object |
| `scroll`, `back`, `hideKeyboard`, `waitForAnimationToEnd` | `{"back": {}}` |
| `swipe` | `{"swipe": {"direction": "UP"}}` with `UP`, `DOWN`, `LEFT` or `RIGHT` |
| `extendedWaitUntil` | `{"extendedWaitUntil": {"visible": {"text": "Home"}, "timeout": 5000}}`, timeout 1 to 30000 ms, default 10000 |
| `takeScreenshot` | `{"takeScreenshot": {"name": "home"}}`, a name of 1 to 40 letters, digits, `_` and `-` |

A selector text is 1 to 80 printable ASCII characters, and an id is 1 to 80 characters of letters, digits and `_ . : / -`.
The broker escapes a selector so it matches literally and in full, so `.` and `*` are ordinary characters and not patterns.

Every other step is refused, and these names are refused with the dedicated code `forbidden_step`: `inputText`, `pressKey`, `runScript`, `evalScript`, `runFlow`, `openLink`, `launchApp`, `stopApp`, `clearState`, `clearKeychain`, `addMedia`, `copyTextFrom`, `setLocation`, and a number of related commands.
A `flow` whose step list contains a YAML header key such as `appId`, `env` or `url` is refused the same way.

### Denied selectors

A `tapOn` selector, and a `tab` name, is refused with `denied_selector` when it contains any of these after normalization: `sign in`, `signin`, `continue with`, `google`, `apple`, `like`, `pass`, `send`, `join`, `leave`, `cancel`, `create`, `save`, `delete`, `block`, `report`, `waitlist`, and the check-in answers `i'm here`, `no, i'm not` and `yes, i'm`.
Normalization lower-cases the text, maps typographic apostrophes to `'`, turns runs of `-`, `_` and `.` into one space, and collapses whitespace.
The match is a substring match on purpose, so `Passport` and `Saved` are refused too, and a client that must tap such a control has to do it by hand.
The denylist applies only to taps, so `assertVisible` and `extendedWaitUntil` can look for any text.

## Errors

| `status` | `code` | Meaning |
| --- | --- | --- |
| `rejected` | `request_too_large` | The file is 64 KiB or more. |
| `rejected` | `not_regular` | The file is a symlink or a special file. |
| `rejected` | `malformed_json` | The body is not valid JSON. |
| `rejected` | `bad_request` | The shape is wrong, or a key is not accepted for that verb. |
| `rejected` | `unknown_verb` | The verb is not in the table above. |
| `rejected` | `bad_step` | A step has the wrong shape or is not in the allowlist. |
| `rejected` | `forbidden_step` | A step names a command that is never allowed. |
| `rejected` | `denied_selector` | A tap or tab names a denied control. |
| `rejected` | `bundle_missing`, `bundle_not_regular`, `bundle_too_large` | `up` with `bundle: true` found no usable `index.bundle`. |
| `error` | `bundle_server` | The bundle could not be served on the broker's port. |
| `error` | `internal` | The broker could not read the request. |
| `rejected` | `platform_unavailable` | The request asked for `ios` and no iOS host is configured. |
| `error` | `mac_unreachable` | The iOS host could not be resolved or reached. |
| `error` | `ssh_refused` | The iOS host refused the connection. |
| `error` | `ssh_auth` | The iOS host refused the key. |
| `error` | `ssh_host_key` | The iOS host's key is not the one on record, or is not on record. |
| `error` | `ssh_failed` | ssh failed in another way. |
| `error` | `sm_verify_missing`, `sm_verify_changed` | The iOS host's pinned command is absent, or its digest differs from the pin. |
| `error` | `remote_failed` | A broker helper command on the iOS host (preparing its scratch directory) exited non-zero. |
| `error` | `timeout` | An iOS preflight step ran out of time. |
| `failed` | `command_failed`, `timeout` | `sm-verify` exited non-zero or ran out of time. |
| `queued` | `busy` | Another task holds the emulator. |

## The lease and the queue

One task at a time holds the emulator, and the lease is a lock on a file in the host's lease directory, shared by every home that uses the same emulator.
The iOS simulator has its own lease, lock and queue in the same directory, so an iOS run never waits for the Android emulator and the other way round.
A task can hold both at once, `status` takes the same `platform` key to describe either, and its `bundle` is always `null` for iOS.
The first verb that needs the emulator takes it, and every later verb from that task refreshes its idle clock.
After the idle TTL, 20 minutes by default, the broker takes the lease back and runs a forced `down`.
The lease also ends, with the same forced `down`, when the worker sends `down`, when the sandbox goes away, and when the task is torn down.

A second task that asks while the lease is held gets `status: queued` with `code: busy`, its place in `position`, and the holder's remaining time.
The request is not run, so the client must send it again, with a new number, after it has waited.
A waiting task keeps its place for the queue TTL, 3 minutes by default, so it must ask again within that time, and the earliest waiter is served first.
`status` never takes the lease, and it reports `holder` as `you`, `other` or `none`, `emulator_up`, how many tasks are `waiting`, and whether a `bundle` is being served.

## Building and serving the code under test

The worker builds a static bundle in its VM and writes exactly one file, `index.bundle`, into the spool.
Then it sends `{"verb": "up", "bundle": true}`.
The broker copies that one regular file out, up to 128 MiB, hashes it, and serves it from memory on its own port, 8081 by default.
The server answers `GET` and `HEAD /` with a fixed Expo manifest, because the Expo dev client reads it before it loads anything, and its launch asset is `http://<the Host the client used>/index.bundle`.
It answers `GET /status` with `packager-status:running`, which the app checks before it fetches the bundle.
It answers `GET /index.bundle` with the file whatever the query string says, and answers everything else, including every other method and a Host header that is not a plain host and port, with a plain 404.
The manifest is built by the broker and carries none of the worker's bytes, and the server never reads a file on request, so there is no path to traverse and nothing to glob.
The result carries `bundle_url`, and the broker passes it to `sm-verify` as `FM_SBX_VERIFY_BUNDLE_URL` and `FM_SBX_VERIFY_BUNDLE_PORT`.
Sending `up` with a new bundle replaces the served one, and the server stops when the lease ends.
A bundle from `expo export` is a production build, so the app writes nothing to the Android log tag `ReactNativeJS`, and `metro-log` returns only its header line.
This was observed on the emulator with the app loaded and no log lines under the app's process.

The app that loads this bundle runs worker-authored JavaScript signed in as the verify account.
That residual risk was accepted when this design was chosen, and the denylist and the missing text-entry verb limit what a tap sequence can reach but not what the bundle itself can do.

## iOS

iOS runs only on the Mac, so a request with `"platform": "ios"` is carried out over ssh to the one alias named by `ios-host` in `config/sbx-verify`, and nothing runs locally in its place.
The broker uses the existing alias and key as they are, adds no credential, and runs ssh with `BatchMode`, `StrictHostKeyChecking=yes`, no agent, X11 or port forwarding, no local command and no terminal.
An unresolvable, refused, unauthenticated or host-key-changed connection is a typed `error` result, never a hang and never a local fallback.

Each iOS request runs these steps over ssh, and every remote command is one simple command whose words come from validated fields or from config, quoted once in `fm_sbxv_remote_cmd`:

1. `shasum -a 256` of the pinned `ios-sm-verify` is compared with `ios-sm-verify-sha256`, and a mismatch or a missing file is `sm_verify_changed` or `sm_verify_missing` before anything else runs.
2. A scratch directory is made under `ios-work-dir`, named from the task and request.
3. For `do` and `flow`, the host generates the Maestro YAML exactly as for Android, with the Mac's evidence directory and `ios-app-id`, and sends it on stdin to a file in that directory.
4. The pinned command is run with `env -u SM_IOS_VERIFY_APPLE`, so the Apple verify account is never enabled, and with `FM_SBX_VERIFY_EVIDENCE_DIR` pointing into the scratch directory.
5. The plain-named regular files of the evidence directory are listed, and at most 8 are fetched one at a time, each cut off just past 5 MiB, into the same host directory the Android path uses.
6. The scratch directory is removed, and the result never depends on that cleanup.

Evidence then goes through the same checks as on Android, so a file that is not a regular PNG under 5 MiB with a plain name is counted in `evidence_skipped` and dropped.
The broker never builds anything, never runs `build-ios`, and never installs; `up` does only what `sm-verify up` does.
The limits are the same as for Android: 900 seconds for `up`, 300 for `do` and `flow`, 120 for the rest, and 30 seconds for each helper step, all overridden by `FM_SBX_VERIFY_TIMEOUT`.
A run that outlives its limit is `failed` with `code: timeout`, and a helper step that does is an `error` with the same code.
Ending an iOS lease sends `down` to the Mac the same way it does for Android, whether the worker asks, the lease idles out, the sandbox disappears, the task is torn down, or the broker was killed.

The digest check and the exec are two ssh calls, so a process that can write the Mac's pinned file between them could swap it.
The Mac's file should therefore be owned by a user the worker account cannot write as, and the key the broker uses should be limited on the Mac by a forced command that accepts only the pinned `sm-verify`, `shasum`, `mkdir`, `dd`, `find`, `head` and `rm` forms above.
That wrapper is a Mac-side change and is not made by this repository.

## What the host runs

The broker runs only the file named by `sm-verify` in `config/sbx-verify` (for `ios`, `ios-sm-verify` on the Mac, under the section above), and it checks that file before every run.
It runs it with no stdin, in a scratch directory under the task's host-only state, with a time limit of 900 seconds for `up`, 300 for `do` and `flow`, and 120 for the rest.
The arguments are built from validated fields only, in these shapes: `up`, `doctor`, `tree`, `down`, `tab <name>`, `shot [name]`, `metro-log <lines>`, and `do|flow <generated-yaml-path>`.
The generated YAML is never read from the worker, and the pinned path is never read from the worker's clone or from any directory a sandbox can write.

The command also gets `FM_SBX_VERIFY_EVIDENCE_DIR`, an empty host directory.
It must write any screenshots there, and the broker copies out only the files that pass the evidence rules above.

Every request, its verdict, its digest, and each command run is appended to a host-only audit log, `state/<id>.sbx-verify/host/audit.log`, which no sandbox mount reaches.

## Assumptions

- The broker runs on a Linux host with `flock`, `jq` and `python3`, and `ssh` when an iOS host is set, and `check` refuses the launch when one is missing.
- `check` never contacts the Mac, so a Mac that is down shows up as a typed `error` on the first iOS request.
- The host's emulator is the one `sm-verify` drives, and `sm-verify` is the only thing the broker trusts.
- A client waits for `res/<seq>.json` with a timeout longer than the verb's time limit.
