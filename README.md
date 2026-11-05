# agent-boss

A Claude Code plugin marketplace with tools for running a team of Claude Code sessions: one **orchestrator** that coordinates, and several **lanes** (frontend, backend, art, review…) that do the work, each in its own session.

## Plugins

### agent-boss

Three skills (`orchestrator-handoff`, `spawn`, `define-role`) and a Stop hook. They cover:
- **Roles by session ID.** A registry maps each role to a session ID, so messages reach the right session even when names repeat or go stale. `orch.sh addr <role>` gives the SendMessage address. The active orchestrator runs as `*orchestrator`, so the starred row in `claude agents` is the one in charge.
- **A mailbox that survives restarts.** `orch.sh msg send <role> "..."` queues a message for whichever session holds that role, in a SQLite file in the handover dir, and a cron in each lane collects it every 5 minutes. A report sent to a lane that is parked or being swapped waits for its replacement instead of vanishing into a dead socket, and `msg log` keeps the whole history. `msg stale --min 10` names any role whose messages nobody is collecting, which is what a dead delivery cron looks like.
- **Rules as an index plus full text.** `STANDING-RULES-SUMMARY.md` holds one line per rule; `STANDING-RULES.md` holds them in full. Sessions read the summary at startup and grep a rule's bold title out of the full file only when a line touches the step they are on, so a project can carry hundreds of rules without spending a fresh session's context on them. `orch.sh size <role>` estimates what a lane reads at startup and warns when it grows.
- **Orchestrator handoffs.** Step-down and take-over steps, a handoff template, and `check-handoff`, which fails when the handoff is stale or missing sections.
- **Fresh lanes.** The old orchestrator, now the helper, parks each lane. The new one starts a replacement with `orch.sh start-lane <role>`, which reads the lane's notes and handoff.
- **Automatic handoff, in every session.** A Stop hook checks each session's context after its turn. Past `ORCH_HANDOFF_AT` (default 250000 tokens; 0 turns it off) it asks that session to hand off, worded for the role it holds: the orchestrator writes its handoff and runs `orch.sh start-successor`, which launches a fresh background orchestrator (`ORCH_ORCHESTRATOR_MODEL`, default opus) that takes over and messages the old one; a lane parks, writes `lane-handoffs/<role>.md` and asks the orchestrator to swap it; a session with no role writes `adhoc-handoffs/<date>-<session>.md`. Past `ORCH_HANDOFF_AGAIN_AT` (default 350000) it asks again and runs `ORCH_NOTIFY`, if you point that at an alert script. The check only reads local files and takes a few hundredths of a second.
- **Automatic sweep of finished role agents.** Lanes that were swapped, a predecessor that stepped down, a helper that finished: `orch.sh sweep` stops them once they have lost their role and gone idle, or have been idle as helpers for `ORCH_SWEEP_MIN` minutes. Only sessions that actually claimed a role are eligible, because `claim` records them in `role-sessions.json` and sweep reads nothing else, so a session of your own is never touched whatever you named it. It also skips live role holders, interactive sessions, lock holders and anything quiet under 5 minutes, and it keeps conversations, so a swept session resumes with `claude --bg --resume <id>`. The orchestrator's own turns trigger it every `ORCH_SWEEP_EVERY` minutes (default 15, `0` for manual only), so there is no cron to recreate; `sweep --dry` shows what it would stop.
- **Defining roles.** `/agent-boss:define-role [rough description]` interviews you one question at a time: what the role is for, what it owns and must never touch, what it delivers, which decisions stay with you, its model, start dir and standing rules. It shows a full draft, and only after you approve it writes the lanes row (`orch.sh add-lane`), the role's notes and a starter handoff.
- **Role subagents.** `/agent-boss:spawn <role> <task>` starts a subagent inside your session that works as a lane role: it reads that role's notes, handoff and CURRENT-STATE first, then does the task and reports back. It doesn't claim the role in the registry. `orch.sh brief <role>` prints what it reads.
- **Snapshots.** `orch.sh snapshot` shows disk, an optional build lock, your own machine checks, recent PRs and live roles in one block.

### soda-fountain

A skill plus the `soda-fountain` MCP server (npm `soda-fountain-mcp`, pinned to 2.0.1) for questions about US city, county and state open data on Socrata portals. It covers:
- **Query workflow.** Find a portal and dataset, read its columns, then run SoQL, with the pitfalls that trip up SQL habits.
- **Cross-dataset keys.** `find_correlation_keys` shows which columns line up across datasets and portals.
- **Errors and retired datasets.** What each error code means, and to search again when a dataset ID is dead.
- **Optional app token.** Export `SOCRATA_API_KEY` for higher rate limits; it works without one.

Install:

```
claude plugin marketplace add danajanezic/agent-boss
claude plugin install soda-fountain@agent-boss
```

## How sessions remember things

[docs/shared-memory.md](docs/shared-memory.md) explains the arrangement these pieces add up to: what a fresh session reads and in what order, how a message crosses between sessions, what survives a restart, and the one piece of the original setup that is not in the plugin (a searchable index of project history). Worth reading before changing any of it, because every mechanism is a file or a database rather than a model behaviour, and that is what makes it work.

## Install

```
claude plugin marketplace add danajanezic/agent-boss
claude plugin install agent-boss@agent-boss
```

Run the skill as `/agent-boss:orchestrator-handoff`, for example `/agent-boss:orchestrator-handoff take-over`.

## Set up a project

1. Create a handover dir: `sh <plugin>/skills/orchestrator-handoff/orch.sh init ~/code/my-project-handover`. Or ask Claude to run `orch init` for you after installing.
2. Edit `agent-boss.conf` there (project name, your name, GitHub repo). Add lanes with `/agent-boss:define-role`, or edit `orchestrator-lanes.tsv` by hand (one row per lane; replace the sample frontend and backend rows). An optional build lock (`ORCH_LOCK`) and snapshot hook (`ORCH_SNAPSHOT_HOOK`) go in `~/.config/agent-boss/config`.
3. Point sessions at the dir: `mkdir -p ~/.config/agent-boss && echo 'ORCH_DIR="$HOME/code/my-project-handover"' > ~/.config/agent-boss/config`. An `ORCH_DIR` environment variable overrides it.

A snapshot hook is any script that prints status lines, for example:

```sh
#!/bin/sh
ssh -o ConnectTimeout=8 build-box 'echo "build-box: $(uptime | sed "s/.*averages: //"), $(df -Pk / | tail -1 | awk "{printf \"%d GB free\", \$4/1048576}")"'
```

## Security

- `orch.sh` reads `agent-boss.conf` and `~/.config/agent-boss/config` as plain `ORCH_NAME="value"` lines and never runs them as shell code.
- `ORCH_LOCK`, `ORCH_SNAPSHOT_HOOK` and `ORCH_NOTIFY` name scripts that run, so they are accepted only from the environment or `~/.config/agent-boss/config`, never from a handover dir's own `agent-boss.conf`.
- `ORCH_ORCHESTRATOR_DIR` (where an automatic successor starts) also comes only from the environment or `~/.config/agent-boss/config`.
- Every Python step runs with `python3 -I`, so a `json.py` or similar planted in a session's working folder is never imported, including by the Stop hook that runs in every session.
- The Stop hook runs in every session on the machine, including sessions in projects unrelated to your handover dir, so it treats that dir's contents as data: `ORCH_USER` is clamped to a few short name characters before it appears in a notice, a role name cannot become a path, and a lane's handoff path is resolved and must stay inside the handover dir. A handover dir you do not trust can still put a few words in front of its own lanes through `ORCH_LANE_PROMPT_EXTRA` and the notes those lanes read, which is why the next point stands.
- `ORCH_LANE_PERMISSION_MODE` follows the same rule and must be `auto`, `default`, `acceptEdits` or `plan`; `bypassPermissions` is refused.
- `start-lane` refuses an `ORCH_DIR` or script path containing a quote, backtick, `$` or backslash, because those paths go into the command line the new session runs.
- Agents read the handover dir's handoffs, notes and settings as instructions, and lanes start in `auto` permission mode by default. Only use handover dirs you trust. Mailbox messages come from other sessions and from scripts, so treat them the same way.
- `sweep` only ever stops background sessions listed in `role-sessions.json`, which `claim` writes, so a session you started yourself is never eligible however you named it, and it never stops one holding a live role or a lock slot. `sweep --dry` shows what it would do.

## Requirements

- Claude Code with background sessions (`claude --bg`, `claude agents --json`, `claude stop`) and cross-session SendMessage. Tested with 2.1.302.
- `python3`, `sh`, and `gh` if you set `ORCH_REPO`.
- Session addresses use Claude Code's local socket path (`uds:/tmp/cc-socks/<pid>.sock`), so all sessions must run on one machine.

## Licence

MIT
