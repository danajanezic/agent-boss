---
name: spawn
description: Start an in-session subagent that works as one of the project's lane roles (for example frontend or backend), primed with that role's lane notes, handoff and CURRENT-STATE from the agent-boss handover dir. Use when the user runs /agent-boss:spawn <role> <task> or asks for a subagent to do a task "as" a lane role.
argument-hint: <role> <task>
---

# Spawn a role subagent

Arguments: `$ARGUMENTS`. The first word is the role; the rest is the task.

In this skill, `orch` means `sh "${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-handoff/orch.sh"`.

## Steps
1. **Check the arguments.** If the role is missing, run `orch roles` and show the lanes in `orchestrator-lanes.tsv` (from `orch brief` errors or the handover dir), then ask which role. If the task is missing, ask for it. Don't invent a task.
2. **Get the brief.** Run `orch brief <role>`. If it fails because ORCH_DIR is not set, ask the user which handover dir to use. If the role is unknown, show the known roles and stop.
3. **Check for overlap.** If the brief shows a live holder, tell the user a lane session already holds the role and ask whether to go ahead, because two workers on one role can edit the same files. If the size line says WARN, mention it in one line.
4. **Start the subagent** with the Agent tool:
   - `subagent_type`: `general-purpose`.
   - `model`: the brief's model if it is one the Agent tool accepts; otherwise leave it out.
   - `description`: `<role>: <3-5 word task summary>`.
   - `prompt`: fill in this template from the brief, listing every file under "read first" in order:

```
You are working as the <role> lane for <project>, as a subagent of the session that started you. The lane's job: <job>.

Before any work, read these files in order. They are this role's standing rules and current state, and they override your defaults:
<each "read first" path, one per line>
<house rules line, if the brief has one>

Work in <start dir>. Your task:
<task, verbatim>

Limits:
- You are a subagent, not the lane session: don't claim roles, don't run orch.sh claim/drop/start-lane/stop-lane, and don't message other sessions.
- Don't merge PRs, push to main, or change permission settings. Ask in your report instead of guessing on anything the files say needs <user>'s decision.
- If the handoff lists work in flight for this role, don't touch it unless the task says to.

Finish with a short report: what you did, the files, branches and PRs you changed, test results, and any open questions.
```
5. **Relay the result.** When the subagent finishes, give the user its outcome in your own words: what changed, where, and any open questions. The user can't see the subagent's report.

Run it in the background only if the user asks or the task is long; then tell the user it is running and wait for the completion notice.
