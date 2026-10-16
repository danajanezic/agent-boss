# agent-boss

A Claude Code plugin marketplace with tools for running a team of Claude Code sessions: one **orchestrator** that coordinates, and several **lanes** (frontend, backend, art, review…) that do the work, each in its own session.

## Plugins

### agent-boss

The `orchestrator-handoff` skill. It covers:
- **Roles by session ID.** A registry maps each role to a session ID, so messages reach the right session even when names repeat or go stale. `orch.sh addr <role>` gives the SendMessage address.
- **Orchestrator handoffs.** Step-down and take-over steps, a handoff template, and `check-handoff`, which fails when the handoff is stale or missing sections.
- **Fresh lanes.** The old orchestrator, now the helper, parks each lane. The new one starts a replacement with `orch.sh start-lane <role>`, which reads the lane's notes and handoff.
- **Snapshots.** `orch.sh snapshot` shows disk, an optional build lock, your own machine checks, recent PRs and live roles in one block.

## Install

```
claude plugin marketplace add danajanezic/agent-boss
claude plugin install agent-boss@agent-boss
```

Run the skill as `/agent-boss:orchestrator-handoff`, for example `/agent-boss:orchestrator-handoff take-over`.

## Set up a project

1. Create a handover dir: `sh <plugin>/skills/orchestrator-handoff/orch.sh init ~/code/my-project-handover`. Or ask Claude to run `orch init` for you after installing.
2. Edit `agent-boss.conf` there (project name, your name, GitHub repo, optional build lock and snapshot hook) and `orchestrator-lanes.tsv` (one row per lane).
3. Point sessions at the dir: `mkdir -p ~/.config/agent-boss && echo 'ORCH_DIR="$HOME/code/my-project-handover"' > ~/.config/agent-boss/config`. An `ORCH_DIR` environment variable overrides it.

A snapshot hook is any script that prints status lines, for example:

```sh
#!/bin/sh
ssh -o ConnectTimeout=8 build-box 'echo "build-box: $(uptime | sed "s/.*averages: //"), $(df -Pk / | tail -1 | awk "{printf \"%d GB free\", \$4/1048576}")"'
```

## Security

`orch.sh` reads `agent-boss.conf` and `~/.config/agent-boss/config` as plain `ORCH_NAME="value"` lines and never runs them as shell code. `ORCH_LOCK` and `ORCH_SNAPSHOT_HOOK` do name scripts that `snapshot` and `check-lane` run, so only point `ORCH_DIR` at handover dirs you trust.

## Requirements

- Claude Code with background sessions (`claude --bg`, `claude agents --json`, `claude stop`) and cross-session SendMessage. Tested with 2.1.302.
- `python3`, `sh`, and `gh` if you set `ORCH_REPO`.
- Session addresses use Claude Code's local socket path (`uds:/tmp/cc-socks/<pid>.sock`), so all sessions must run on one machine.

## Licence

MIT
