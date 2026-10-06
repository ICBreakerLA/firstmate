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

# The task a wake key belongs to: a stale wake's window name through
# window_to_task (fm-classify-lib.sh, which every caller recording a stale wake
# sources), a `gate-parked:<task>:<run>` key's task, and a status, turn-ended or
# meta file name reduced to the bare task id. Other keys (a check name,
# `heartbeat`) pass through unchanged.
fm_hj_task_of_key() { # <kind> <key>
  local kind=$1 key=$2
  case "$kind:$key" in
    stale:*) key=$(window_to_task "$key") ;;
    *:gate-parked:*:*) key=${key#gate-parked:}; key=${key%:*} ;;
    *)
      key=${key%.status}
      key=${key%.turn-ended}
      key=${key%.meta}
      ;;
  esac
  printf '%s\n' "$key"
}

# fm_hj_line <event> <seq> <kind> <key> <queued-epoch> <task>: one journal line.
fm_hj_line() {
  printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(fm_hj_now_ms)" "$1" \
    "$(printf '%s' "$6" | LC_ALL=C tr '\t\r\n' '   ')" "$2" "$3" \
    "$(printf '%s' "$4" | LC_ALL=C tr '\t\r\n' '   ')" "$5"
}

# fm_hj_append <lines>: one open, one write per whole line so a concurrent
# writer can never split a row, then one trim check for the batch.
fm_hj_append() {
  local file lines line
  [ -n "$1" ] || return 0
  file=$(fm_hj_path)
  {
    while IFS= read -r line; do
      printf '%s\n' "$line"
    done <<<"${1%$'\n'}"
  } 2>/dev/null >>"$file" || return 0
  lines=$(awk 'END { print NR }' "$file" 2>/dev/null || printf '0')
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt $((FM_HANDOFF_JOURNAL_KEEP * 2)) ]; then
    tail -n "$FM_HANDOFF_JOURNAL_KEEP" "$file" >"$file.trim.$$" 2>/dev/null \
      && mv -f "$file.trim.$$" "$file" 2>/dev/null
    rm -f "$file.trim.$$" 2>/dev/null
  fi
  return 0
}

# fm_hj_record <event> <seq> <kind> <key> <queued-epoch> [<task>]
fm_hj_record() {
  local event=$1 seq=${2:-0} kind=${3:--} key=${4:--} queued=${5:-0} task=${6:-}
  [ -n "$task" ] || task=$(fm_hj_task_of_key "$kind" "$key")
  fm_hj_append "$(fm_hj_line "$event" "$seq" "$kind" "$key" "$queued" "$task")
"
}

# The window and terminal names of every meta file as `name<TAB>task` lines, in
# the order window_to_task scans them, so a batch resolves stale keys from one
# read of the meta files.
fm_hj_window_map() {
  local meta line t
  for meta in "${STATE:-${FM_HOME:-.}/state}"/*.meta; do
    [ -e "$meta" ] || continue
    t=${meta##*/}
    t=${t%.meta}
    {
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          window=*) printf '%s\t%s\n' "${line#window=}" "$t" ;;
          terminal=*) printf '%s\t%s\n' "${line#terminal=}" "$t" ;;
        esac
      done < "$meta"
    } 2>/dev/null
  done
}

# fm_hj_record_rows <event>: one record per tab-row (epoch seq kind key payload)
# read from stdin, appended and trimmed once for the whole batch.
fm_hj_record_rows() { # <event>
  local event=$1 epoch seq kind key _payload task map='' mapped=0 w t out=''
  while IFS=$'\t' read -r epoch seq kind key _payload; do
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    if [ "$kind" = stale ]; then
      [ "$mapped" -eq 1 ] || { map=$(fm_hj_window_map); mapped=1; }
      task=${key##*:}; task=${task#fm-}
      while IFS=$'\t' read -r w t; do
        [ "$w" = "$key" ] || continue
        task=$t
        break
      done <<<"$map"
    else
      task=$(fm_hj_task_of_key "$kind" "$key")
    fi
    out+=$(fm_hj_line "$event" "$seq" "${kind:--}" "${key:--}" "${epoch:-0}" "$task")$'\n'
  done
  fm_hj_append "$out"
}
