# shellcheck shell=bash
# shellcheck disable=SC2034 # the FM_SBXV_* results are read by the sourcing script
# Shared helpers of the host-side verification broker (bin/fm-sbx-verify-broker.sh).
#
# Usage: . bin/fm-sbx-verify-lib.sh
#
# This file owns three things: the host-owned config/sbx-verify grammar, the
# request validator with its host-owned selector denylist, and the generator
# that turns a validated step list into Maestro YAML.
# docs/sbx-verify-broker.md owns the request and result protocol these
# functions enforce, and docs/configuration.md "Worker sandbox" the operator
# schema.
#
# Nothing here reads a path from a worker; a request is JSON bytes the broker
# already copied into a host-only directory.
# The validator is an allowlist: a verb, a step, a key or a value that is not
# named below is rejected, and text entry (inputText, pressKey) is not named.
#
# Value grammar of config/sbx-verify, one `key=value` per line, `#` comments:
#   sm-verify=/abs/path     required: the pinned host verification command,
#                           a regular executable that is not inside any
#                           sandbox clone or this home's state directory
#   sm-verify-sha256=HEX    optional: refuse to run when the file's digest differs
#   app-id=ID               required: the app id written into generated flows
#   bundle-port=N           the broker-owned port the one bundle file is served
#                           on (default 8081)
#   bundle-bind=ADDR        the address that port binds (default 127.0.0.1)
#   lease-ttl=SECS          idle seconds before the lease is taken back
#                           (default 1200)
#   queue-ttl=SECS          seconds a waiting second holder stays queued without
#                           asking again (default 180)
#   lease-dir=/abs/path     the lease every home sharing the emulator must share
#                           (default <config>/sbx-verify.d)

FM_SBXV_SMV='' FM_SBXV_SMV_SHA='' FM_SBXV_APP_ID=''
FM_SBXV_PORT=8081 FM_SBXV_BIND=127.0.0.1 FM_SBXV_TTL=1200 FM_SBXV_QTTL=180 FM_SBXV_LEASE_DIR=''

# Host-owned selector denylist: a tap whose text or id contains any of these,
# after the normalization in the validator, is refused.
# It is a substring match on purpose, so `Passport` and `Saved` are refused too.
FM_SBXV_DENY=(
  "sign in" "signin" "continue with" "google" "apple"
  "like" "pass" "send" "join" "leave" "cancel" "create" "save" "delete"
  "block" "report" "waitlist"
  "i'm here" "no, i'm not" "yes, i'm"
)

fm_sbxv_sha256() { # <file> -> lowercase hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fm_sbxv_realpath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# fm_sbxv_load_config <config-dir> <state-dir>
# Parse <config-dir>/sbx-verify into the FM_SBXV_* variables and check the
# pinned command.
# A missing or malformed value prints the refusal to stderr and returns 1.
fm_sbxv_load_config() {
  local cdir=$1 state=$2 file line key val real
  file="$cdir/sbx-verify"
  FM_SBXV_SMV='' FM_SBXV_SMV_SHA='' FM_SBXV_APP_ID=''
  FM_SBXV_PORT=8081 FM_SBXV_BIND=127.0.0.1 FM_SBXV_TTL=1200 FM_SBXV_QTTL=180
  FM_SBXV_LEASE_DIR="$cdir/sbx-verify.d"
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    echo "error: verify=app needs the host file config/sbx-verify (a regular file holding sm-verify=/absolute/path)" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
    *=*) ;;
    *)
      echo "error: config/sbx-verify line '$line' is not key=value" >&2
      return 1
      ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
    sm-verify) FM_SBXV_SMV=$val ;;
    sm-verify-sha256)
      case "$val" in
      '' | *[!0-9a-f]*) echo "error: config/sbx-verify sm-verify-sha256 takes 64 lowercase hex digits" >&2; return 1 ;;
      esac
      [ "${#val}" -eq 64 ] || { echo "error: config/sbx-verify sm-verify-sha256 takes 64 lowercase hex digits" >&2; return 1; }
      FM_SBXV_SMV_SHA=$val
      ;;
    app-id)
      case "$val" in '' | *[!A-Za-z0-9_.]*) echo "error: config/sbx-verify app-id takes letters, digits, dot and underscore" >&2; return 1 ;; esac
      FM_SBXV_APP_ID=$val
      ;;
    bundle-port)
      case "$val" in '' | *[!0-9]* | 0*) echo "error: config/sbx-verify bundle-port takes a port number" >&2; return 1 ;; esac
      [ "${#val}" -le 5 ] && [ "$val" -le 65535 ] || { echo "error: config/sbx-verify bundle-port takes a port number" >&2; return 1; }
      FM_SBXV_PORT=$val
      ;;
    bundle-bind)
      case "$val" in '' | *[!0-9a-fA-F.:]*) echo "error: config/sbx-verify bundle-bind takes an IP address" >&2; return 1 ;; esac
      FM_SBXV_BIND=$val
      ;;
    lease-ttl)
      case "$val" in '' | *[!0-9]* | 0*) echo "error: config/sbx-verify lease-ttl takes whole seconds" >&2; return 1 ;; esac
      FM_SBXV_TTL=$val
      ;;
    queue-ttl)
      case "$val" in '' | *[!0-9]* | 0*) echo "error: config/sbx-verify queue-ttl takes whole seconds" >&2; return 1 ;; esac
      FM_SBXV_QTTL=$val
      ;;
    lease-dir)
      case "$val" in /*) ;; *) echo "error: config/sbx-verify lease-dir must be an absolute path" >&2; return 1 ;; esac
      FM_SBXV_LEASE_DIR=$val
      ;;
    *)
      echo "error: config/sbx-verify holds the unknown key '$key'" >&2
      return 1
      ;;
    esac
  done <"$file"
  case "$FM_SBXV_SMV" in
  /*) ;;
  *)
    echo "error: config/sbx-verify needs sm-verify=/absolute/path" >&2
    return 1
    ;;
  esac
  if [ -z "$FM_SBXV_APP_ID" ]; then
    echo "error: config/sbx-verify needs app-id=ID (letters, digits, dot and underscore)" >&2
    return 1
  fi
  real=$(fm_sbxv_realpath "$FM_SBXV_SMV" 2>/dev/null) || real=''
  if [ -z "$real" ] || [ ! -f "$real" ] || [ ! -x "$real" ]; then
    echo "error: config/sbx-verify sm-verify '$FM_SBXV_SMV' is not an executable regular file" >&2
    return 1
  fi
  case "$real/" in
  *.sbx-clone/* | *.sbx-verify/* | *.sbx/*)
    echo "error: config/sbx-verify sm-verify must be a host-owned file, not a path inside a sandbox clone or channel" >&2
    return 1
    ;;
  esac
  if [ -n "$state" ]; then
    case "$real/" in
    "$(fm_sbxv_realpath "$state")"/*)
      echo "error: config/sbx-verify sm-verify must not live in the firstmate state directory" >&2
      return 1
      ;;
    esac
  fi
  FM_SBXV_SMV=$real
  if [ -n "$FM_SBXV_SMV_SHA" ] && [ "$(fm_sbxv_sha256 "$real")" != "$FM_SBXV_SMV_SHA" ]; then
    echo "error: config/sbx-verify sm-verify does not match sm-verify-sha256" >&2
    return 1
  fi
}

# fm_sbxv_clean <max-bytes>: stdin -> stdout without control bytes (newline and
# tab stay), cut to the byte cap.
fm_sbxv_clean() { LC_ALL=C tr -d '\000-\010\013-\037\177' | head -c "$1"; }

read -r -d '' FM_SBXV_JQ_VALIDATE <<'JQ' || true
def die($c; $m): error($c + "|" + $m);
def norm:
  ascii_downcase
  | gsub("[‘’ʼ`´]"; "'")
  | gsub("[-_.]+"; " ")
  | gsub("\\s+"; " ")
  | sub("^ "; "") | sub(" $"; "");
def denied($s): ($s | norm) as $n | any($deny[]; . as $d | $n | contains($d));
def selector($check):
  if type != "object" then die("bad_step"; "a selector is an object holding text or id")
  elif (keys | sort) == ["text"] then
    if (.text | type) == "string" and (.text | test("^[ -~‘’]{1,80}$")) then
      (if $check and denied(.text) then die("denied_selector"; "that text names a control the broker never taps") else {kind: "text", value: .text} end)
    else die("bad_step"; "selector text is 1-80 printable ASCII characters") end
  elif (keys | sort) == ["id"] then
    if (.id | type) == "string" and (.id | test("^[A-Za-z0-9_.:/-]{1,80}$")) then
      (if $check and denied(.id) then die("denied_selector"; "that id names a control the broker never taps") else {kind: "id", value: .id} end)
    else die("bad_step"; "selector id is 1-80 characters of letters, digits and _.:/-") end
  else die("bad_step"; "a selector has exactly one of text or id") end;
def forbidden: ["inputText", "pressKey", "runScript", "evalScript", "runFlow", "openLink", "launchApp", "stopApp", "clearState", "clearKeychain", "addMedia", "copyTextFrom", "setLocation", "eraseText", "pasteText", "repeat", "retry", "assertTrue", "assertWithAI", "startRecording", "stopRecording", "travel", "setAirplaneMode", "toggleAirplaneMode", "killApp", "setOrientation", "onFlowStart", "onFlowComplete", "appId", "env", "tags", "name", "properties", "jsEngine", "androidWebViewHierarchy", "onFlowStart", "url"];
def step:
  if type != "object" or length != 1 then die("bad_step"; "a step is an object with exactly one key")
  else
    (keys[0]) as $k | .[$k] as $a
    | if $k == "tapOn" then {op: $k, sel: ($a | selector(true))}
      elif $k == "assertVisible" or $k == "assertNotVisible" then {op: $k, sel: ($a | selector(false))}
      elif $k == "scroll" or $k == "back" or $k == "hideKeyboard" or $k == "waitForAnimationToEnd" then
        (if $a == {} or $a == null then {op: $k} else die("bad_step"; $k + " takes no arguments") end)
      elif $k == "swipe" then
        (if ($a | type) == "object" and ($a | keys) == ["direction"] and ($a.direction | IN("UP", "DOWN", "LEFT", "RIGHT")) then {op: $k, direction: $a.direction} else die("bad_step"; "swipe takes direction UP, DOWN, LEFT or RIGHT") end)
      elif $k == "extendedWaitUntil" then
        (if ($a | type) == "object" and ($a | has("visible")) and (($a | keys) - ["visible", "timeout"]) == [] then
           ($a.timeout // 10000) as $t
           | if ($t | type) == "number" and $t >= 1 and $t <= 30000 and $t == ($t | floor) then {op: $k, sel: ($a.visible | selector(false)), timeout: $t} else die("bad_step"; "extendedWaitUntil timeout is 1-30000 milliseconds") end
         else die("bad_step"; "extendedWaitUntil takes visible and an optional timeout") end)
      elif $k == "takeScreenshot" then
        (if ($a | type) == "object" and ($a | keys) == ["name"] and ($a.name | type) == "string" and ($a.name | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$")) then {op: $k, name: $a.name} else die("bad_step"; "takeScreenshot takes a name of 1-40 letters, digits, _ and -") end)
      elif (forbidden | index($k)) != null then die("forbidden_step"; "the step '" + $k + "' is never allowed")
      else die("bad_step"; "the step '" + ($k | .[0:40]) + "' is not in the allowlist") end
  end;
def allowed($v):
  if $v == "up" then ["verb", "id", "bundle"]
  elif $v == "tab" or $v == "shot" then ["verb", "id", "name"]
  elif $v == "metro-log" then ["verb", "id", "lines"]
  elif $v == "do" then ["verb", "id", "step"]
  elif $v == "flow" then ["verb", "id", "steps"]
  else ["verb", "id"] end;
def main:
  if type != "object" then die("bad_request"; "the request must be a JSON object") else . end
  | . as $r
  | ($r.verb // "") as $v
  | if ($v | type) != "string" or (["up", "doctor", "tab", "shot", "tree", "status", "metro-log", "down", "do", "flow"] | index($v)) == null then die("unknown_verb"; "the verb is not one of up, doctor, tab, shot, tree, status, metro-log, down, do, flow") else . end
  | (($r | keys) - allowed($v)) as $extra
  | if ($extra | length) > 0 then die("bad_request"; "the key '" + ($extra[0] | .[0:40]) + "' is not accepted for " + $v) else . end
  | if ($r | has("id")) and (($r.id | type) != "string" or ($r.id | test("^[A-Za-z0-9_.-]{1,64}$") | not)) then die("bad_request"; "id is 1-64 characters of letters, digits, _ . and -") else . end
  | {ok: true, verb: $v, id: ($r.id // null)}
  | if $v == "up" then
      (if ($r | has("bundle")) and ($r.bundle | type) != "boolean" then die("bad_request"; "bundle is true or false") else . end)
      | . + {bundle: ($r.bundle // false)}
    elif $v == "tab" then
      (if ($r.name | type) == "string" and ($r.name | test("^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$")) then
         (if denied($r.name) then die("denied_selector"; "that tab name names a control the broker never taps") else . + {name: $r.name} end)
       else die("bad_request"; "tab takes a name of 1-40 letters, digits, space, _ and -") end)
    elif $v == "shot" then
      (if ($r | has("name")) then
         (if ($r.name | type) == "string" and ($r.name | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$")) then . + {name: $r.name} else die("bad_request"; "shot takes an optional name of 1-40 letters, digits, _ and -") end)
       else . + {name: null} end)
    elif $v == "metro-log" then
      ($r.lines // 100) as $l
      | (if ($l | type) == "number" and $l >= 1 and $l <= 500 and $l == ($l | floor) then . + {lines: $l} else die("bad_request"; "lines is a whole number from 1 to 500") end)
    elif $v == "do" then
      (if ($r | has("step")) then . + {steps: [$r.step | step]} else die("bad_request"; "do takes one step") end)
    elif $v == "flow" then
      (if ($r.steps | type) == "array" and ($r.steps | length) >= 1 and ($r.steps | length) <= 40 then . + {steps: [$r.steps[] | step]} else die("bad_request"; "flow takes 1 to 40 steps") end)
    else . end;
try main catch (
  if type == "string" and test("^[a-z_]+\\|") then
    {ok: false, code: (split("|")[0]), message: (.[(index("|") + 1):])}
  else
    {ok: false, code: "bad_request", message: "the request does not have the expected shape"}
  end)
JQ

# fm_sbxv_validate <request-file>
# Print one JSON object on stdout: {"ok":true,"verb":...} with the normalized
# request, or {"ok":false,"code":...,"message":...}; return 0 for the former.
# Invalid JSON is code malformed_json.
fm_sbxv_validate() {
  local file=$1 deny out
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf '{"ok":false,"code":"malformed_json","message":"the request is not valid JSON"}\n'
    return 1
  fi
  deny=$(printf '%s\n' "${FM_SBXV_DENY[@]}" | jq -R . | jq -sc .)
  out=$(jq -c --argjson deny "$deny" "$FM_SBXV_JQ_VALIDATE" "$file" 2>/dev/null) || out=''
  if [ -z "$out" ]; then
    printf '{"ok":false,"code":"bad_request","message":"the request does not have the expected shape"}\n'
    return 1
  fi
  printf '%s\n' "$out"
  [ "$(printf '%s' "$out" | jq -r '.ok')" = true ]
}

read -r -d '' FM_SBXV_JQ_YAML <<'JQ' || true
def esc: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}])"; "\\" + .c);
def sel($s; $pad): $pad + $s.kind + ": " + ($s.value | esc | @json);
def emit:
  if .op == "tapOn" or .op == "assertVisible" or .op == "assertNotVisible" then
    "- " + .op + ":", sel(.sel; "    ")
  elif .op == "swipe" then
    "- swipe:", "    direction: " + .direction
  elif .op == "extendedWaitUntil" then
    "- extendedWaitUntil:", "    visible:", sel(.sel; "      "), "    timeout: " + (.timeout | tostring)
  elif .op == "takeScreenshot" then
    "- takeScreenshot: " + ($ev + "/" + .name | @json)
  else "- " + .op end;
"appId: " + $app, "---", (.steps[] | emit)
JQ

# fm_sbxv_yaml <validated-json-file> <app-id> <evidence-dir>
# Print the Maestro flow for a validated do or flow request.
# Every string is a JSON-quoted scalar, which is also a valid YAML scalar, and
# selectors are regex-escaped so they match the literal text only.
# Only the keys written in this function ever reach the YAML.
fm_sbxv_yaml() {
  jq -r --arg app "$2" --arg ev "$3" "$FM_SBXV_JQ_YAML" "$1"
}
