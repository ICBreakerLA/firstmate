# Sandbox verification broker

A sandboxed worker cannot reach the host's Android emulator, so a home that sets `verify=sportsmeet` in [`config/worker-sandbox`](configuration.md#worker-sandbox-configworker-sandbox) gives its sandboxes a request spool instead.
The worker writes small typed requests into the spool, a host-side broker validates each one, runs the host's pinned `sm-verify` command for it, and writes a typed result back.
The worker never gets a shell on the host, never names a path or an option for `sm-verify`, and never writes Maestro YAML.
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

`ok` means the verb ran and `sm-verify` exited 0.
`failed` means it ran and exited non-zero (`code: command_failed`) or ran out of time (`code: timeout`).
`rejected` means the broker refused the request and ran nothing.
`error` means the broker could not carry the request out, such as a missing pinned command or a bundle server that would not start.
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
| `down` | none | `sm-verify down`, then the lease is released |
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
| `failed` | `command_failed`, `timeout` | `sm-verify` exited non-zero or ran out of time. |
| `queued` | `busy` | Another task holds the emulator. |

## The lease and the queue

One task at a time holds the emulator, and the lease is a lock on a file in the host's lease directory, shared by every home that uses the same emulator.
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
The server answers `HEAD /` and `HEAD /index.bundle` with a JavaScript content type, answers `GET /index.bundle` with the file whatever the query string says, and answers everything else, including every other method, with a plain 404.
It never reads a file on request, so there is no path to traverse and nothing to glob.
The result carries `bundle_url`, and the broker passes it to `sm-verify` as `FM_SBX_VERIFY_BUNDLE_URL` and `FM_SBX_VERIFY_BUNDLE_PORT`.
Sending `up` with a new bundle replaces the served one, and the server stops when the lease ends.

The app that loads this bundle runs worker-authored JavaScript signed in as the verify account.
That residual risk was accepted when this design was chosen, and the denylist and the missing text-entry verb limit what a tap sequence can reach but not what the bundle itself can do.

## What the host runs

The broker runs only the file named by `sm-verify` in `config/sbx-verify`, and it checks that file before every run.
It runs it with no stdin, in a scratch directory under the task's host-only state, with a time limit of 900 seconds for `up`, 300 for `do` and `flow`, and 120 for the rest.
The arguments are built from validated fields only, in these shapes: `up`, `doctor`, `tree`, `down`, `tab <name>`, `shot [name]`, `metro-log <lines>`, and `do|flow <generated-yaml-path>`.
The generated YAML is never read from the worker, and the pinned path is never read from the worker's clone or from any directory a sandbox can write.

The command also gets `FM_SBX_VERIFY_EVIDENCE_DIR`, an empty host directory.
It must write any screenshots there, and the broker copies out only the files that pass the evidence rules above.

Every request, its verdict, its digest, and each command run is appended to a host-only audit log, `state/<id>.sbx-verify/host/audit.log`, which no sandbox mount reaches.

## Assumptions

- The broker runs on a Linux host with `flock`, `jq` and `python3`, and `check` refuses the launch when one is missing.
- The host's emulator is the one `sm-verify` drives, and `sm-verify` is the only thing the broker trusts.
- A client waits for `res/<seq>.json` with a timeout longer than the verb's time limit.
