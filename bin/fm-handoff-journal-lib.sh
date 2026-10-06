#!/usr/bin/env bash
# fm-handoff-journal-lib.sh - the single owner of the handoff journal, the
# durable record of when a wake reached firstmate and when it was handled.
#
# Sourced, never executed. bin/fm-handoff-latency.sh reads it.
#
# WHY. The wake queue deletes a row at acknowledgement, so once a wake is
# handled nothing recorded how long it waited to be presented or handled. The
# journal keeps that one fact the other records lose; everything else the
# latency command prints (status event times, turn-end touches, steering inbox
# messages and their acknowledgement) is derived from records that already exist.
#
# FILE: $STATE/.handoff-journal, one tab-separated line per event, appended
# with O_APPEND so concurrent writers interleave whole lines:
#   v1 <TAB> epoch-ms <TAB> event <TAB> task <TAB> seq <TAB> kind <TAB> key <TAB> queued-epoch
# event is `presented` (the drain printed the row to firstmate), `acked` (the
# acknowledgement consumed it) or `nudge` (the watcher sent a worker the
# reattach nudge for a parked run). queued-epoch is the row's own epoch, so a
# reader needs no join against a queue that no longer holds the row.
#
# INERT. A failed append is discarded: losing a diagnostic line must never
# change what the drain or the watcher does or how it exits. The file is
# trimmed to its newest FM_HANDOFF_JOURNAL_KEEP lines when it passes twice that,
# so it never grows without bound.
set -u

FM_HANDOFF_JOURNAL_KEEP=${FM_HANDOFF_JOURNAL_KEEP:-2000}

fm_hj_path() {
  printf '%s\n' "${STATE:-${FM_HOME:-.}/state}/.handoff-journal"
}

fm_hj_now_ms() {
  local raw sec frac
  raw=${EPOCHREALTIME:-}
  case "$raw" in
    *[0-9][.,][0-9]*)
      sec=${raw%%[.,]*}
      frac="${raw#*[.,]}000"
      frac=${frac:0:3}
      case "$sec$frac" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$((sec * 1000 + 10#$frac))"; return 0 ;;
      esac
      ;;
  esac
  sec=$(date +%s 2>/dev/null || printf '0')
  case "$sec" in ''|*[!0-9]*) sec=0 ;; esac
  printf '%s\n' "$((sec * 1000))"
}

# The task a wake key belongs to: the status or turn-ended file name, or the
# watcher's window name, reduced to the bare task id. Other keys (a check name,
# `heartbeat`) pass through unchanged.
fm_hj_task_of_key() { # <key>
  local key=$1
  key=${key%.status}
  key=${key%.turn-ended}
  key=${key%.meta}
  printf '%s\n' "$key"
}

# fm_hj_record <event> <seq> <kind> <key> <queued-epoch> [<task>]
fm_hj_record() {
  local event=$1 seq=${2:-0} kind=${3:--} key=${4:--} queued=${5:-0} task=${6:-} file lines
  [ -n "$task" ] || task=$(fm_hj_task_of_key "$key")
  file=$(fm_hj_path)
  {
    printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(fm_hj_now_ms)" "$event" \
      "$(printf '%s' "$task" | LC_ALL=C tr '\t\r\n' '   ')" "$seq" "$kind" \
      "$(printf '%s' "$key" | LC_ALL=C tr '\t\r\n' '   ')" "$queued" >>"$file"
  } 2>/dev/null || return 0
  lines=$(awk 'END { print NR }' "$file" 2>/dev/null || printf '0')
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt $((FM_HANDOFF_JOURNAL_KEEP * 2)) ]; then
    tail -n "$FM_HANDOFF_JOURNAL_KEEP" "$file" >"$file.trim.$$" 2>/dev/null \
      && mv -f "$file.trim.$$" "$file" 2>/dev/null
    rm -f "$file.trim.$$" 2>/dev/null
  fi
  return 0
}

# fm_hj_record_rows <event> <rows-file-or-stdin-text>: one record per tab-row
# (epoch seq kind key payload) read from stdin.
fm_hj_record_rows() { # <event>
  local event=$1 epoch seq kind key _payload
  while IFS=$'\t' read -r epoch seq kind key _payload; do
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    fm_hj_record "$event" "$seq" "$kind" "$key" "$epoch"
  done
  return 0
}
