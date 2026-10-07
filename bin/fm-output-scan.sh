#!/usr/bin/env bash
# Scan text that is about to leave the fleet for secrets and the captain's personal data.
#
# Usage: fm-output-scan.sh <file|->
#        fm-output-scan.sh --diff [<base>]
#
# <file|-> scans a file, or standard input for "-". --diff scans only the lines
# a branch adds, `git diff <base>...HEAD` in the current repository; <base>
# defaults to the merge-base with origin/main (else main), and no base found
# scans every line of the HEAD tree diff against the empty tree.
#
# Exit codes: 0 clean, 1 at least one hit, 2 usage or configuration error. Any
# non-zero exit means "do not send": callers refuse on every non-zero status.
#
# On a hit the scanner prints one line per hit to stdout, `<shape> line <N>`
# (`<shape> <path>:<N>` in --diff mode), and nothing else. It NEVER prints the
# matched text, so the scan itself cannot leak a secret into a log, a status line,
# or a worker's context. It does not redact or rewrite anything.
#
# Secret shapes, always on: aws-key-id, github-token, anthropic-key, openai-key,
# slack-token, private-key, jwt, bearer-header, secret-assignment.
# Personal-data shapes, driven ONLY by the captain-maintained deny-list
# $FM_CONFIG_OVERRIDE|$FM_HOME/config/output-scan-deny.txt, because emails, phone
# numbers and home paths false-positive on ordinary work. One entry per line;
# blank lines and lines starting with '#' are ignored; matching is
# case-insensitive. An entry that contains '@' reports as `email`, one made only of
# digits and phone punctuation with at least seven digits reports as `phone` and
# matches however its digits are spaced and with or without a country code (only its last
# ten digits are compared), one containing /home/ or /Users/ reports as
# `home-path`, and anything else (a name, a street address, an employer string)
# reports as `personal-term`. An absent file means no personal-data rules; an
# unreadable file or an entry shorter than three characters is a configuration
# error (exit 2), never a silent pass.
#
# Honest limit: this is a pattern scan. It stops accidental pastes, not a worker
# that deliberately splits, encodes, or obfuscates what it sends.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DENY_FILE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/output-scan-deny.txt"

usage() {
  echo "usage: fm-output-scan.sh <file|->" >&2
  echo "       fm-output-scan.sh --diff [<base>]" >&2
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-output-scan.XXXXXX") || {
  echo "fm-output-scan: cannot create temp dir" >&2
  exit 2
}
trap 'rm -rf "$WORK"' EXIT
TEXT="$WORK/text"
MAP="$WORK/map"
HITS="$WORK/hits"
: >"$HITS"

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --diff)
    [ "$#" -le 2 ] || { usage; exit 2; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "fm-output-scan: --diff needs a git repository" >&2; exit 2; }
    BASE=${2:-}
    if [ -z "$BASE" ]; then
      for ref in origin/main main; do
        if git rev-parse --verify -q "$ref" >/dev/null 2>&1; then
          BASE=$(git merge-base "$ref" HEAD 2>/dev/null) && break
          BASE=
        fi
      done
    fi
    [ -n "$BASE" ] || BASE=$(git hash-object -t tree /dev/null)
    git diff -U0 --no-color --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ "$BASE" HEAD >"$WORK/diff" 2>/dev/null || {
      echo "fm-output-scan: cannot read git diff against $BASE" >&2
      exit 2
    }
    awk -v text="$TEXT" -v map="$MAP" '
      /^diff --git / { path = ""; in_hunk = 0; next }
      !in_hunk && /^\+\+\+ (b\/|\/dev\/null)/ { path = substr($0, 7); if ($0 == "+++ /dev/null") path = ""; next }
      !in_hunk && /^--- (a\/|\/dev\/null)/ { next }
      /^@@ / {
        in_hunk = 1
        s = $3; sub(/^\+/, "", s); sub(/,.*/, "", s); n = s + 0; next
      }
      /^\+/ && path != "" { print substr($0, 2) > text; print path ":" n > map; n++ }
    ' "$WORK/diff"
    : >>"$TEXT"
    : >>"$MAP"
    ;;
  -)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    cat >"$TEXT" || { echo "fm-output-scan: cannot read standard input" >&2; exit 2; }
    ;;
  ''|-*) usage; exit 2 ;;
  *)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    [ -f "$1" ] && [ -r "$1" ] || { echo "fm-output-scan: cannot read file: $1" >&2; exit 2; }
    cp -- "$1" "$TEXT" || { echo "fm-output-scan: cannot read file: $1" >&2; exit 2; }
    ;;
esac

# record_hits <shape> <grep-output-with-n-and-o> [validator]
# Keeps only the line number of each match; the matched text is read into a shell
# variable for the optional validator and is never written anywhere.
record_hits() {
  local shape=$1 rec line match
  while IFS= read -r rec; do
    line=${rec%%:*}
    match=${rec#*:}
    if [ "${3:-}" = digit-value ]; then
      case "${match#*[:=]}" in *[0-9]*) ;; *) continue ;; esac
    fi
    printf '%s %s\n' "$line" "$shape" >>"$HITS"
  done <<<"$2"
}

# run_scan_grep <grep-args-after-"-a -n -o">: sets GREP_OUT, returns 0 for a
# match or 1 for none; a grep failure (exit > 1) exits the script with 2.
run_scan_grep() {
  local rc
  GREP_OUT=$(grep -a -n -o "$@" "$TEXT" 2>/dev/null)
  rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "fm-output-scan: grep failed (exit $rc) while scanning" >&2
    exit 2
  fi
  [ "$rc" -eq 0 ]
}

scan() {
  local shape=$1 regex=$2 flags=${3:--E} validator=${4:-}
  run_scan_grep "$flags" -e "$regex" || return 0
  record_hits "$shape" "$GREP_OUT" "$validator"
}

B='(^|[^A-Za-z0-9])'
scan aws-key-id "${B}(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[0-9A-Z]{16}([^A-Za-z0-9]|\$)"
scan github-token "${B}(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"
scan anthropic-key "${B}sk-ant-[A-Za-z0-9_-]{20,}"
scan openai-key "${B}sk-([B-Zb-z0-9_-]|[Aa][^Nn]|[Aa][Nn][^Tt]|[Aa][Nn][Tt][^-])[A-Za-z0-9_-]{30,}"
scan slack-token "${B}(xox[abprs]-[A-Za-z0-9-]{10,}|xapp-[0-9]-[A-Za-z0-9-]{10,})"
scan private-key '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----'
scan jwt "${B}eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"
scan bearer-header 'bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}' -Ei
scan secret-assignment "(api[_-]?key|secret|token|passw(or)?d|credential|access[_-]?key|private[_-]?key)[A-Za-z0-9_]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+_.~=-]{16,}" -Ei digit-value

if [ -e "$DENY_FILE" ]; then
  [ -f "$DENY_FILE" ] && [ -r "$DENY_FILE" ] || {
    echo "fm-output-scan: cannot read deny-list: $DENY_FILE" >&2
    exit 2
  }
  entry_no=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry_no=$((entry_no + 1))
    entry=${entry%$'\r'}
    case "$entry" in ''|'#'*) continue ;; esac
    if [ "${#entry}" -lt 3 ]; then
      echo "fm-output-scan: deny-list entry on line $entry_no is shorter than three characters" >&2
      exit 2
    fi
    shape=
    phone_chars='^[-0-9+ ().]+$'
    case "$entry" in
      *@*) shape=email ;;
      *) [[ $entry =~ $phone_chars ]] && shape=phone ;;
    esac
    case "$entry" in
      */home/*|*/Users/*|*/home|*/Users) [ -n "$shape" ] || shape=home-path ;;
    esac
    if [ "$shape" = phone ]; then
      digits=${entry//[!0-9]/}
      if [ "${#digits}" -lt 7 ]; then
        echo "fm-output-scan: deny-list phone entry on line $entry_no has fewer than seven digits" >&2
        exit 2
      fi
      [ "${#digits}" -le 10 ] || digits=${digits: -10}
      regex=$(printf '%s' "$digits" | sed 's/./&[^0-9]*/g; s/\[\^0-9\]\*$//')
      run_scan_grep -E -e "$regex" || continue
    else
      [ -n "$shape" ] || shape=personal-term
      run_scan_grep -i -F -e "$entry" || continue
    fi
    record_hits "$shape" "$GREP_OUT"
  done <"$DENY_FILE"
fi

# A key that matches the specific anthropic-key shape is not also an openai-key.
sort -t' ' -k1,1n -k2,2 -u "$HITS" >"$HITS.sorted"
ANTHROPIC_LINES=$(awk '$2 == "anthropic-key" { print $1 }' "$HITS.sorted")
HIT_COUNT=0
while read -r line shape; do
  if [ "$shape" = openai-key ] && grep -qx "$line" <<<"$ANTHROPIC_LINES"; then
    continue
  fi
  HIT_COUNT=$((HIT_COUNT + 1))
  if [ -s "$MAP" ]; then
    loc=$(sed -n "${line}p" "$MAP")
    printf '%s %s\n' "$shape" "$loc"
  else
    printf '%s line %s\n' "$shape" "$line"
  fi
done <"$HITS.sorted"

[ "$HIT_COUNT" -eq 0 ] || exit 1
exit 0
