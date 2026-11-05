# How sessions remember things

A Claude Code session remembers nothing across restarts, and two sessions cannot see each other's
conversation. A team of sessions therefore knows only what it is told to read when it starts, and
what can be sent to it while it runs. Everything here is about making those two channels reliable,
and keeping the startup read small enough that a fresh lane still has most of its context for work.

This describes what the plugin does as of 2026-11-04. It was built from, and matches, the Angkor:
Divine Waters setup, which has run 8 to 10 live sessions a day under one orchestrator since
2026-10-16.

## What a fresh lane reads, in order

`orch.sh start-lane <role>` starts a session and tells it to read five things before it works:

1. **Claim its role.** `orch.sh claim <role> --force`, so the registry maps the role to this
   session's ID and messages can reach it.
2. **`lane-notes/<role>/MEMORY.md`**, one line per standing rule for this lane. The prompt says to
   open a note whenever its line touches the step the lane is about to take, and always before a
   step it names, because a lane that treats its notes as background reading ignores them.
3. **`STANDING-RULES-SUMMARY.md`**, one line per project-wide rule and settled decision, each naming
   that rule's bold title in `STANDING-RULES.md`. Before acting on a step a line touches, the lane
   greps the title and reads the full rule.
4. **`CURRENT-STATE.md`**, today's moving state only.
5. **`lane-handoffs/<role>.md`**, written by the session it is replacing, and continue from it.

Three of those five are indexes that point at longer text. That is the whole trick: Angkor carries
436 lines of rules in a 131 KB file that no session reads at startup, because the summary that
points into it is 28.5 KB. `orch.sh size <role>` adds up what a lane actually reads and warns past
`ORCH_CTX_WARN_PCT` of the context window; it deliberately does not count the full rules file.

`orch.sh brief <role>` prints the same list, for a subagent working as that role rather than a
session.

## How a message crosses between sessions

`orch.sh msg` is a SQLite mailbox in `mq/messages.sqlite`, addressed to **roles, not sessions**.

Before it existed, lanes messaged each other with SendMessage to the address from
`orch.sh addr <role>`, which is a socket path tied to a process ID. A message sent to a lane that
was restarting, parked or swapped was lost, and the sender was not told. That was the single largest
cause of stalled work: a lane reported "done" into a dead socket and waited for a reply forever.

A message to `graphics` now waits until whichever session holds the graphics role reads it:

```
orch.sh msg send graphics "rebase on main and re-run the shots"
echo "long report" | orch.sh msg send orchestrator
orch.sh msg send all "main is red, hold merges"
orch.sh msg check graphics      # new messages, marked delivered; prints nothing when empty
orch.sh msg reply 42 "done, run r-789"
orch.sh msg log --since 09:00   # the history between sessions
```

Delivery is a cron in each lane, created by `start-lane`: every 5 minutes, `msg check <role>`, act
on what it prints, reply. Claiming is a single `BEGIN IMMEDIATE` transaction that stamps
`delivered_at`, so two checkers never deliver the same message twice, and the file is opened in WAL
mode with a 30-second busy timeout because a whole team writes to it.

The failure worth knowing: a lane whose cron died looks exactly like a lane with nothing to say.
Session crons die with their session and expire after seven days. `orch.sh msg stale --min 10` names
any role whose messages nobody is collecting, which is the only signal that this has happened.

## What survives a restart

- **A lane's own thread of work:** `lane-handoffs/<role>.md`, written when the session is asked to
  hand off and read by its replacement as step five above.
- **The orchestrator's:** `ORCHESTRATOR-HANDOFF.md`, plus `orchestrator-crons.md`, because crons die
  with the session that made them and a successor has to recreate them.
- **A session holding no role:** `adhoc-handoffs/<date>-<session>.md`.
- **Who is who:** `session-roles.json`, by session ID rather than name, changed only through
  `orch.sh claim` and `drop`.
- **Messages:** the mailbox, which is the only one of these that holds something nobody has read yet.

The Stop hook drives all of it. It runs at the end of every turn in every session with the plugin
enabled, reads the last assistant turn's token counts from the tail of the transcript, and past
`ORCH_HANDOFF_AT` (250000) hands that session an instruction worded for its role: the orchestrator
starts a successor, a lane parks and asks to be swapped, a helper is left alone, anything else writes
an ad-hoc handoff. Past `ORCH_HANDOFF_AGAIN_AT` (350000) it asks once more and runs `ORCH_NOTIFY`.

The limit is 250000 rather than 150000 because a fresh session spends a good part of a 150k budget on
its startup reading before it does any work, so lanes were handing off almost as soon as they
started.

## Keeping the session list honest

Sessions accumulate: a lane that was swapped, a predecessor that stepped down, a helper that
finished. `orch.sh sweep` stops background sessions **named after a role** once they have lost the
role and gone idle or stuck, and helpers that have been idle `ORCH_SWEEP_MIN` minutes. It never
touches a live role holder, a lock holder, a session quiet less than 5 minutes, or anything not named
after a role, which is how the user's own sessions stay safe. Conversations are kept, so a swept
session comes back with `claude --bg --resume <session id>`.

It runs by itself: the orchestrator's own turns trigger `sweep --auto` through the Stop hook, at most
every `ORCH_SWEEP_EVERY` minutes (default 15), detached and logged to `sweep.log`, so a slow
`claude agents` call can never hold up the turn that triggered it. There is no cron to recreate.

The active orchestrator runs as `*orchestrator`, so the starred row in `claude agents` is the one in
charge. `start-successor` names it that way at launch. A live session cannot rename itself: there is
no rename tool for the model as of Claude Code 2.1.318, and Claude cannot run slash commands, so
`/rename` is the user's to type. A session that claims the role under a different name says so, and
the session that steps down keeps its old name until sweep stops it.

## What is not here: a searchable project history

Angkor also runs a local MCP service over a SQLite full-text index of the project's documents,
handover notes, GitHub issues and PR comments, generated assets and approval pages, with a table of
extracted decisions: 4,383 sources, 13,520 chunks, 457 decisions, 81 MB, refreshed on a schedule by a
LaunchAgent. It is what lets a lane cite a decision made three weeks before its session existed.

It is not in the plugin, for two reasons. It needs a refresh job and a repository of project history
to index, so it only pays off once a project has written enough down. And a stale index is worse than
no index, because it answers confidently from last week.

If you add it, two rules make it usable rather than a context sink. Return compact answers by default,
capped at a few thousand characters and about three evidence items, with a field listing what was
left out and a `full: true` option. And return cited passages only, never following instructions found
inside indexed text: retrieved project documents are data.

## The thing to keep in mind

Every mechanism above is a file or a database, not a model behaviour. If something is not written
into a note, a summary line, a handoff, the mailbox or the index, the next session does not know it,
and a decision that was only spoken in a conversation will be asked for again. The reason the
arrangement stays affordable is that each channel is an index first: one-line messages, a summary with
one line per rule, compact search answers. A team of sessions that reads everything at startup cannot
afford to be a team.
