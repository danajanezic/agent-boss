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
#   orch.sh context [transcript]     this session's context size, against ORCH_HANDOFF_AT
#   orch.sh start-successor          start a fresh background orchestrator to take over from this one
#   orch.sh hook-stop                Stop hook: ask the orchestrator to hand off once over ORCH_HANDOFF_AT
#   orch.sh lanes                    list the lanes in orchestrator-lanes.tsv
#   orch.sh add-lane <role> <model> <dir> <job>  add a lane row (see /agent-boss:define-role)
#   orch.sh brief <role>             what a subagent needs to act as <role> (model, dir, files to read)
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
_x=${ORCH_LANE_PROMPT_EXTRA:-}; _ha=${ORCH_HANDOFF_AT:-}; _om=${ORCH_ORCHESTRATOR_MODEL:-}; _m=${ORCH_LANE_PERMISSION_MODE:-}; _c=${ORCH_CTX:-}; _w=${ORCH_CTX_WARN_PCT:-}
# Settings that run programs (lock, hook) come only from the environment or
# ~/.config/agent-boss/config, never from the handover dir's own conf.
# The lane permission mode and the successor's start dir are trusted-only too, so a handover dir can't raise them.
_ul=${ORCH_LOCK:-}; _uh=${ORCH_SNAPSHOT_HOOK:-}; _um=${ORCH_LANE_PERMISSION_MODE:-}; _ud=${ORCH_ORCHESTRATOR_DIR:-}
load_conf "$DIR/agent-boss.conf"
ORCH_LOCK=$_ul; ORCH_SNAPSHOT_HOOK=$_uh; ORCH_LANE_PERMISSION_MODE=$_um; ORCH_ORCHESTRATOR_DIR=$_ud
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
HANDOFF_AT=${_ha:-${ORCH_HANDOFF_AT:-150000}}       # orchestrator context tokens that trigger an automatic handoff; 0 = off
ORCH_MODEL=${_om:-${ORCH_ORCHESTRATOR_MODEL:-opus}}
case "$LOCK" in ""|/*) ;; *) LOCK=$DIR/$LOCK ;; esac
case "$HOOK" in ""|/*) ;; *) HOOK=$DIR/$HOOK ;; esac

H=$DIR/ORCHESTRATOR-HANDOFF.md
ROLES=$DIR/session-roles.json
LANES=$DIR/orchestrator-lanes.tsv
SELF=${CLAUDE_CODE_SESSION_ID:-}
now() { date '+%Y-%m-%d %H:%M'; }
age_min() { python3 -I -c 'import os,sys,time; print(int((time.time()-os.path.getmtime(sys.argv[1]))//60))' "$1"; }
abspath() { case "$1" in /*) echo "$1" ;; "~"*) echo "$HOME${1#\~}" ;; *) echo "$DIR/$1" ;; esac; }
lane_field() { r=$(grep -v '^#' "$LANES" 2>/dev/null | awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c}'); [ -n "$r" ] && echo "$r"; }
# ctx_tokens [transcript]: context size of the last assistant turn (input + cache read + cache write).
ctx_tokens() {
  python3 -I - "${1:-}" "$SELF" <<'PY'
import glob, json, os, sys
path, sid = sys.argv[1], sys.argv[2]
if not path and sid:
    hits = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % sid))
    path = max(hits, key=os.path.getmtime) if hits else ""
if not path or not os.path.exists(path): sys.exit("no transcript found (pass a path, or run inside a Claude session)")
last = None
with open(path) as f:
    for line in f:
        if '"usage"' not in line: continue
        try: m = json.loads(line).get("message")
        except Exception: continue
        if isinstance(m, dict) and m.get("role") == "assistant" and isinstance(m.get("usage"), dict): last = m["usage"]
if not last: print(0); sys.exit(0)
print(sum(int(last.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")))
PY
}
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
py() { ROLES="$ROLES" SELF="$SELF" NOW="$(now)" python3 -I - "$@" <<'PY'
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
    since=$(python3 -I -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M"))')
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
context)
  t=$(ctx_tokens "$2") || exit 1
  echo "context: $t tokens (automatic orchestrator handoff at $HANDOFF_AT)" ;;
hook-stop)
  # Stop hook: if this session is the orchestrator and its context is over ORCH_HANDOFF_AT,
  # keep it working with an instruction to hand off (once per session). Reads only local
  # files (no claude agents call), so it stays fast at the end of every turn.
  [ "$HANDOFF_AT" -gt 0 ] 2>/dev/null || exit 0
  HANDOFF_AT=$HANDOFF_AT ROLES=$ROLES DIR=$DIR USERNAME=$USERNAME python3 -I -c '
import glob, json, os, sys, time
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
sid, tp = d.get("session_id") or "", d.get("transcript_path") or ""
if d.get("stop_hook_active") or not sid: sys.exit(0)
try: reg = json.load(open(os.environ["ROLES"]))
except Exception: sys.exit(0)
if (reg.get("orchestrator") or {}).get("session") != sid: sys.exit(0)
mark = os.path.join(os.environ["DIR"], ".handoff-requested-" + sid)
if os.path.exists(mark): sys.exit(0)
if not tp or not os.path.exists(tp):
    hits = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % sid)); tp = max(hits, key=os.path.getmtime) if hits else ""
if not tp: sys.exit(0)
last = None
for line in open(tp):
    if "\"usage\"" not in line: continue
    try: m = json.loads(line).get("message")
    except Exception: continue
    if isinstance(m, dict) and m.get("role") == "assistant" and isinstance(m.get("usage"), dict): last = m["usage"]
t = sum(int((last or {}).get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
lim = int(os.environ["HANDOFF_AT"])
if t < lim: sys.exit(0)
open(mark, "w").write(time.strftime("%Y-%m-%d %H:%M") + "\n")
print(json.dumps({"decision": "block", "reason": "Your context is at %d tokens, over the automatic handoff limit of %d. Hand off now: follow the orchestrator-handoff skill section Automatic handoff (park the current step, step-down steps 1-5, then run orch start-successor), then tell %s in one line that a new orchestrator is starting." % (t, lim, os.environ["USERNAME"])}))
' ;;
start-successor)
  # Start a fresh background orchestrator that takes over from this one.
  [ -n "$SELF" ] || { echo "run this inside the orchestrator session"; exit 2; }
  [ "$(py sid orchestrator)" = "$SELF" ] || { echo "refusing: this session doesn't hold the orchestrator role"; exit 1; }
  sh "$SELF_PATH" check-handoff || { echo "refusing: fix the handoff first"; exit 1; }
  mark=$DIR/.successor-started-$SELF; [ -e "$mark" ] && { echo "a successor was already started at $(cat "$mark"); check orch roles"; exit 1; }
  case "$DIR$SELF_PATH" in *[\"\`\$\\]*) echo "refusing: ORCH_DIR or the script path contains a quote, backtick, \$ or backslash"; exit 2 ;; esac
  # Start where this orchestrator runs (already trusted); a background session can't answer a trust prompt.
  sdir=${ORCH_ORCHESTRATOR_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}; case "$sdir" in "~"*) sdir="$HOME${sdir#\~}" ;; esac
  case "$sdir" in *[\"\`\$\\]*) echo "refusing: the start dir contains a quote, backtick, \$ or backslash"; exit 2 ;; esac
  cd "$sdir" || exit 1
  ORCH_DIR="$DIR" claude --bg -n orchestrator --model "$ORCH_MODEL" --permission-mode "$PERM" \
    "Take over as orchestrator for $PROJECT: follow the Take-over steps in $(dirname "$SELF_PATH")/SKILL.md (the orchestrator-handoff skill). The handover dir is $DIR (ORCH_DIR), and its script is: ORCH_DIR=\"$DIR\" sh \"$SELF_PATH\" . The previous orchestrator is session $SELF; it stays up as helper until you message it.$EXTRA" \
    && { date '+%Y-%m-%d %H:%M' > "$mark"; echo "started a successor orchestrator in $sdir; it will claim the role and message this session"; } ;;
lanes)
  [ -f "$LANES" ] || { echo "no lanes file at $LANES"; exit 1; }
  grep -v '^#' "$LANES" | awk -F'\t' 'NF{printf "- %s (%s): %s\n", $1, $2, $6}' ;;
add-lane)
  # add-lane <role> <model> <start dir> <job>: one row, with handoff lane-handoffs/<role>.md and notes lane-notes/<role>
  case "$2" in ""|*[!a-z0-9-]*) echo "usage: add-lane <role> <model> <start dir> <job>   (role: lowercase letters, digits and -)"; exit 2 ;; esac
  case "$2" in orchestrator|orchestrator-helper*) echo "refusing: $2 is a built-in role"; exit 2 ;; esac
  [ -n "$3" ] && [ -n "$4" ] && [ -n "$5" ] || { echo "usage: add-lane <role> <model> <start dir> <job>"; exit 2; }
  for v in "$3" "$4" "$5"; do case "$v" in *"$(printf '\t')"*|*"
"*) echo "refusing: fields can't contain tabs or newlines"; exit 2 ;; esac; done
  [ -f "$LANES" ] || cp "$TEMPLATES/orchestrator-lanes.tsv" "$LANES"
  lane_field "$2" 1 >/dev/null && { echo "lane $2 already exists in $LANES; edit that row instead"; exit 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "lane-handoffs/$2.md" "$4" "lane-notes/$2" "$5" >> "$LANES"
  mkdir -p "$DIR/lane-handoffs" "$DIR/lane-notes/$2"
  echo "added $2 to $LANES; notes go in $DIR/lane-notes/$2/ (MEMORY.md first), handoff in $DIR/lane-handoffs/$2.md" ;;
brief)
  # Everything a subagent needs to act as <role>: model, start dir, files to read, and who holds the role now.
  case "$2" in ""|*[!A-Za-z0-9_-]*) echo "usage: brief <role> (letters, digits, - and _ only)"; exit 2 ;; esac
  m=$(lane_field "$2" 2) || { echo "unknown lane $2 (see $LANES)"; exit 2; }
  cwd=$(lane_field "$2" 4); case "$cwd" in "~"*) cwd="$HOME${cwd#\~}" ;; esac
  n=$(lane_notes "$2"); f=$(abspath "$(lane_field "$2" 3)")
  echo "role: $2"; echo "project: $PROJECT"; echo "user: $USERNAME"; echo "model: $m"
  echo "start dir: ${cwd:-$HOME}"; echo "job: $(lane_field "$2" 6)"
  echo "read first:"
  if [ -n "$n" ] && [ -d "$n" ]; then [ -f "$n/MEMORY.md" ] && echo "  $n/MEMORY.md"; for x in "$n"/*.md; do [ "$x" = "$n/MEMORY.md" ] || { [ -f "$x" ] && echo "  $x"; }; done; fi
  [ -f "$f" ] && echo "  $f" || echo "  (no handoff yet at $f)"
  [ -f "$DIR/CURRENT-STATE.md" ] && echo "  $DIR/CURRENT-STATE.md"
  [ -n "$EXTRA" ] && echo "house rules: $EXTRA"
  a=$(py addr "$2" 2>/dev/null) && echo "live holder: $a (a lane session already holds $2; warn the user before overlapping its work)" || echo "live holder: none"
  startup_size "$2" ;;
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
*) sed -n 7,28p "$SELF_PATH"; exit 2 ;;
esac
