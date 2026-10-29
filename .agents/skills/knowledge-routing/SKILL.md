---
name: knowledge-routing
description: Load when deciding where durable knowledge belongs, or before touching a project's AGENTS.md or CLAUDE.md.
user-invocable: false
metadata:
  internal: true
---

Route durable knowledge to its most specific owner:

- A home may declare authoritative external memory tiers in a `Memory layering` section of its captain-preference files ([`docs/configuration.md`](../../../docs/configuration.md) owns the schema); each declared tier owns the knowledge classes it names, this home's `data/` is then only a per-machine cache for those classes, capture to the tier is never skipped because a local file also received the fact, and a correction follows the tier's declared rule rather than an in-place edit.
- When a worker's harness cannot reach a declared tier, firstmate captures on the worker's behalf from its report.
- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under the `secondmate-provisioning` contract.
- Fleet-local operational facts no declared tier owns belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`, which only deliberate human edits extend.
- Knowledge general to every firstmate user belongs in this repo's shared tracked surface, which a user/operator home can only reach through an authorized contribution - otherwise it stays in `data/learnings.md` or a local draft for the captain.

Firstmate never writes a project's `AGENTS.md` directly.
A crewmate edits a project's `AGENTS.md` or `CLAUDE.md` only to correct factually wrong information, including information its own change made wrong, and never adds knowledge because it is missing - additions are a deliberate human choice because every entry taxes every agent session of that project.
A correction edits only the wrong text and never runs `bin/fm-ensure-agents-md.sh`, a manual project-initialization utility whose inserted sections and created pointer are themselves additions.
Keep fleet delivery posture and captain-private strategy out of project memory.
When the captain invokes `/stow`, load the `stow` skill for its memory curation, knowledge routing, and persistence of the open work records this session is holding; it files and corrects only the open work that session is holding, and never reconciles the backlog against repository or PR reality.
