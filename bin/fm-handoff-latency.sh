#!/usr/bin/env bash
# fm-handoff-latency.sh - read-only report of where time went in the handoffs
# between workers and firstmate, worst gap first.
#
# Usage:
#   fm-handoff-latency.sh [--task <id>] [--since <seconds>] [--limit <n>] [--min <seconds>]
#   fm-handoff-latency.sh --help
#
# A handoff has two directions, and each is a chain of timestamps already on
# disk. Worker to firstmate:
#   event->wake      a worker status line ([at=]) to the wake row it caused
#   wake->shown      the row queued to the drain presenting it to firstmate
#   shown->handled   presented to acknowledged (firstmate's own handling time)
#   wake unhandled   a row still queued now, with how long it has waited
# Firstmate to worker:
#   steer->worker-ack  a steering inbox message (its at= header) to the worker
#                      moving it into handled/ (the rename's ctime)
#   steer unacked      a message still waiting in the inbox now
# The wake stages come from the handoff journal ($STATE/.handoff-journal,
# bin/fm-handoff-journal-lib.sh owns it): the queue deletes a row at
# acknowledgement, so the journal is the one record kept for this report. The
# steering stages come from the inbox files themselves, and the first stage from
# the status logs.
#
# OUTPUT: a one-line header (window, watcher beat age), the worst gaps, then a
# per-stage summary (count, median, max). Gaps under --min seconds (default 5)
# are left out of the worst list. --since is the look-back window in seconds
# (default 86400); --limit caps the worst list (default 15); --task narrows
# everything to one task id. With no records the report says so and names where
# the records come from.
#
# Read-only and side-effect free. Always exits 0 after a successful read; exit 2
# on a usage error.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  printf 'usage: fm-handoff-latency.sh [--task ID] [--since SECONDS] [--limit N] [--min SECONDS]\n'
  printf 'Prints where time went between workers and firstmate, worst gap first: status event to wake, wake to presented, presented to handled, steer to worker acknowledgement, plus anything still waiting.\n'
  printf 'example: bin/fm-handoff-latency.sh --since 3600 --limit 10\n'
}

TASK=
SINCE=86400
LIMIT=15
MIN=5
need_num() { # <flag> <value>
  case "$2" in
    ''|*[!0-9]*) printf 'fm-handoff-latency: %s needs a whole number of seconds, got "%s"\n' "$1" "$2" >&2; usage >&2; exit 2 ;;
  esac
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TASK=$2; shift 2 ;;
    --since) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; need_num --since "$2"; SINCE=$2; shift 2 ;;
    --limit) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; need_num --limit "$2"; LIMIT=$2; shift 2 ;;
    --min) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; need_num --min "$2"; MIN=$2; shift 2 ;;
    *) printf 'fm-handoff-latency: unknown argument "%s"\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

NOW=$(date +%s)
CUTOFF=$((NOW - SINCE))
UNAME=$(uname 2>/dev/null || echo unknown)
JOURNAL="$STATE/.handoff-journal"

file_mtime() {
  if [ "$UNAME" = Darwin ]; then /usr/bin/stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}
file_ctime() {
  if [ "$UNAME" = Darwin ]; then /usr/bin/stat -f %c "$1" 2>/dev/null; else stat -c %Z "$1" 2>/dev/null; fi
}
clock() { # <epoch>
  date -d "@$1" +%H:%M:%S 2>/dev/null || date -r "$1" +%H:%M:%S 2>/dev/null || printf '%s' "$1"
}
human() { # <seconds>
  local s=$1
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}
clean() { LC_ALL=C tr '\t\r\n' '   ' | cut -c1-70; }

ROWS=$(mktemp "${TMPDIR:-/tmp}/fm-handoff-latency.XXXXXX") || exit 1
trap 'rm -f "$ROWS"' EXIT
# Row format: gap<TAB>stage<TAB>task<TAB>when<TAB>detail
add_row() { # <gap> <stage> <task> <when> <detail>
  [ -z "$TASK" ] || [ "$3" = "$TASK" ] || return 0
  [ "$4" -ge "$CUTOFF" ] || return 0
  [ "$1" -ge 0 ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$ROWS"
}

# Latest status event at or before <epoch> for <task>: prints "<at>\t<text>".
status_event_before() { # <task> <epoch>
  local log="$STATE/$1.status"
  [ -f "$log" ] || return 1
  awk -v limit="$2" '
    match($0, /\[at=[0-9]+\]/) {
      at = substr($0, RSTART + 4, RLENGTH - 5) + 0
      if (at <= limit && at >= best) { best = at; text = $0 }
    }
    END { if (best > 0) printf "%s\t%s\n", best, text }
  ' "$log"
}

records=0
# --- wake stages from the journal -------------------------------------------
if [ -s "$JOURNAL" ]; then
  # one line per acked wake: seq task kind key queued presented-ms acked-ms
  JOINED=$(awk -F '\t' '
    $1 != "v1" || $3 == "nudge" { next }
    $3 == "presented" {
      if (!($5 in pms)) { pms[$5] = $2; pq[$5] = $8; pk[$5] = $6 SUBSEP $7; ptask[$5] = $4 }
      kk = $6 SUBSEP $7
      pkseq[kk] = pkseq[kk] " " $5
      next
    }
    $3 == "acked" { if (!($5 in ams)) { ams[$5] = $2; aq[$5] = $8; ak[$5] = $6; akey[$5] = $7; atask[$5] = $4 } }
    END {
      for (s in ams) {
        kk = ak[s] SUBSEP akey[s]
        shown = ""
        if (s in pms) shown = pms[s]
        else {
          n = split(pkseq[kk], cand, " ")
          for (i = 1; i <= n; i++) if (cand[i] + 0 >= s + 0 && (shown == "" || pms[cand[i]] + 0 < shown + 0)) shown = pms[cand[i]]
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s, atask[s], ak[s], akey[s], aq[s], shown, ams[s]
      }
    }
  ' "$JOURNAL" 2>/dev/null)
  while IFS=$'\t' read -r seq task kind key queued shown_ms acked_ms; do
    [ -n "${seq:-}" ] || continue
    case "$queued" in ''|*[!0-9]*) continue ;; esac
    records=$((records + 1))
    acked=$((acked_ms / 1000))
    detail="$kind $key"
    if [ "$kind" = signal ] && ev=$(status_event_before "$task" "$queued") && [ -n "$ev" ]; then
      at=${ev%%$'\t'*}
      text=$(printf '%s' "${ev#*$'\t'}" | clean)
      [ $((queued - at)) -gt 3600 ] || add_row $((queued - at)) 'event->wake' "$task" "$at" "$text"
    fi
    if [ -n "$shown_ms" ]; then
      shown=$((shown_ms / 1000))
      add_row $((shown - queued)) 'wake->shown' "$task" "$queued" "$detail"
      add_row $((acked - shown)) 'shown->handled' "$task" "$shown" "$detail"
    else
      add_row $((acked - queued)) 'queued->handled' "$task" "$queued" "$detail"
    fi
  done <<EOF
$JOINED
EOF
fi

# --- wakes still waiting in the queue ----------------------------------------
if [ -s "$STATE/.wake-queue" ]; then
  while IFS=$'\t' read -r epoch seq kind key _payload; do
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$kind" != heartbeat ] || continue
    records=$((records + 1))
    task=${key%.status}; task=${task%.turn-ended}
    add_row $((NOW - epoch)) wake-unhandled "$task" "$epoch" "$kind $key (queued, not yet acknowledged)"
  done <"$STATE/.wake-queue"
fi

# --- steering messages --------------------------------------------------------
msg_at() { # <file> -> epoch from the at= ISO header
  local iso
  iso=$(sed -n 's/^at=//p' "$1" 2>/dev/null | head -n 1)
  [ -n "$iso" ] || return 1
  date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null
}
for inbox in "$STATE"/*.inbox; do
  [ -d "$inbox" ] || continue
  task=${inbox##*/}; task=${task%.inbox}
  [ -z "$TASK" ] || [ "$task" = "$TASK" ] || continue
  for msg in "$inbox"/*.msg; do
    [ -f "$msg" ] || continue
    sent=$(msg_at "$msg") || continue
    records=$((records + 1))
    add_row $((NOW - sent)) steer-unacked "$task" "$sent" "${msg##*/} waiting in the inbox"
  done
  for msg in "$inbox"/handled/*.msg; do
    [ -f "$msg" ] || continue
    sent=$(msg_at "$msg") || continue
    handled=$(file_ctime "$msg") || continue
    records=$((records + 1))
    add_row $((handled - sent)) 'steer->worker-ack' "$task" "$sent" "${msg##*/}"
  done
done

# --- watcher beacon ------------------------------------------------------------
beat_line="watcher beat: never seen (state/.last-watcher-beat is absent)"
if beat=$(file_mtime "$STATE/.last-watcher-beat") && [ -n "$beat" ]; then
  beat_line="watcher beat: $(human $((NOW - beat))) ago"
fi

window=$(human "$SINCE")
printf 'handoff latency  window=%s%s  now=%s\n' "$window" "${TASK:+  task=$TASK}" "$(clock "$NOW")"
printf '%s\n' "$beat_line"

if [ "$records" -eq 0 ] || [ ! -s "$ROWS" ]; then
  if [ "$records" -eq 0 ]; then
    printf '\nno handoff records yet\n'
    printf 'records come from the wake drain (%s), worker status logs and steering inboxes under %s; run firstmate for a while and ask again\n' "$JOURNAL" "$STATE"
  else
    printf '\nno gaps in the window (%s records, none over %ss)\n' "$records" "$MIN"
  fi
  exit 0
fi

printf '\nWORST GAPS\n'
printf '  %-8s %-16s %-24s %-9s %s\n' GAP STAGE TASK WHEN DETAIL
sort -t "$(printf '\t')" -k1,1nr "$ROWS" | awk -F '\t' -v min="$MIN" -v limit="$LIMIT" '$1 + 0 >= min && n < limit { n++; print }' |
  while IFS=$'\t' read -r gap stage task when detail; do
    printf '  %-8s %-16s %-24s %-9s %s\n' "$(human "$gap")" "$stage" "${task:0:24}" "$(clock "$when")" "$detail"
  done

printf '\nBY STAGE\n'
printf '  %-16s %6s %8s %8s\n' STAGE COUNT MEDIAN MAX
for stage in 'event->wake' 'wake->shown' 'shown->handled' 'queued->handled' 'wake-unhandled' 'steer->worker-ack' 'steer-unacked'; do
  stats=$(awk -F '\t' -v st="$stage" '$2 == st { v[++n] = $1 + 0 } END {
    if (n == 0) exit
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
    printf "%d %d %d\n", n, v[int((n + 1) / 2)], v[n]
  }' "$ROWS")
  [ -n "$stats" ] || continue
  read -r cnt med max <<EOF
$stats
EOF
  printf '  %-16s %6s %8s %8s\n' "$stage" "$cnt" "$(human "$med")" "$(human "$max")"
done
exit 0
