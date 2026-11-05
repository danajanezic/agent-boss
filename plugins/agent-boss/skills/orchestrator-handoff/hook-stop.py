"""Stop hook body for `orch.sh hook-stop`: ask any session whose context is too big to hand off.

Reads the hook JSON on stdin and prints a {"decision": "block"} reply when a notice is due.
Env (set by orch.sh): HANDOFF_AT, HANDOFF_AGAIN_AT, DIR, ROLES, LANES, SELF_PATH,
USERNAME (who the sessions work for), HANDOFF_ADHOC (0 = no notice for sessions holding no role),
ORCH_NOTIFY (an executable that gets {"message", "cwd"} JSON on stdin for the second notice;
empty = no alert).

Each session gets at most two notices, tracked by marker files in DIR:
  .handoff-requested-<sid>   first notice, at HANDOFF_AT
  .handoff-again-<sid>       second notice, at HANDOFF_AGAIN_AT, plus the alert

The notice depends on the session's role in session-roles.json:
  orchestrator             write the handoff and start a successor
  a lane                   park, write lane-handoffs/<role>.md, tell the orchestrator, which swaps the session
  orchestrator-helper*     no notice (it is winding down anyway)
  anything else            write adhoc-handoffs/<date>-<sid8>.md and tell the user how to continue

This runs at the end of every turn in every session with the plugin enabled, so it only reads
local files: the registry, the lanes file, and the tail of this session's transcript.
"""
import glob, json, os, re, subprocess, sys, time

env = os.environ
first_at, again_at = int(env.get("HANDOFF_AT") or 0), int(env.get("HANDOFF_AGAIN_AT") or 0)
DIR, ROLES, ORCH = env["DIR"], env["ROLES"], env["SELF_PATH"]
ADHOC, NOTIFY = env.get("HANDOFF_ADHOC", "1") != "0", env.get("ORCH_NOTIFY") or ""


def a_name(s, fallback):
    """A name, not a sentence. This hook runs in EVERY session on the machine, including ones in
    projects that have nothing to do with this handover dir, and whatever it returns is printed
    into that session's context as an instruction. ORCH_USER and the role names come from files in
    the handover dir, so clamp them to something that cannot carry instructions of its own."""
    s = re.sub(r"[^A-Za-z0-9 ._'-]", " ", (s or "").strip())
    s = " ".join(s.split()[:3])[:24].strip()   # a name is a few short words, not a sentence
    return s or fallback


def in_dir(path, fallback):
    """A path under DIR, or the fallback. Keeps a handoff path out of ~/.ssh and the like, whether
    the lanes file holds an absolute path, a '..' or a symlinked route out."""
    try:
        base = os.path.realpath(DIR)
        full = os.path.realpath(os.path.join(DIR, path))
        if full == base or full.startswith(base + os.sep):
            return full
    except Exception:
        pass
    return fallback


USER = a_name(env.get("USERNAME"), "the user")
TAIL = 1 << 19  # the last usage line is always within the final 512 KB, so big transcripts stay cheap to read

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sid, tp = d.get("session_id") or "", d.get("transcript_path") or ""
if d.get("stop_hook_active") or not sid:
    sys.exit(0)
if not tp or not os.path.exists(tp):
    hits = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % sid))
    tp = max(hits, key=os.path.getmtime) if hits else ""
if not tp:
    sys.exit(0)


def ctx_tokens(path):
    """Context size of the last assistant turn: input plus both cache counts."""
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - TAIL))
        lines = f.read().decode("utf-8", "ignore").splitlines()
    for line in reversed(lines):
        if '"usage"' not in line:
            continue
        try:
            m = json.loads(line).get("message")
        except Exception:
            continue
        if isinstance(m, dict) and m.get("role") == "assistant" and isinstance(m.get("usage"), dict):
            return sum(int(m["usage"].get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return 0


try:
    reg = json.load(open(ROLES))
except Exception:
    reg = {}
held = [r for r, v in reg.items() if isinstance(v, dict) and v.get("session") == sid]
lanes = [r for r in held if not r.startswith("orchestrator-helper")]
if held and not lanes:
    sys.exit(0)  # a helper is winding down; leave it alone
role = "orchestrator" if "orchestrator" in held else lanes[0] if lanes else None
if role is not None:
    role = a_name(role, "")  # the registry is a file; a role is a label, not a path or a sentence
    if not role:
        sys.exit(0)
if role is None and not ADHOC:
    sys.exit(0)

first, again = os.path.join(DIR, ".handoff-requested-" + sid), os.path.join(DIR, ".handoff-again-" + sid)
t = ctx_tokens(tp)
if again_at and t >= again_at and os.path.exists(first) and not os.path.exists(again):
    tier = 2
elif first_at and t >= first_at and not os.path.exists(first):
    tier = 1
else:
    sys.exit(0)
limit = first_at if tier == 1 else again_at
stamp = time.strftime("%Y-%m-%d %H:%M") + "\n"
if tier == 1:
    open(first, "w").write(stamp)
    if again_at and t >= again_at:
        open(again, "w").write(stamp)  # past both limits in one turn: one notice is enough
else:
    open(again, "w").write(stamp)

head = "Your context is %d tokens, over the automatic handoff limit of %d." % (t, limit)
if tier == 2:
    head = ("Second notice. Your context is %d tokens, over the second handoff limit of %d, and every further turn "
            "re-reads all of it." % (t, limit))

if role == "orchestrator":
    body = ("Hand off now: follow the orchestrator-handoff skill section Automatic handoff (park the current step, "
            "step-down steps 1-5, then run %s start-successor), then tell %s in one line that a new orchestrator "
            "is starting." % (ORCH, USER))
elif role:
    path = os.path.join(DIR, "lane-handoffs", role + ".md")
    try:  # the lanes file names each lane's handoff in column 3; it must stay inside DIR
        for row in open(env.get("LANES") or os.devnull):
            c = row.rstrip("\n").split("\t")
            if not row.startswith("#") and len(c) > 2 and c[0] == role and c[2].strip():
                path = in_dir(c[2].strip(), path)
    except Exception:
        pass
    body = ("Ask your orchestrator for a fresh %s session. (1) Finish or park your current step and start nothing new. "
            "(2) Commit and push every worktree you changed, and release any lock slot you hold. "
            "(3) Write %s with ## Doing, ## In flight (runs and subagents with their IDs), ## Branches (branch, head, "
            "PR, test run), ## Next and ## Gotchas. (4) Message the orchestrator that %s is parked, with the handoff "
            "path and what is in flight (its address is the output of: %s addr orchestrator). Then go idle: the "
            "orchestrator stops this session with stop-lane and starts a fresh one with start-lane. Do not stop "
            "yourself." % (role, path, role, ORCH))
else:
    tag = re.sub(r"[^A-Za-z0-9-]", "", sid)[:8] or "session"
    path = os.path.join(DIR, "adhoc-handoffs", "%s-%s.md" % (time.strftime("%Y-%m-%d"), tag))
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    except Exception:
        pass
    body = ("Hand off now. (1) Finish or park the current step and start nothing new. (2) Commit and push any worktree "
            "you changed. (3) Write %s with ## Doing, ## In flight, ## Branches, ## Next and ## Gotchas, enough for a "
            "fresh session to continue without this conversation. (4) Tell %s in one line your context size and how to "
            "continue in a fresh session: Read %s and continue from it." % (path, USER, path))
tail = (" If you already did this, say so in one line and stop. If %s asked you to keep going, say that in one line "
        "and continue." % USER) if tier == 2 else ""

if tier == 2 and NOTIFY:  # an alert script can skip itself while the user is at the keyboard, and rate-limit itself
    try:
        p = subprocess.Popen([NOTIFY], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        p.stdin.write(json.dumps({"message": "%s session at %d tokens, asked twice to hand off" % (role or "ad hoc", t),
                                  "cwd": d.get("cwd") or ""}))
        p.stdin.close()
    except Exception:
        pass
print(json.dumps({"decision": "block", "reason": head + " " + body + tail}))
