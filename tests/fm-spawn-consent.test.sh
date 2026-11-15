#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --upstream-consent parsing and refusals.
#
# The option records a ship's one-off approval to publish to one repository,
# and the launched brief must record the same token. These tests drive the real
# bin/fm-spawn.sh. Every refusal case stops at the flag's own validation, which
# runs before any project, record, endpoint, or worktree exists; the acceptance
# cases reach the missing-brief check, which runs after the flag is parsed and
# normalized, so no terminal or worktree side effect is ever created.
# FM_SPAWN_NO_GUARD=1 keeps them off the live watcher guard / state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-consent)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so each case owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# refuse <label> <expected substring> <args...>
refuse() {
  local label=$1 want=$2 out status
  shift 2
  out=$(run_spawn "$@")
  status=$?
  [ "$status" -ne 0 ] || fail "$label: expected a refusal, got success: $out"
  printf '%s\n' "$out" | grep -F "$want" >/dev/null || fail "$label: missing '$want': $out"
}

# The flag takes a value both as a following argument and after '='; a missing
# or empty value is refused before anything else about the spawn is resolved.
test_consent_requires_a_value() {
  refuse 'consent as the last argument' 'error: --upstream-consent requires a value' \
    task-consent-a projects/none-a --mode no-mistakes --yolo off --upstream-consent
  refuse 'consent followed by another flag' 'error: --upstream-consent requires a value' \
    task-consent-b projects/none-a --mode no-mistakes --yolo off --upstream-consent --yolo on
  refuse 'empty = form' 'error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value' \
    task-consent-c projects/none-a --mode no-mistakes --yolo off --upstream-consent=
  pass "--upstream-consent refuses a missing or empty value in both spellings"
}

# The value is a publication scope, not a path or a bare name.
test_consent_rejects_a_malformed_scope() {
  refuse 'no slashes' "error: --upstream-consent must be <host>/<owner>/<repo> (got 'not-a-scope')" \
    task-consent-d projects/none-a --mode no-mistakes --yolo off --upstream-consent not-a-scope
  refuse 'two fields' "error: --upstream-consent must be <host>/<owner>/<repo> (got 'github.com/owner')" \
    task-consent-e projects/none-a --mode no-mistakes --yolo off --upstream-consent github.com/owner
  refuse 'trailing slash' "error: --upstream-consent must be <host>/<owner>/<repo> (got 'github.com/owner/repo/')" \
    task-consent-f projects/none-a --mode no-mistakes --yolo off --upstream-consent github.com/owner/repo/
  pass "--upstream-consent rejects a scope that is not <host>/<owner>/<repo>"
}

# The approval applies only where a ship publishes through the role gate.
test_consent_is_refused_where_it_cannot_apply() {
  refuse 'local-only publishes nothing' \
    'error: --upstream-consent is meaningless on local-only, which publishes nothing; drop it' \
    task-consent-g projects/none-a --mode local-only --yolo off --upstream-consent github.com/owner/repo
  refuse 'scout has no delivery contract' \
    'error: --upstream-consent applies only to ship spawns; a scout publishes nothing and a secondmate records no delivery contract' \
    task-consent-h projects/none-a --scout --upstream-consent github.com/owner/repo
  refuse 'secondmate has no delivery contract' \
    'error: --upstream-consent applies only to ship spawns; a scout publishes nothing and a secondmate records no delivery contract' \
    task-consent-i projects/none-a --secondmate --upstream-consent github.com/owner/repo
  refuse 'relaunch reuses the recorded consent' \
    "error: --relaunch reuses the task's recorded upstream consent; --upstream-consent cannot override it" \
    task-consent-j --relaunch --upstream-consent github.com/owner/repo
  pass "--upstream-consent is refused on local-only, scouts, secondmates, and relaunches"
}

# A well-formed approval survives parsing and validation, in both the space and
# '=' forms, so the spawn proceeds to its next check (here, the missing brief).
test_well_formed_consent_is_accepted_for_a_ship() {
  local case_dir home project out status
  case_dir="$TMP_ROOT/accepted"
  home="$case_dir/home"
  project="$case_dir/accepted-project"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' codex > "$home/config/crew-harness"
  fm_git_init_commit "$project"
  fm_git_add_origin "$project" "$project.origin.git"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" consent-ok-a "$project" --mode no-mistakes --yolo off \
    --upstream-consent github.com/Owner/Repo 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn with no brief should fail: $out"
  printf '%s\n' "$out" | grep -F "error: task consent-ok-a has no brief at inaccessible data path $home/data/consent-ok-a/brief.md" >/dev/null \
    || fail "the space-form --upstream-consent was not accepted before the brief check: $out"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" consent-ok-b "$project" --mode no-mistakes --yolo off \
    --upstream-consent=github.com/Owner/Repo 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn with no brief should fail: $out"
  printf '%s\n' "$out" | grep -F "error: task consent-ok-b has no brief at inaccessible data path $home/data/consent-ok-b/brief.md" >/dev/null \
    || fail "the '=' form of --upstream-consent was not accepted before the brief check: $out"
  pass "a well-formed --upstream-consent is accepted in both the space and '=' forms"
}

test_consent_requires_a_value
test_consent_rejects_a_malformed_scope
test_consent_is_refused_where_it_cannot_apply
test_well_formed_consent_is_accepted_for_a_ship
