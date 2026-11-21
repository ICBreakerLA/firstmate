#!/usr/bin/env bash
# Repo invariants the hosted-CI invariants job enforces: the AGENTS.md
# pointer files stay intact and personal fleet paths stay untracked. The local
# no-mistakes gate also runs this through the portable serial lane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_claude_pointer_and_skills_symlink_are_intact() {
  local claude="$ROOT/CLAUDE.md" skills="$ROOT/.claude/skills"
  [ ! -L "$claude" ] || fail "CLAUDE.md must be a real @AGENTS.md pointer file, not a symlink"
  cmp -s "$claude" - <<'EOF' || fail "CLAUDE.md must be the canonical @AGENTS.md pointer"
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
  [ "$(readlink "$skills")" = "../.agents/skills" ] \
    || fail ".claude/skills must be a symlink to ../.agents/skills"
  pass "repo invariants: AGENTS.md pointer and skills symlink stay intact"
}

test_personal_fleet_paths_stay_untracked() {
  local tracked
  tracked=$(git -C "$ROOT" ls-files -- data state config projects .no-mistakes)
  [ -z "$tracked" ] || fail "personal fleet paths are tracked in git:"$'\n'"$tracked"
  pass "repo invariants: personal fleet paths stay untracked"
}

test_claude_pointer_and_skills_symlink_are_intact
test_personal_fleet_paths_stay_untracked
