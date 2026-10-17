---
name: orchestrator-handoff
description: Use when an orchestrator session that coordinates other Claude Code sessions (lanes) must hand its role to a fresh session (context too large, restart needed, user asks for a handoff), when a new session is told to take over as orchestrator, or when lane sessions must be replaced by fresh ones. Roles are held by session ID in a saved registry, not by session name.
---

# Orchestrator handoff

In this skill, `orch` means `sh "${CLAUDE_SKILL_DIR}/orch.sh"`. Run `orch` with no arguments for its command list.

**Roles belong to session IDs, not names.** `session-roles.json` in the handover dir maps each role (orchestrator, orchestrator-helper, and one per lane) to a session ID. Every session knows its own ID through `$CLAUDE_CODE_SESSION_ID` and claims roles itself. To message a role, look up its current address and pass that as SendMessage `to`:
```
orch addr orchestrator   # -> uds:/tmp/cc-socks/<pid>.sock, or OFFLINE <id> (exit 1)
```
Look the address up again before each message, because the pid changes when a session restarts. Session names are only labels for people, and nothing depends on them.

## Setup (once per project)
`orch init <dir>` creates a handover dir with starter files. Then edit `agent-boss.conf` (project name, user, GitHub repo) and `orchestrator-lanes.tsv`, and point sessions at the dir with `ORCH_DIR` or `~/.config/agent-boss/config` (`ORCH_DIR="/path/to/dir"`, plus the optional `ORCH_LOCK` and `ORCH_SNAPSHOT_HOOK`, which run programs and so are never read from the handover dir). If `orch` says ORCH_DIR is not set, ask the user which handover dir to use; don't guess.

Files in the handover dir:
- `agent-boss.conf`: project settings (environment variables of the same names win).
- `session-roles.json`: the registry. Change it only with `orch claim/drop`.
- `ORCHESTRATOR-HANDOFF.md`: the orchestrator handoff (template below).
- `ORCHESTRATOR.md`: the board, an append-only log with one line per event. Never read it whole; read the tail.
- `CURRENT-STATE.md`: the single source of truth for rules, decisions and open work. Handoffs point to it and don't repeat it.
- `orchestrator-crons.md`: the exact prompts of the orchestrator's crons. Crons are session-only, so a new orchestrator recreates them from this file.
- `orchestrator-lanes.tsv`: one row per lane (role, model, handoff file, start dir, required notes dir, job). `lane-handoffs/<role>.md` is each lane's handoff. `start-lane` starts the lane in its start dir and tells it to read its required notes first.
- `lane-notes/<role>/`: standing rules for a lane, `MEMORY.md` first (optional).

Commands:
- `snapshot`: this machine's disk, the build lock, the snapshot hook's lines, PRs and roles in one block.
- `archive`, `check-handoff`: the orchestrator handoff file.
- `claim <role> [--force]`, `drop <role>`, `addr <role>`, `roles`, `show`: the role registry.
- `check-lane`, `size`, `stop-lane`, `start-lane <role>`: lane transitions.
- `lanes`, `add-lane <role> <model> <start dir> "<job>"`: list lanes, add one (`/agent-boss:define-role` walks the user through designing it first).
- `context`, `start-successor`, `hook-stop`: the automatic orchestrator handoff (see below).
- `brief <role>`: what a subagent needs to work as that role (model, start dir, files to read, live holder). `/agent-boss:spawn <role> <task>` uses it to start an in-session role subagent.

`claim` refuses a role that a live session holds unless you pass `--force`, which is only for a planned handoff. Claiming `orchestrator` moves the previous holder to `orchestrator-helper`, or to `orchestrator-helper-<id>` if a live helper already exists. One helper is enough: the new orchestrator picks one, and the others end.

## Why
- **Names break messaging.** Two sessions can share a name (for example a stale Remote Control session), and then sends by name fail. Session IDs never collide.
- **Crons die with their session.** If the old session cancels first, check-ins stop. If it never cancels, they run twice. So the old session cancels only after the new one confirms it has recreated them.
- **Subagents and background waits die with their session.** Handoffs list each one with its branch and run ID.
- **A handoff written hours earlier is stale by takeover time.** `check-handoff` fails at 60 minutes, and `check-lane` fails at 30.
- **A subagent told to wait hours for a run wakes every few minutes and burns tokens.** Hand over the run ID instead.

## Step-down (outgoing orchestrator)
1. Finish or park the current step. Start nothing new, and give lanes no new work.
2. Run `orch archive`. Write `ORCHESTRATOR-HANDOFF.md` fresh from the template, and paste the output of `orch snapshot` into Machines.
3. In **In flight**, list every subagent, wait and remote run you started, with its branch, run ID, output file, and who finishes it ("helper forwards" or "new orchestrator redoes from log").
4. Make `orchestrator-crons.md` match your live crons (check with CronList).
5. Run `orch check-handoff` and fix what it reports.
6. Tell the user to start the new session and paste: `Run /orchestrator-handoff take-over.` Renaming sessions isn't needed.
7. Keep your crons running until the new orchestrator messages you. Then cancel every cron, reply with your in-flight status, and work only as helper (rules below).

## Automatic handoff
The plugin's Stop hook checks the orchestrator's context at the end of each turn. Once it passes `ORCH_HANDOFF_AT` (default 150000 tokens; 0 turns it off), the hook keeps you working with an instruction to hand off. It asks once per session, and only the session that holds the orchestrator role. `orch context` shows your current size. When it asks:
1. Park the current step, as in Step-down step 1. If something can't be parked (the user is mid-decision, a merge is half done), finish that first, but start nothing new.
2. Do Step-down steps 2-5 (archive, handoff, In flight, crons, check-handoff).
3. Run `orch start-successor`. It refuses unless you hold the orchestrator role and the handoff passes `check-handoff`, and it starts at most one successor per session. The successor runs in the background with `ORCH_ORCHESTRATOR_MODEL` (default opus) and the lane permission mode, does Take-over, and messages you.
4. Tell the user in one line that a new orchestrator is starting, and that they can watch or talk to it with `claude attach` (its session shows in `claude agents`).
5. Continue with Step-down step 7: keep your crons until the successor confirms, then cancel them and work as helper.

## Take-over (incoming orchestrator)
1. Read `ORCHESTRATOR-HANDOFF.md`, `CURRENT-STATE.md`, then the last 40 lines of the board. Run `orch check-handoff`. If it's stale, ask the old orchestrator to refresh it first (its address comes from `addr orchestrator`, before you claim).
2. Run `orch claim orchestrator --force`. The old holder becomes `orchestrator-helper`.
3. Run `orch snapshot` and compare it with the handoff. A new session gets fresh OS permissions (for example macOS disk access), so note any change.
4. Recreate every cron in `orchestrator-crons.md` with CronCreate.
5. Message the helper at `addr orchestrator-helper`: takeover done, crons recreated, cancel yours, send your in-flight list.
6. Plan the lane transition (below). Unless the user says otherwise, every lane gets a fresh session under you. Tell the helper the order.
7. Append one line to the board, then give the user at most 5 bullets.

## Lane transition (fresh lanes under the new orchestrator)
The helper winds down each old lane, and the new orchestrator starts its replacement. Do one lane at a time, the least busy first, and never while the user is testing or demoing. Each step reaches the lane through `addr <role>`.
1. **Helper: ask the lane to park.** Send one message, with `notify_when_idle: true`, telling it to:
   - finish or park its step;
   - commit and push every worktree;
   - clean build output and release any lock slot;
   - write `lane-handoffs/<role>.md` with `## Doing`, `## In flight` (runs and subagents with their IDs), `## Branches` (branch, head, PR, test run), `## Next` and `## Gotchas`;
   - reply with the path, then go idle.

   If the lane is OFFLINE, the helper writes that handoff itself from the board, CURRENT-STATE and `git ls-remote`.
2. **Helper: verify.** `orch check-lane <role>` checks freshness, the sections and the lock. Check the branch heads against `git ls-remote`. For each remote run it lists, confirm that it keeps going on its own. A lane's claim that it is ready is not proof.
3. **Helper: stop the old session.**
   - A background session: run `orch stop-lane <role>`. The conversation is kept, and `claude --bg --resume <session id>` restores it.
   - An interactive one: ask the user to close it.
4. **Helper: report to the orchestrator:** "<role> parked, handoff <path>, old session stopped, in flight: …".
5. **Orchestrator: start the replacement.** Run `orch start-lane <role>`. It refuses while a live session holds the role. The new session claims the role itself, reads its notes and handoff, and messages the orchestrator. Check its plan against the handoff's Next section before giving it work.
6. Both sessions log one board line per lane.

If a lane can't park (a long job is running), skip it and come back later. Never stop a session that holds a lock slot or is in the middle of a push.

## Lane notes
When a lane gets a standing rule from the user, save it in `lane-notes/<role>/` (with a line in that folder's `MEMORY.md`), not only in its handoff. A handoff describes the current state; the notes folder holds rules that outlast it. `start-lane` tells every new lane to read its notes first.

**Size check:** `orch size <role>` (also printed by `check-lane`) estimates a fresh lane's startup reading (notes + handoff + CURRENT-STATE, about 4 characters per token) against `ORCH_CTX`. At `ORCH_CTX_WARN_PCT` it prints WARN: suggest progressive disclosure to the user (for example an index note that names which notes to open when).

## Helper rules
- Send lanes no instructions, and don't merge PRs. Your work is the in-flight items, the lane wind-down, and any task the orchestrator hands you.
- When a lane messages you, forward the message to `addr orchestrator` and tell the lane that address.
- Once the in-flight list and the lane transition are both done, run `orch drop orchestrator-helper` and tell the user this session can be closed.

## Orchestrator handoff template
```
# Orchestrator handoff (YYYY-MM-DD, about HH:MM)
Read this, then CURRENT-STATE.md, then the last 40 lines of ORCHESTRATOR.md. Then run /orchestrator-handoff take-over.
## First things       (deadlines today, the user's pending notes, anything time-critical)
## Asking the user    (the decision queue and the suggested order; one at a time)
## Machines           (paste of orch snapshot, plus permission or lock problems and their fixes)
## Lanes              (one bullet per lane: doing, waiting on, blocked by)
## In flight          (subagents, waits and runs this session started: branch, run ID, output file, who finishes it)
## Standing rules     (short; point to CURRENT-STATE for the rest)
```
`check-handoff` accepts any section heading that starts with "Asking" (for example "Asking Sam").

## Common mistakes
- Reading a lane's "waiting" state as idle. In `orch roles`, "waiting" can mean the background session is stuck on a permission prompt nobody sees. If a lane shows "waiting" with no report for 30 minutes, read `claude logs <id>` for "Do you want to proceed?" and ask the user to answer it with `claude attach <id>`.
- Assuming an idle background lane is still there. Idle `--bg` lanes can exit on their own within about an hour. Check `orch roles` before handing work over; when one is offline, refresh its handoff and `start-lane` it.
- Messaging a role by session name. Always use `addr <role>`.
- Cancelling crons before the new orchestrator confirms it has recreated them.
- Giving lane instructions after stepping down, which splits authority.
- Writing `session-roles.json` by hand. Use `claim` and `drop`, which refuse to take a live holder's role by accident.
