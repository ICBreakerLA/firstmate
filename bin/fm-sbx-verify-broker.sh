#!/usr/bin/env bash
# fm-sbx-verify-broker.sh - the host-side verification broker for a sandboxed
# worker (config/worker-sandbox `verify=sportsmeet`).
#
# A sandboxed worker cannot reach the host's Android emulator, so it asks for
# a fixed set of verbs through a request spool and reads typed results back.
# This script runs on the host, treats every byte of a request as untrusted,
# and is the only thing that ever invokes the pinned sm-verify command.
# docs/sbx-verify-broker.md owns the request and result protocol and the verb
# list; bin/fm-sbx-verify-lib.sh owns the config grammar, the validator, the
# selector denylist and the Maestro generator; bin/fm-sbx-verify-io.py owns the
# no-follow copy and the one-file bundle server.
#
# Usage:
#   fm-sbx-verify-broker.sh check --config DIR [--state DIR]
#   fm-sbx-verify-broker.sh init  --id ID --state DIR
#   fm-sbx-verify-broker.sh run   --id ID --state DIR --config DIR --sandbox NAME
#                                 [--once] [--interval SECS]
#   fm-sbx-verify-broker.sh stop  --id ID --state DIR --config DIR [--wait SECS]
#
#   check   verify jq, python3, flock and a loadable config/sbx-verify; prints
#           nothing and exits 0 when the broker can run (fm-sbx-run.sh calls it
#           before it creates the sandbox).
#   init    create state/<id>.sbx-verify/{req,res,host}: `req` is the one
#           directory the worker can write (mounted read-write), `res` holds the
#           results (mounted read-only; only this script writes it), and `host`
#           is never mounted.
#   run     serve until terminated: process requests, expire the lease, and on
#           the sandbox disappearing, SIGTERM, SIGINT or SIGHUP force a `down`
#           when this task holds the lease, stop the bundle server and release
#           the lease.
#           --once handles the requests present now and exits without the final
#           teardown, as a test and debugging aid.
#   stop    TERM a running broker of this task, wait for its forced `down`, and
#           fall back to KILL plus a host-side `down` when it does not exit.
#
# Trust boundary: a request is a regular file req/<digits>.json, under 64 KiB.
# Its bytes are copied with no-follow semantics into host/in/ and only that
# copy is ever validated or parsed again, so swapping, renaming or replacing
# the worker's file afterwards changes nothing.
# Every request, verdict and digest is appended to host/audit.log.
# The sm-verify argument list is built by this script from validated fields;
# no worker string becomes a path, an option or a YAML key.
#
# The lease is a flock on <lease-dir>/lease.lock shared by every home that uses
# the emulator, with an idle TTL; a second holder gets a `queued` reply and its
# request is not run.
#
# Environment (tests): FM_SBX_VERIFY_SANDBOX_POLL seconds between sandbox
# liveness checks (default 5); FM_SBX_VERIFY_TIMEOUT overrides every
# sm-verify time limit in seconds; with FM_TEST_SEAM=1,
# FM_SBX_VERIFY_TEST_HOOK is run as `HOOK pre-copy|post-copy <request-path>`
# around each request copy to simulate a swap race.
set -u
export LC_ALL=C
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-sbx-lib.sh
. "$SCRIPT_DIR/fm-sbx-lib.sh"
# shellcheck source=bin/fm-sbx-verify-lib.sh
. "$SCRIPT_DIR/fm-sbx-verify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
IO="$SCRIPT_DIR/fm-sbx-verify-io.py"

MAX_REQUEST=65535
MAX_BUNDLE=134217728
MAX_EVIDENCE_FILES=8
MAX_EVIDENCE_BYTES=5242880
MAX_PER_PASS=200

ID='' STATE='' CONFIG='' SANDBOX='' ONCE=0 INTERVAL=1 WAIT=60
HOLDING=0 LEASE_LAST=0 LEASE_UP=0 STOP=0 FINISHED=0
SERVER_PID='' BUNDLE_URL='' BUNDLE_SHA=''
REQ_ID='' REQ_VERB=''

die() {
  echo "error: $*" >&2
  exit 2
}

now() { date +%s; }

audit() { # <kind> [key value]...
  local kind=$1 a=()
  shift
  while [ "$#" -ge 2 ]; do
    a+=(--arg "$1" "$2")
    shift 2
  done
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg kind "$kind" "${a[@]+"${a[@]}"}" '$ARGS.named' >>"$HOST/audit.log" 2>/dev/null || true
}

# ---------------------------------------------------------------- lease ----

state_read() {
  local k v
  LS_OWNER='' LS_LAST=0 LS_UP=0
  [ -f "$LEASE_DIR/state" ] && [ ! -L "$LEASE_DIR/state" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
    owner) LS_OWNER=${v//[!A-Za-z0-9-]/} ;;
    last) LS_LAST=${v//[!0-9]/} ;;
    up) LS_UP=${v//[!01]/} ;;
    esac
  done <"$LEASE_DIR/state"
  : "${LS_LAST:=0}" "${LS_UP:=0}"
}

state_write() { # <owner> <last> <up>
  printf 'owner=%s\nlast=%s\nup=%s\n' "$1" "$2" "$3" >"$LEASE_DIR/state.tmp.$$" &&
    mv -f "$LEASE_DIR/state.tmp.$$" "$LEASE_DIR/state"
}

# queue entries: <lease-dir>/queue/<key> holding "<first> <last>".
queue_touch() {
  local f="$LEASE_DIR/queue/$KEY" first t
  t=$(now)
  first=$t
  if [ -f "$f" ]; then
    first=$(cut -d' ' -f1 "$f" 2>/dev/null)
    case "$first" in '' | *[!0-9]*) first=$t ;; esac
  fi
  printf '%s %s\n' "$first" "$t" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

queue_remove() { rm -f "$LEASE_DIR/queue/$KEY" 2>/dev/null || true; }

# queue_live: print "<first> <key>" for each waiting holder, oldest first,
# dropping entries that were not refreshed within the queue TTL.
queue_live() {
  local f key first last t
  t=$(now)
  for f in "$LEASE_DIR"/queue/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    key=${f##*/}
    case "$key" in *.tmp.* | '' | *[!A-Za-z0-9-]*) continue ;; esac
    read -r first last <"$f" 2>/dev/null || continue
    case "$first$last" in '' | *[!0-9]*) continue ;; esac
    if [ $((t - last)) -gt "$FM_SBXV_QTTL" ]; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    printf '%s %s\n' "$first" "$key"
  done | sort -n -k1,1 -k2,2
}

# queue_position: this holder's 1-based place among the waiting holders.
queue_position() {
  local i=0 first key
  while read -r first key; do
    i=$((i + 1))
    if [ "$key" = "$KEY" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  done < <(queue_live)
  printf '1\n'
}

lock_is_free() {
  if flock -n 9; then
    flock -u 9
    return 0
  fi
  return 1
}

# acquire_lease: 0 when this task holds the lease, 1 when it is queued.
acquire_lease() {
  local head first
  [ "$HOLDING" = 0 ] || return 0
  read -r first head < <(queue_live | head -n 1) || true
  if [ -n "${head:-}" ] && [ "$head" != "$KEY" ]; then
    queue_touch
    return 1
  fi
  if flock -n 9; then
    HOLDING=1
    queue_remove
    state_read
    if [ "$LS_UP" = 1 ]; then
      audit stale-down owner "$LS_OWNER"
      forced_down "stale-$(now)" || true
    fi
    LEASE_LAST=$(now)
    LEASE_UP=0
    state_write "$KEY" "$LEASE_LAST" 0
    audit lease-acquire key "$KEY"
    return 0
  fi
  queue_touch
  return 1
}

lease_touch() {
  LEASE_LAST=$(now)
  state_write "$KEY" "$LEASE_LAST" "$LEASE_UP"
}

# release_lease <reason>: take the emulator down when it is up, stop the
# bundle server, and give the lease back.
release_lease() {
  [ "$HOLDING" = 1 ] || return 0
  if [ "$LEASE_UP" = 1 ]; then
    if forced_down "release-$(now)"; then
      LEASE_UP=0
    fi
  fi
  stop_server
  if [ "$LEASE_UP" = 1 ]; then
    state_write "$KEY" "$LEASE_LAST" 1
  else
    rm -f "$LEASE_DIR/state" 2>/dev/null || true
  fi
  flock -u 9
  HOLDING=0
  audit lease-release reason "$1"
}

# --------------------------------------------------------------- sm-verify --

check_smv() {
  SMV_CODE=''
  if [ ! -f "$FM_SBXV_SMV" ] || [ ! -x "$FM_SBXV_SMV" ]; then
    SMV_CODE=sm_verify_missing
    return 1
  fi
  SMV_SHA=$(fm_sbxv_sha256 "$FM_SBXV_SMV")
  if [ -n "$FM_SBXV_SMV_SHA" ] && [ "$SMV_SHA" != "$FM_SBXV_SMV_SHA" ]; then
    SMV_CODE=sm_verify_changed
    return 1
  fi
}

smv_timeout() { # <verb>
  if [ -n "${FM_SBX_VERIFY_TIMEOUT:-}" ]; then
    printf '%s\n' "$FM_SBX_VERIFY_TIMEOUT"
    return
  fi
  case "$1" in
  up) echo 900 ;;
  do | flow) echo 300 ;;
  *) echo 120 ;;
  esac
}

# run_smv <label> <timeout> <argv...>: run the pinned command with its working
# directory and evidence directory under host/run/<label>; the exit status is
# left in SMV_RC and its output in stdout and stderr there.
# Extra environment goes in SMV_ENV (name=value words).
run_smv() {
  local label=$1 to=$2 rd
  shift 2
  rd="$HOST/run/$label"
  mkdir -p "$rd/evidence" || return 1
  check_smv || return 1
  (
    cd "$rd" || exit 126
    # Neither the instance lock nor the lease lock may outlive this broker in a child.
    fm_run_timed "$to" env FM_SBX_VERIFY_EVIDENCE_DIR="$rd/evidence" "${SMV_ENV[@]+"${SMV_ENV[@]}"}" "$FM_SBXV_SMV" "$@" 8>&- 9>&- </dev/null >"$rd/stdout" 2>"$rd/stderr"
  )
  SMV_RC=$?
}

forced_down() { # <label>
  SMV_ENV=()
  if ! run_smv "$1" 120 down; then
    audit forced-down result "cannot-run" code "${SMV_CODE:-error}"
    return 1
  fi
  audit forced-down result "exit-$SMV_RC" smv_sha256 "$SMV_SHA"
  [ "$SMV_RC" = 0 ]
}

# ----------------------------------------------------------- bundle server --

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    audit server-stop pid "$SERVER_PID"
  fi
  SERVER_PID='' BUNDLE_URL='' BUNDLE_SHA=''
  rm -f "$HOST/server.pid" "$HOST/server.ready" 2>/dev/null || true
}

# start_server: serve host/bundle/index.bundle on the broker-owned port.
start_server() {
  local i keep_sha=$BUNDLE_SHA
  stop_server
  BUNDLE_SHA=$keep_sha
  rm -f "$HOST/server.ready"
  python3 "$IO" serve --file "$HOST/bundle/index.bundle" --port "$FM_SBXV_PORT" --bind "$FM_SBXV_BIND" --ready "$HOST/server.ready" \
    8>&- 9>&- </dev/null >/dev/null 2>"$HOST/server.err" &
  SERVER_PID=$!
  printf '%s\n' "$SERVER_PID" >"$HOST/server.pid"
  for i in $(seq 1 50); do
    [ -f "$HOST/server.ready" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
  done
  if [ ! -f "$HOST/server.ready" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=''
    rm -f "$HOST/server.pid"
    return 1
  fi
  # 0.0.0.0 is a bind address, not one anything can connect to; sm-verify swaps a loopback host for the address the emulator reaches.
  local url_host=$FM_SBXV_BIND
  [ "$url_host" != 0.0.0.0 ] || url_host=127.0.0.1
  BUNDLE_URL="http://$url_host:$(head -n 1 "$HOST/server.ready" | tr -dc '0-9')/index.bundle"
  audit server-start url "$BUNDLE_URL" bundle_sha256 "$BUNDLE_SHA"
}

# ingest_bundle <seq>: copy exactly one bundle file out of the spool.
# Sets INGEST_CODE and INGEST_MSG on failure.
ingest_bundle() {
  local n=$1 out rc
  mkdir -p "$HOST/bundle"
  rm -f "$HOST/bundle/new.$n"
  out=$(python3 "$IO" copy-in --src "$REQ/index.bundle" --dst "$HOST/bundle/new.$n" --max "$MAX_BUNDLE" 2>/dev/null)
  rc=$?
  case "$rc" in
  0) ;;
  3) INGEST_CODE=bundle_missing INGEST_MSG="up with bundle:true needs a regular file index.bundle in the spool"; return 1 ;;
  5) INGEST_CODE=bundle_too_large INGEST_MSG="index.bundle is larger than the broker accepts"; return 1 ;;
  *) INGEST_CODE=bundle_not_regular INGEST_MSG="index.bundle must be a regular file, not a link or a special file"; return 1 ;;
  esac
  BUNDLE_SHA=${out%% *}
  mv -f "$HOST/bundle/new.$n" "$HOST/bundle/index.bundle"
}

# ---------------------------------------------------------------- replies --

reply() { # <seq> <status> <code> <message> [extra-json]
  local n=$1 st=$2 code=$3 msg=$4 extra=${5:-'{}'}
  jq -nc --argjson seq "$n" --arg id "$REQ_ID" --arg verb "$REQ_VERB" --arg status "$st" --arg code "$code" --arg msg "$msg" --argjson extra "$extra" \
    '{v: 1, seq: $seq, id: (if $id == "" then null else $id end), verb: (if $verb == "" then null else $verb end), status: $status, code: (if $code == "" then null else $code end), message: (if $msg == "" then null else $msg end)} + $extra' \
    >"$RES/.$n.tmp" && mv -f "$RES/.$n.tmp" "$RES/$n.json"
}

collect_evidence() { # <seq> -> EVIDENCE_JSON
  local n=$1 f base cnt=0 skipped=0 out sha size
  EVIDENCE_JSON='[]'
  EVIDENCE_SKIPPED=0
  for f in "$HOST/run/$n/evidence"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    case "$base" in
    '' | .* | *[!A-Za-z0-9._-]*)
      skipped=$((skipped + 1))
      continue
      ;;
    esac
    if [ "${#base}" -gt 64 ] || [ "$cnt" -ge "$MAX_EVIDENCE_FILES" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$RES/$n"
    if out=$(python3 "$IO" copy-in --src "$f" --dst "$RES/$n/$base" --max "$MAX_EVIDENCE_BYTES" --magic png 2>/dev/null); then
      chmod 644 "$RES/$n/$base" 2>/dev/null || true
      sha=${out%% *}
      size=${out##* }
      EVIDENCE_JSON=$(printf '%s' "$EVIDENCE_JSON" | jq -c --arg name "$base" --arg sha "$sha" --argjson size "$size" --arg dir "$n" '. + [{name: $name, path: ($dir + "/" + $name), bytes: $size, sha256: $sha}]')
      cnt=$((cnt + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  EVIDENCE_SKIPPED=$skipped
}

# ------------------------------------------------------------- one request --

lease_info_json() {
  local idle ttl_left
  state_read
  idle=$(($(now) - LS_LAST))
  ttl_left=$((FM_SBXV_TTL - idle))
  [ "$ttl_left" -ge 0 ] || ttl_left=0
  jq -nc --argjson idle "$idle" --argjson ttl "$FM_SBXV_TTL" --argjson left "$ttl_left" '{holder_idle_seconds: $idle, lease_ttl_seconds: $ttl, holder_expires_in_seconds: $left}'
}

do_status() { # <seq>
  local n=$1 holder pos extra up srv
  if [ "$HOLDING" = 1 ]; then
    holder=you
    extra=$(jq -nc --argjson idle "$(($(now) - LEASE_LAST))" --argjson ttl "$FM_SBXV_TTL" '{idle_seconds: $idle, lease_ttl_seconds: $ttl, expires_in_seconds: ([$ttl - $idle, 0] | max)}')
  elif lock_is_free; then
    holder=none
    extra='{}'
  else
    holder=other
    extra=$(lease_info_json)
  fi
  pos=$(queue_live | grep -c . || true)
  up=false
  [ "$LEASE_UP" = 1 ] && [ "$HOLDING" = 1 ] && up=true
  srv=null
  [ -z "$BUNDLE_URL" ] || srv=$(jq -nc --arg u "$BUNDLE_URL" --arg s "$BUNDLE_SHA" '{url: $u, sha256: $s}')
  reply "$n" ok "" "" "$(jq -nc --arg holder "$holder" --argjson up "$up" --argjson waiting "$pos" --argjson extra "$extra" --argjson bundle "$srv" '{lease: ({holder: $holder, emulator_up: $up, waiting: $waiting} + $extra), bundle: $bundle}')"
  audit exec seq "$n" verb status status ok
}

# process_request <seq> <spool-file-name>
process_request() {
  local n=$1 name=$2 src sha out rc plan verb argv_desc yaml timeout cap
  local -a argv
  REQ_ID='' REQ_VERB=''
  src="$REQ/$name"
  : >"$HOST/seen/$n"
  mkdir -p "$HOST/in"
  rm -f "$HOST/in/$n.json"
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SBX_VERIFY_TEST_HOOK:-}" ]; then
    "$FM_SBX_VERIFY_TEST_HOOK" pre-copy "$src" || true
  fi
  out=$(python3 "$IO" copy-in --src "$src" --dst "$HOST/in/$n.json" --max "$MAX_REQUEST" 2>/dev/null)
  rc=$?
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SBX_VERIFY_TEST_HOOK:-}" ]; then
    "$FM_SBX_VERIFY_TEST_HOOK" post-copy "$src" || true
  fi
  case "$rc" in
  0) sha=${out%% *} ;;
  3)
    rm -f "$HOST/seen/$n"
    return 0
    ;;
  5)
    reply "$n" rejected request_too_large "a request must be smaller than 64 KiB"
    audit request seq "$n" verdict rejected code request_too_large
    return 0
    ;;
  4)
    reply "$n" rejected not_regular "a request must be a regular file, not a link or a special file"
    audit request seq "$n" verdict rejected code not_regular
    return 0
    ;;
  *)
    reply "$n" error internal "the broker could not read the request"
    audit request seq "$n" verdict error code internal
    return 0
    ;;
  esac
  if ! plan=$(fm_sbxv_validate "$HOST/in/$n.json"); then
    REQ_ID=''
    reply "$n" rejected "$(printf '%s' "$plan" | jq -r '.code')" "$(printf '%s' "$plan" | jq -r '.message')"
    audit request seq "$n" req_sha256 "$sha" verdict rejected code "$(printf '%s' "$plan" | jq -r '.code')"
    return 0
  fi
  printf '%s\n' "$plan" >"$HOST/in/$n.plan"
  verb=$(jq -r '.verb' "$HOST/in/$n.plan")
  REQ_VERB=$verb
  REQ_ID=$(jq -r '.id // ""' "$HOST/in/$n.plan")
  audit request seq "$n" req_sha256 "$sha" verdict accepted verb "$verb"

  if [ "$verb" = status ]; then
    do_status "$n"
    return 0
  fi
  if [ "$verb" = down ] && [ "$HOLDING" = 0 ]; then
    reply "$n" ok no_lease "this task holds no verification lease; nothing was brought down"
    audit exec seq "$n" verb down status ok code no_lease
    return 0
  fi
  if ! acquire_lease; then
    reply "$n" queued busy "the verification emulator is in use by another task; ask again later" \
      "$(jq -nc --argjson pos "$(queue_position)" --argjson info "$(lease_info_json)" '{position: $pos} + $info')"
    audit exec seq "$n" verb "$verb" status queued
    return 0
  fi

  SMV_ENV=()
  argv=()
  rm -rf "$HOST/run/$n"
  mkdir -p "$HOST/run/$n/evidence"
  case "$verb" in
  up)
    LEASE_UP=1
    if [ "$(jq -r '.bundle' "$HOST/in/$n.plan")" = true ]; then
      if ! ingest_bundle "$n"; then
        reply "$n" rejected "$INGEST_CODE" "$INGEST_MSG"
        audit exec seq "$n" verb up status rejected code "$INGEST_CODE"
        return 0
      fi
      if ! start_server; then
        reply "$n" error bundle_server "the bundle could not be served on port $FM_SBXV_PORT"
        audit exec seq "$n" verb up status error code bundle_server
        return 0
      fi
      SMV_ENV=("FM_SBX_VERIFY_BUNDLE_URL=$BUNDLE_URL" "FM_SBX_VERIFY_BUNDLE_PORT=$FM_SBXV_PORT")
    fi
    argv=(up)
    ;;
  doctor | tree | down) argv=("$verb") ;;
  tab) argv=(tab "$(jq -r '.name' "$HOST/in/$n.plan")") ;;
  shot)
    argv=(shot)
    name=$(jq -r '.name // ""' "$HOST/in/$n.plan")
    [ -z "$name" ] || argv+=("$name")
    ;;
  metro-log) argv=(metro-log "$(jq -r '.lines' "$HOST/in/$n.plan")") ;;
  do | flow)
    yaml="$HOST/run/$n/flow.yaml"
    fm_sbxv_yaml "$HOST/in/$n.plan" "$FM_SBXV_APP_ID" "$HOST/run/$n/evidence" >"$yaml"
    argv=("$verb" "$yaml")
    ;;
  esac
  timeout=$(smv_timeout "$verb")
  if ! run_smv "$n" "$timeout" "${argv[@]}"; then
    reply "$n" error "${SMV_CODE:-error}" "the pinned verification command cannot be run"
    audit exec seq "$n" verb "$verb" status error code "${SMV_CODE:-error}"
    return 0
  fi
  case "$verb" in tree) cap=65536 ;; metro-log) cap=32768 ;; *) cap=16384 ;; esac
  fm_sbxv_clean "$cap" <"$HOST/run/$n/stdout" >"$HOST/run/$n/stdout.clean"
  fm_sbxv_clean 8192 <"$HOST/run/$n/stderr" >"$HOST/run/$n/stderr.clean"
  collect_evidence "$n"
  if [ "$verb" = down ] && [ "$SMV_RC" = 0 ]; then
    LEASE_UP=0
  fi
  lease_touch
  argv_desc=$(printf '%q ' "${argv[@]}")
  local st=ok code=''
  if [ "$SMV_RC" = 124 ]; then
    st=failed code=timeout
  elif [ "$SMV_RC" != 0 ]; then
    st=failed code=command_failed
  fi
  local reply_url=$BUNDLE_URL
  [ "$verb" != down ] || reply_url=''
  reply "$n" "$st" "$code" "" "$(jq -nc --argjson exit "$SMV_RC" --rawfile so "$HOST/run/$n/stdout.clean" --rawfile se "$HOST/run/$n/stderr.clean" --argjson ev "$EVIDENCE_JSON" --argjson skipped "$EVIDENCE_SKIPPED" --arg url "$reply_url" \
    '{exit: $exit, stdout: $so, stderr: $se, evidence: $ev, evidence_skipped: $skipped} + (if $url == "" then {} else {bundle_url: $url} end)')"
  audit exec seq "$n" verb "$verb" status "$st" code "$code" exit "$SMV_RC" argv "$argv_desc" smv_sha256 "$SMV_SHA" \
    flow_sha256 "$([ -f "$HOST/run/$n/flow.yaml" ] && fm_sbxv_sha256 "$HOST/run/$n/flow.yaml" || true)" \
    evidence_sha256 "$(printf '%s' "$EVIDENCE_JSON" | jq -r '[.[].sha256] | join(",")')"
  if [ "$verb" = down ]; then
    release_lease down
  fi
}

scan() {
  local f base num entry count=0
  local -a list=()
  for f in "$REQ"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    case "$base" in
    *.json) ;;
    *) continue ;;
    esac
    num=${base%.json}
    case "$num" in '' | *[!0-9]*) continue ;; esac
    [ "${#num}" -le 12 ] || continue
    list+=("$((10#$num)) $base")
  done
  [ "${#list[@]}" -gt 0 ] || return 0
  while read -r num base; do
    [ ! -e "$HOST/seen/$num" ] || continue
    process_request "$num" "$base"
    count=$((count + 1))
    [ "$count" -lt "$MAX_PER_PASS" ] || break
    [ "$STOP" = 0 ] || break
  done < <(printf '%s\n' "${list[@]}" | sort -n)
}

sandbox_gone() {
  local out
  [ -n "$SANDBOX" ] || return 1
  out=$(sbx ls -q 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -Fxq -- "$SANDBOX" && return 1
  return 0
}

finish() {
  [ "$FINISHED" = 0 ] || return 0
  FINISHED=1
  trap - EXIT
  trap : HUP TERM INT
  if [ "$HOLDING" = 1 ]; then
    release_lease "$FINISH_REASON"
  fi
  stop_server
  queue_remove
  rm -f "$HOST/broker.pid" 2>/dev/null || true
  audit broker-stop reason "$FINISH_REASON"
}
FINISH_REASON=terminated

# -------------------------------------------------------------- subcommands --

setup_paths() {
  case "$ID" in *[!A-Za-z0-9._-]* | '') die "--id must be a bare task slug" ;; esac
  case "$STATE" in /*) ;; *) die "--state must be an absolute path" ;; esac
  VDIR=$(fm_sbx_verify_dir "$STATE" "$ID")
  REQ="$VDIR/req" RES="$VDIR/res" HOST="$VDIR/host"
  KEY=$SANDBOX
  [ -n "$KEY" ] || KEY=$(printf '%s' "$ID" | tr -c 'A-Za-z0-9-' '-')
}

cmd=${1:-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
  --id) ID=${2:-}; shift 2 ;;
  --state) STATE=${2:-}; shift 2 ;;
  --config) CONFIG=${2:-}; shift 2 ;;
  --sandbox) SANDBOX=${2:-}; shift 2 ;;
  --once) ONCE=1; shift ;;
  --interval) INTERVAL=${2:-}; shift 2 ;;
  --wait) WAIT=${2:-}; shift 2 ;;
  *) die "unknown argument '$1' (see the script header)" ;;
  esac
done

case "$cmd" in
check)
  [ -n "$CONFIG" ] || die "--config is required"
  for t in jq python3 flock; do
    command -v "$t" >/dev/null 2>&1 || {
      echo "error: verify=sportsmeet needs $t on the host PATH" >&2
      exit 1
    }
  done
  fm_sbxv_load_config "$CONFIG" "$STATE" || exit 1
  exit 0
  ;;
init)
  [ -n "$ID" ] && [ -n "$STATE" ] || die "--id and --state are required"
  setup_paths
  mkdir -p "$REQ" "$RES" "$HOST" || die "could not create $VDIR"
  chmod 755 "$VDIR" "$REQ" "$RES"
  chmod 700 "$HOST"
  mkdir -p "$HOST/seen" "$HOST/run" "$HOST/in" "$HOST/bundle"
  exit 0
  ;;
run | stop) ;;
*) die "usage: fm-sbx-verify-broker.sh check|init|run|stop (see the script header)" ;;
esac

[ -n "$ID" ] && [ -n "$STATE" ] && [ -n "$CONFIG" ] || die "--id, --state and --config are required"
if [ "$cmd" = run ]; then
  [ -n "$SANDBOX" ] || die "--sandbox is required"
fi
setup_paths
[ -d "$HOST" ] || die "$HOST does not exist; run init first"
fm_sbxv_load_config "$CONFIG" "$STATE" || exit 1
LEASE_DIR=$FM_SBXV_LEASE_DIR
mkdir -p "$LEASE_DIR/queue" || die "could not create the lease directory $LEASE_DIR"

if [ "$cmd" = stop ]; then
  # The lease owner key is the sandbox name the running broker recorded.
  if [ -f "$HOST/key" ] && [ ! -L "$HOST/key" ]; then
    KEY=$(head -n 1 "$HOST/key" | tr -dc 'A-Za-z0-9-')
  fi
  pid=$(head -n 1 "$HOST/broker.pid" 2>/dev/null | tr -dc '0-9')
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
    ps -o command= -p "$pid" 2>/dev/null | grep -q 'fm-sbx-verify-broker'; then
    kill -TERM "$pid" 2>/dev/null || true
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$WAIT" ]; do
      sleep 0.2
      waited=$((waited + 1))
      [ "$waited" -lt $((WAIT * 5)) ] || break
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.2
    fi
  fi
  # A broker that was killed leaves its server and a possibly-up emulator behind.
  spid=$(head -n 1 "$HOST/server.pid" 2>/dev/null | tr -dc '0-9')
  if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null &&
    ps -o command= -p "$spid" 2>/dev/null | grep -q 'fm-sbx-verify-io'; then
    kill -TERM "$spid" 2>/dev/null || true
  fi
  rm -f "$HOST/server.pid" "$HOST/server.ready" "$HOST/broker.pid" 2>/dev/null || true
  exec 9>"$LEASE_DIR/lease.lock"
  if flock -n 9; then
    state_read
    if [ "$LS_UP" = 1 ] && [ "$LS_OWNER" = "$KEY" ]; then
      audit stale-down owner "$LS_OWNER" via stop
      forced_down "stop-$(now)" || echo "notice: the verification emulator could not be taken down; the next lease holder retries it" >&2
      rm -f "$LEASE_DIR/state"
    fi
    queue_remove
  fi
  exit 0
fi

# ------------------------------------------------------------------- run ----

mkdir -p "$HOST/seen" "$HOST/run" "$HOST/in" "$HOST/bundle"
exec 8>"$HOST/broker.lock"
flock -n 8 || die "a verification broker already runs for task $ID"
exec 9>"$LEASE_DIR/lease.lock"
printf '%s\n' "$$" >"$HOST/broker.pid"
printf '%s\n' "$KEY" >"$HOST/key"
audit broker-start sandbox "$SANDBOX" smv "$FM_SBXV_SMV" lease_ttl "$FM_SBXV_TTL"

if [ "$ONCE" = 1 ]; then
  scan
  stop_server
  exit 0
fi

trap 'STOP=1' HUP TERM INT
trap finish EXIT
SB_POLL=${FM_SBX_VERIFY_SANDBOX_POLL:-5}
SB_LAST=$(now)
while [ "$STOP" = 0 ]; do
  scan
  [ "$STOP" = 0 ] || break
  if [ "$HOLDING" = 1 ] && [ $(($(now) - LEASE_LAST)) -gt "$FM_SBXV_TTL" ]; then
    release_lease expired
  fi
  if [ $(($(now) - SB_LAST)) -ge "$SB_POLL" ]; then
    SB_LAST=$(now)
    if sandbox_gone; then
      FINISH_REASON=sandbox-gone
      break
    fi
  fi
  sleep "$INTERVAL" 8>&- 9>&- &
  wait $! 2>/dev/null || true
done
[ "$STOP" = 0 ] || FINISH_REASON=terminated
finish
