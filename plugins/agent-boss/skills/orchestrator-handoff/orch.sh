#!/bin/sh
# Orchestrator handoffs and lane roles for a team of Claude Code sessions.
# Roles are held by SESSION ID in $ORCH_DIR/session-roles.json, never by
# session name: names can repeat and go stale, a session id can't. A session
# claims a role with its own $CLAUDE_CODE_SESSION_ID; `addr` turns a role into
# a SendMessage address.
#   orch.sh init [dir]               create a handover dir with starter files
#   orch.sh snapshot                 machine + PR + role status block (markdown)
#   orch.sh archive                  copy ORCHESTRATOR-HANDOFF.md to a dated file
#   orch.sh check-handoff            fail if the handoff is stale or missing parts
#   orch.sh claim <role> [--force]   this session takes <role> (orchestrator: old holder -> orchestrator-helper)
#   orch.sh drop <role>              this session gives up <role>
#   orch.sh addr <role>              SendMessage "to" for the role's holder (exit 1 if offline)
#   orch.sh roles                    every role, its session id, live or not
#   orch.sh show                     roles plus the cron specs
#   orch.sh check-lane <role>        lane handoff fresh, sections present, no lock held, startup reading size
#   orch.sh size <role>              tokens a fresh lane must read at start (notes + handoff + CURRENT-STATE)
#   orch.sh stop-lane <role>         stop the holder's background session (kept, resumable)
#   orch.sh start-lane <role>        start a fresh background session that claims <role>
#
# Settings: ORCH_DIR (the handover dir) comes from the environment, else from
# ~/.config/agent-boss/config. Project settings live in $ORCH_DIR/agent-boss.conf
# (see templates/agent-boss.conf). Environment values win over both files.
SELF_PATH=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
TEMPLATES=$(dirname "$SELF_PATH")/templates
_env_dir=${ORCH_DIR:-}
# Config files are read as plain ORCH_NAME="value" lines, never run as shell code,
# so a handover dir you didn't write can't run commands through its config.
load_conf() {
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ORCH_*=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    case "$k" in *[!A-Z_]*) continue ;; esac
    case "$v" in \"*\") v=${v#\"}; v=${v%\"} ;; \'*\') v=${v#\'}; v=${v%\'} ;; esac
    eval "$k=\$v"
  done < "$1"
}
load_conf "$HOME/.config/agent-boss/config"
[ -n "$_env_dir" ] && ORCH_DIR=$_env_dir

if [ "$1" = "init" ]; then
  d=${2:-${ORCH_DIR:-}}
  [ -n "$d" ] || { echo "usage: orch.sh init <dir>   (or set ORCH_DIR)"; exit 2; }
  mkdir -p "$d/lane-handoffs" "$d/lane-notes" || exit 1
  for f in agent-boss.conf orchestrator-lanes.tsv orchestrator-crons.md CURRENT-STATE.md ORCHESTRATOR.md; do
    [ -e "$d/$f" ] && echo "kept $d/$f" || { cp "$TEMPLATES/$f" "$d/$f" && echo "created $d/$f"; }
  done
  [ -e "$d/session-roles.json" ] || echo "{}" > "$d/session-roles.json"
  d=$(cd "$d" && pwd)
  echo "Next: edit $d/agent-boss.conf and $d/orchestrator-lanes.tsv, then point sessions at it:"
  echo "  mkdir -p ~/.config/agent-boss && echo 'ORCH_DIR=\"$d\"' > ~/.config/agent-boss/config"
  exit 0
fi

[ -n "${ORCH_DIR:-}" ] || { echo "ORCH_DIR is not set: run 'orch.sh init <dir>' or set ORCH_DIR (env or ~/.config/agent-boss/config)"; exit 2; }
DIR=$ORCH_DIR
# Project settings; env values set before this point win.
_r=${ORCH_REPO:-}; _l=${ORCH_LOCK:-}; _h=${ORCH_SNAPSHOT_HOOK:-}; _p=${ORCH_PROJECT:-}; _u=${ORCH_USER:-}
_x=${ORCH_LANE_PROMPT_EXTRA:-}; _m=${ORCH_LANE_PERMISSION_MODE:-}; _c=${ORCH_CTX:-}; _w=${ORCH_CTX_WARN_PCT:-}
# Settings that run programs (lock, hook) come only from the environment or
# ~/.config/agent-boss/config, never from the handover dir's own conf.
# The lane permission mode is trusted-only too, so a handover dir can't raise it.
_ul=${ORCH_LOCK:-}; _uh=${ORCH_SNAPSHOT_HOOK:-}; _um=${ORCH_LANE_PERMISSION_MODE:-}
load_conf "$DIR/agent-boss.conf"
ORCH_LOCK=$_ul; ORCH_SNAPSHOT_HOOK=$_uh; ORCH_LANE_PERMISSION_MODE=$_um
REPO=${_r:-${ORCH_REPO:-}}                  # owner/name for gh PR lists; empty = skip
LOCK=${_l:-${ORCH_LOCK:-}}                  # build-lock script with a `who` command; empty = skip
HOOK=${_h:-${ORCH_SNAPSHOT_HOOK:-}}         # script whose stdout joins the snapshot (machine checks)
PROJECT=${_p:-${ORCH_PROJECT:-this project}}
USERNAME=${_u:-${ORCH_USER:-the user}}
EXTRA=${_x:-${ORCH_LANE_PROMPT_EXTRA:-}}
PERM=${_m:-${ORCH_LANE_PERMISSION_MODE:-auto}}
case "$PERM" in auto|default|acceptEdits|plan) ;; *) echo "ORCH_LANE_PERMISSION_MODE must be auto, default, acceptEdits or plan (got '$PERM')"; exit 2 ;; esac
CTX=${_c:-${ORCH_CTX:-200000}}
WARN_PCT=${_w:-${ORCH_CTX_WARN_PCT:-10}}
case "$LOCK" in ""|/*) ;; *) LOCK=$DIR/$LOCK ;; esac
case "$HOOK" in ""|/*) ;; *) HOOK=$DIR/$HOOK ;; esac

H=$DIR/ORCHESTRATOR-HANDOFF.md
ROLES=$DIR/session-roles.json
LANES=$DIR/orchestrator-lanes.tsv
SELF=${CLAUDE_CODE_SESSION_ID:-}
now() { date '+%Y-%m-%d %H:%M'; }
age_min() { python3 -c 'import os,sys,time; print(int((time.time()-os.path.getmtime(sys.argv[1]))//60))' "$1"; }
abspath() { case "$1" in /*) echo "$1" ;; "~"*) echo "$HOME${1#\~}" ;; *) echo "$DIR/$1" ;; esac; }
lane_field() { r=$(grep -v '^#' "$LANES" 2>/dev/null | awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c}'); [ -n "$r" ] && echo "$r"; }
lane_notes() { n=$(lane_field "$1" 5); [ -n "$n" ] && [ "$n" != "-" ] && abspath "$n"; }

# Startup reading = required notes + lane handoff + CURRENT-STATE, about 4 chars per token.
startup_size() {
  n=$(lane_notes "$1"); f=$(abspath "$(lane_field "$1" 3)"); b=0
  [ -n "$n" ] && [ -d "$n" ] && b=$(cat "$n"/*.md 2>/dev/null | wc -c)
  [ -f "$f" ] && b=$((b + $(wc -c < "$f")))
  [ -f "$DIR/CURRENT-STATE.md" ] && b=$((b + $(wc -c < "$DIR/CURRENT-STATE.md")))
  t=$((b / 4)); pct=$((t * 100 / CTX))
  msg="$1 startup reading: about $t tokens ($pct% of $CTX)"
  if [ $pct -ge "$WARN_PCT" ]; then echo "WARN: $msg; at or over $WARN_PCT%, raise progressive disclosure with $USERNAME"; else echo "OK: $msg"; fi
}

# py <action> <role> [arg]: all registry reads and writes, atomic, joined with live sessions
py() { ROLES="$ROLES" SELF="$SELF" NOW="$(now)" python3 - "$@" <<'PY'
import json, os, subprocess, sys
act, role, arg = (sys.argv[1:] + ["", ""])[:3]
path, me, now = os.environ["ROLES"], os.environ["SELF"], os.environ["NOW"]
try: reg = json.load(open(path))
except Exception: reg = {}
try: live = {x["sessionId"]: x for x in json.loads(subprocess.run(["claude","agents","--json"],capture_output=True,text=True).stdout) if x.get("sessionId")}
except Exception: live = {}
def alive(sid): return bool(live.get(sid, {}).get("pid"))
def addr(sid): return "uds:/tmp/cc-socks/%s.sock" % live[sid]["pid"] if alive(sid) else None
def save():
    tmp = path + ".tmp"; json.dump(reg, open(tmp, "w"), indent=2); os.replace(tmp, path)
def holder(r): return (reg.get(r) or {}).get("session")
if act in ("claim", "drop") and not me: sys.exit("no CLAUDE_CODE_SESSION_ID: run this inside the Claude session that takes the role")
if act == "claim":
    cur = holder(role)
    if cur and cur != me and alive(cur) and arg != "--force":
        sys.exit("%s is held by live session %s (%s); use --force only for a planned handoff" % (role, cur, live[cur].get("name")))
    if role == "orchestrator" and cur and cur != me:
        h = holder("orchestrator-helper")
        key = "orchestrator-helper" if not h or not alive(h) or h == cur else "orchestrator-helper-" + cur[:8]
        reg[key] = {"session": cur, "since": now, "note": "stepped down; finishes its in-flight items, then ends"}
        if key != "orchestrator-helper": print("note: a live helper already exists; old orchestrator saved as " + key)
    reg[role] = {"session": me, "since": now}; save()
    print("%s -> %s (%s)" % (role, me, addr(me) or "not visible in claude agents yet"))
elif act == "drop":
    if holder(role) != me and arg != "--force": sys.exit("%s is not held by this session" % role)
    reg.pop(role, None); save(); print("dropped", role)
elif act == "addr":
    sid = holder(role)
    if not sid: sys.exit("no holder for %s" % role)
    a = addr(sid)
    if not a: print("OFFLINE %s" % sid); sys.exit(1)
    print(a)
elif act == "sid":
    print(holder(role) or "")
elif act == "bgid":
    sid = holder(role); x = live.get(sid or "", {})
    print(x.get("id", "") if x.get("kind") == "background" and x.get("pid") else "")
elif act == "roles":
    if not reg: print("- (no roles claimed yet)")
    for r, v in sorted(reg.items()):
        sid = v.get("session", ""); x = live.get(sid, {})
        state = "live %s %s, name '%s'" % (x.get("kind"), x.get("status", "busy"), x.get("name")) if alive(sid) else "offline"
        print("- %s: %s (since %s) %s%s" % (r, sid[:8], v.get("since"), state, " -> " + addr(sid) if alive(sid) else ""))
PY
}

case "$1" in
snapshot)
  echo "## Snapshot $(now)"
  echo "- This machine: $(df -Pk "$HOME" | tail -1 | awk '{printf "%d GB free", $4/1048576}')"
  [ -n "$LOCK" ] && echo "- Lock: $("$LOCK" who 2>&1 | tr '\n' ' ')"
  [ -n "$HOOK" ] && "$HOOK" 2>&1 | sed 's/^/- /'
  if [ -n "$REPO" ]; then
    echo "- Last merged: $(gh pr list -R "$REPO" --state merged --limit 5 --json number --jq '[.[].number|"#\(.)"]|join(", ")' 2>&1)"
    echo "- Open PRs updated in the last 24 h:"
    since=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M"))')
    gh pr list -R "$REPO" --limit 50 --json number,isDraft,updatedAt,title --jq "[.[]|select(.updatedAt>\"$since\")]|.[]|\"  - #\(.number)\(if .isDraft then \" (draft)\" else \"\" end) \(.title[0:70])\"" 2>&1
  fi
  echo "- Roles:"; py roles | sed 's/^/  /' ;;
archive)
  [ -f "$H" ] || { echo "no handoff at $H"; exit 1; }
  d=$(sed -n '1s/.*(\([0-9-]*\).*/\1/p' "$H"); [ -n "$d" ] || d=$(date +%Y-%m-%d)
  t=$DIR/ORCHESTRATOR-HANDOFF-$d.md
  [ -e "$t" ] && t=$DIR/ORCHESTRATOR-HANDOFF-$d-$(date +%H%M).md
  cp "$H" "$t" && echo "archived to $t" ;;
check-handoff)
  [ -f "$H" ] || { echo "FAIL: no $H"; exit 1; }
  age=$(age_min "$H")
  bad=0; [ "$age" -gt 60 ] && { echo "FAIL: handoff is $age min old (rewrite it)"; bad=1; }
  for s in "First things" "Asking" "Machines" "Lanes" "In flight"; do
    grep -q "^## .*$s" "$H" || { echo "FAIL: missing section '## $s'"; bad=1; }; done
  [ $bad -eq 0 ] && echo "OK: handoff $age min old, all sections present"; exit $bad ;;
claim|drop) [ -n "$2" ] || { echo "usage: $1 <role>"; exit 2; }; py "$1" "$2" "$3" ;;
addr) py addr "$2" ;;
roles) py roles ;;
show) py roles; echo; cat "$DIR/orchestrator-crons.md" 2>/dev/null || echo "no cron specs" ;;
check-lane)
  f=$(lane_field "$2" 3) || { echo "unknown lane $2 (see $LANES)"; exit 2; }
  f=$(abspath "$f"); bad=0
  if [ ! -f "$f" ]; then echo "FAIL: no handoff $f"; bad=1; else
    age=$(age_min "$f")
    [ "$age" -gt 30 ] && { echo "FAIL: handoff $f is $age min old"; bad=1; }
    n=$(lane_notes "$2"); [ -n "$n" ] && [ ! -f "$n/MEMORY.md" ] && { echo "FAIL: required notes $n/MEMORY.md missing"; bad=1; }
    for s in "In flight" "Next" "Branches"; do grep -q "^## .*$s" "$f" || { echo "FAIL: $f missing '## $s'"; bad=1; }; done
  fi
  [ -n "$LOCK" ] && "$LOCK" who 2>/dev/null | grep -i -q "$2" && { echo "FAIL: $2 still holds a lock slot"; bad=1; }
  startup_size "$2"
  [ $bad -eq 0 ] && echo "OK: $2 handoff fresh, no lock held"; exit $bad ;;
size) lane_field "$2" 3 >/dev/null || { echo "unknown lane $2 (see $LANES)"; exit 2; }; startup_size "$2" ;;
stop-lane)
  id=$(py bgid "$2"); [ -n "$id" ] || { echo "the $2 holder is not a live background session (interactive ones: ask $USERNAME to close it)"; exit 1; }
  claude stop "$id" && echo "stopped $2 (session $(py sid "$2")); resume with: claude --bg --resume $(py sid "$2")" ;;
start-lane)
  m=$(lane_field "$2" 2) || { echo "unknown lane $2 (see $LANES)"; exit 2; }
  f=$(abspath "$(lane_field "$2" 3)"); cwd=$(lane_field "$2" 4); notes=$(lane_notes "$2")
  case "$cwd" in "~"*) cwd="$HOME${cwd#\~}" ;; esac
  py addr "$2" >/dev/null 2>&1 && { echo "$2 is held by a live session ($(py addr "$2")); stop it first"; exit 1; }
  case "$DIR$SELF_PATH" in *[\"\`\$\\]*) echo "refusing: ORCH_DIR or the script path contains a quote, backtick, \$ or backslash"; exit 2 ;; esac
  read_notes=""; [ -n "$notes" ] && read_notes=" Before any work, read every note in $notes (MEMORY.md first): they are this lane's standing rules from $USERNAME."
  [ -n "$EXTRA" ] && EXTRA=" $EXTRA"
  cd "${cwd:-$HOME}" && ORCH_DIR="$DIR" claude --bg -n "$2" --model "$m" --permission-mode "$PERM" \
    "You are the $2 lane for $PROJECT. First run: ORCH_DIR=\"$DIR\" sh \"$SELF_PATH\" claim $2 --force .$read_notes Then read $f and $DIR/CURRENT-STATE.md and continue from the handoff. Your orchestrator's address is the output of: ORCH_DIR=\"$DIR\" sh \"$SELF_PATH\" addr orchestrator . Message it when you start, take lane instructions only from it, and look its address up again before each message (it can change).$EXTRA" ;;
*) sed -n 6,22p "$SELF_PATH"; exit 2 ;;
esac
