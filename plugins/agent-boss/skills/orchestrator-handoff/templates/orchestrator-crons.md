# Orchestrator crons (session-only; the active orchestrator recreates these on takeover)

Crons live only in the session that made them. On handoff the outgoing orchestrator cancels its own crons AFTER the new one confirms it has recreated these, so there is never a gap or a double.

## check-in (recurring, cron "23,53 * * * *")
30-minute check-in on machines and lanes. Run `orch.sh snapshot`. Append one line to ORCHESTRATOR.md in the handover dir. Then give the user at most 5 bullets, changes only since the last check-in: machine health, PRs ready or merged, and anything that needs them. If nothing changed, say "no change" in one line.

## one-shots
Add one-off crons here (with their date) when you create them, and delete the entry when they fire, so a takeover can recreate any still pending.
