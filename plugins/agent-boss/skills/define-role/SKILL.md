---
name: define-role
description: Walk the user through defining a new lane role for an agent-boss team (what it's for, what it owns, what it delivers, which decisions stay with the user, model, start dir, standing rules), then write its lanes row, notes and starter handoff. Use when the user runs /agent-boss:define-role, or asks to add, design or set up a new role or lane.
argument-hint: [rough description of the role]
---

# Define a role

Help the user design one lane role the way you would help them design a new agent: find out what the role is for before naming it, and turn the answers into rules a fresh session can follow. A role here is a lane: one Claude session (started with `start-lane`) or a subagent (started with `/agent-boss:spawn`) that works under the orchestrator.

In this skill, `orch` means `sh "${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-handoff/orch.sh"`.

Starting point from the user: `$ARGUMENTS` (may be empty).

## Before asking
1. Run `orch lanes`. If ORCH_DIR is not set, offer `orch init <dir>` and ask which dir to use. Keep the existing lanes in mind: a new role should not duplicate one.
2. Read `CURRENT-STATE.md` in the handover dir if it exists, so your suggestions fit the project.
3. Skip any question the user's starting description already answers; confirm it in the draft instead.

## The interview
Ask ONE question at a time and wait for the answer. Use AskUserQuestion with 2-4 concrete options when there are natural choices (mark your recommendation first), and plain questions when the answer is open. Suggest answers from what you know about the project; the user can always type their own.

1. **Purpose.** What problem should this role solve, and what does "done well" look like? Ask for one or two example tasks it would get.
2. **Overlap check.** If the purpose overlaps an existing lane, say which and ask: a new role, a change to that lane, or a narrower split between them.
3. **Ownership.** What does it own: repos, folders, file types, systems? What must it never touch, and which lanes own those?
4. **Deliverables and hand-off.** What does it produce (PRs, reports, pages, data, reviews), who checks its work, and where does it report (the orchestrator, by default)?
5. **Decisions.** Which calls may it make alone, and which must go to the user? Ask for concrete examples, such as "no merges", "no visual changes without approval", or "budget over $X".
6. **Model.** Recommend one from the work: `opus` for design, judgment and hard debugging; `sonnet` for routine implementation, research and runs; `haiku` for cheap, mechanical, high-volume tasks.
7. **Start dir.** The folder its sessions start in (usually the project repo or a parent folder that is already trusted, because a background session can't answer a trust prompt).
8. **Standing rules.** Tools, machines, budgets, conventions, past mistakes to avoid. Collect each as one rule with its reason.
9. **Name.** Propose a short lowercase name (letters, digits and `-`, such as `docs-writer`) and confirm it.

## Draft and confirm
Show the whole draft in one message before writing anything:
- The lanes row: role, model, start dir, and a one-line job (no tabs or line breaks).
- `lane-notes/<role>/MEMORY.md`: an index with one line per note.
- `lane-notes/<role>/role.md`: purpose, example tasks, owns, never touches, deliverables, who reviews, decisions it makes alone, decisions for the user.
- One note per standing rule (`<short-name>.md`): the rule, then **Why:** and **How to apply:** lines.
- `lane-handoffs/<role>.md`: the starter handoff (template below).

Ask the user to approve or change it. Revise until they approve. Write nothing before that.

## Write
1. `orch add-lane <role> <model> <start dir> "<job>"`. It refuses duplicates and bad names; fix the cause instead of working around it.
2. Write the notes files and the starter handoff into the paths it prints.
3. Run `orch check-lane <role>` and `orch brief <role>`, and fix anything they report.
4. If `CURRENT-STATE.md` has an "Open work by lane" section, add the role with "new, no work yet".
5. Tell the user what was created (paths) and the two ways to use it: `orch start-lane <role>` for a separate lane session, or `/agent-boss:spawn <role> <task>` for a one-off subagent.

## Starter handoff template
```
# <role> handoff (YYYY-MM-DD, about HH:MM)
New role, defined with /agent-boss:define-role. Read lane-notes/<role>/ first (MEMORY.md, then role.md).
## Doing
Nothing yet.
## In flight
None.
## Branches
None.
## Next
<the first task the user named, or "wait for the orchestrator's first task">
## Gotchas
<anything from the interview that is easy to get wrong>
```

## Don't
- Don't write files before the user approves the draft.
- Don't give a role the power to merge, push to main, change permission settings or spend money unless the user said so in the interview.
- Don't copy rules from another lane without asking; similar roles can still differ.
