#!/bin/sh
# Stop hook for every session with agent-boss enabled. It only ever prints the
# handoff JSON and always exits 0: any other output or exit code (exit 2 means
# "block" for a Stop hook) must never hold up an unrelated session.
out=$(sh "$(dirname "$0")/../skills/orchestrator-handoff/orch.sh" hook-stop 2>/dev/null)
case "$out" in "{"*) printf '%s\n' "$out" ;; esac
exit 0
