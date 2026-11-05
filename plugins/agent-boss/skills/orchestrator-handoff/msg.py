"""msg: a role mailbox for a team of Claude Code sessions (sqlite, WAL). Run it as `orch.sh msg ...`.

  msg send <to> [--from R] [--reply-to ID] [--urgent] [text|stdin]
  msg check <role>            one-shot (for a cron): prints new messages, marks them delivered, silent if none
  msg watch <role>            long-running; one line per message: MSG <id> from=<r> [re=<id>] <text>
  msg inbox <role> [--all] | show <id> | reply <id> [text] | ack <id>
  msg log [--role R] [--since HH:MM|ISO] [--thread ID] | stale [--min 10] [--brief]

A message is addressed to a ROLE, not a session, so it waits in the mailbox while a lane is
offline, parked or being swapped, and the replacement session collects it on its first check.
Every message is kept, so the history is readable.

Env (orch.sh sets these): MSG_DB (the sqlite file), MSG_ROLES_FILE (session-roles.json),
MSG_EXTRA_ROLES (comma-separated senders that are not lanes, default "script,all"),
MSG_POLL_SEC (watch poll interval, default 2).
"""
import argparse, datetime as dt, json, os, sqlite3, sys, time

DB = os.environ.get("MSG_DB", "")
ROLES_FILE = os.environ.get("MSG_ROLES_FILE", "")
FIXED = {r.strip() for r in os.environ.get("MSG_EXTRA_ROLES", "script,all").split(",") if r.strip()} | {"script", "all"}
LONG = 400


def now():
    return dt.datetime.now().isoformat(timespec="seconds")


def conn():
    if not DB:
        sys.exit("MSG_DB is not set (run this through orch.sh msg)")
    d = os.path.dirname(DB)
    if d:
        os.makedirs(d, exist_ok=True)
    c = sqlite3.connect(DB, timeout=30, isolation_level=None)
    c.row_factory = sqlite3.Row
    # WAL and a long busy timeout: a whole team of sessions and their crons write to this file.
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA busy_timeout=30000")
    c.execute("""CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT NOT NULL,
        reply_to INTEGER, thread INTEGER, urgent INTEGER DEFAULT 0, body TEXT NOT NULL,
        delivered_at TEXT, acked_at TEXT)""")
    c.execute("CREATE INDEX IF NOT EXISTS ix_rcpt ON messages(recipient, delivered_at)")
    return c


def roles():
    try:
        return json.load(open(ROLES_FILE))
    except Exception:
        return {}


def known_roles():
    return set(roles()) | FIXED


def my_role():
    """This session's role, from its own session id in the registry."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    for r, v in roles().items():
        if sid and isinstance(v, dict) and v.get("session") == sid:
            return r
    return "script"


def check_role(r):
    # An unknown recipient fails loudly here, rather than queueing a message nobody will collect.
    if r not in known_roles():
        sys.exit("unknown role %r; known: %s" % (r, ", ".join(sorted(known_roles()))))


def lane_roles():
    return sorted(r for r in roles() if r not in FIXED)


def one_line(m):
    text = " ".join(m["body"].split())
    if len(text) > LONG:
        text = text[:LONG] + "... (msg show %d)" % m["id"]
    re_ = " re=%s" % m["reply_to"] if m["reply_to"] else ""
    urg = " URGENT" if m["urgent"] else ""
    return "MSG %s from=%s%s%s %s" % (m["id"], m["sender"], re_, urg, text)


def get_text(t):
    if t:
        return " ".join(t)
    if not sys.stdin.isatty():
        s = sys.stdin.read().strip()
        if s:
            return s
    sys.exit("no text (give it as an argument or on stdin)")


def insert(c, to, sender, body, reply_to=None, urgent=False):
    thread = None
    if reply_to:
        p = c.execute("SELECT id, thread FROM messages WHERE id=?", (reply_to,)).fetchone()
        if not p:
            sys.exit("no message %s" % reply_to)
        thread = p["thread"] or p["id"]
    targets = [r for r in lane_roles() if r != sender] if to == "all" else [to]
    ids = []
    for r in targets:
        cur = c.execute("INSERT INTO messages(ts,sender,recipient,reply_to,thread,urgent,body) VALUES(?,?,?,?,?,?,?)",
                        (now(), sender, r, reply_to, thread, int(urgent), body))
        ids.append(cur.lastrowid)
        if thread is None:
            c.execute("UPDATE messages SET thread=id WHERE id=?", (cur.lastrowid,))
    return ids


def cmd_send(a):
    check_role(a.to)
    sender = a.sender or my_role()
    check_role(sender)
    print(" ".join(map(str, insert(conn(), a.to, sender, get_text(a.text), a.reply_to, a.urgent))))


def cmd_reply(a):
    c = conn()
    m = c.execute("SELECT * FROM messages WHERE id=?", (a.id,)).fetchone()
    if not m:
        sys.exit("no message %s" % a.id)
    sender = a.sender or my_role()
    print(" ".join(map(str, insert(c, m["sender"], sender, get_text(a.text), a.id))))


def claim(c, role):
    """Atomically take the undelivered messages for a role, so a second checker or watcher never
    delivers the same message twice."""
    c.execute("BEGIN IMMEDIATE")
    try:
        rows = c.execute("SELECT * FROM messages WHERE recipient=? AND delivered_at IS NULL ORDER BY id",
                         (role,)).fetchall()
        if rows:
            c.executemany("UPDATE messages SET delivered_at=? WHERE id=?", [(now(), r["id"]) for r in rows])
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise
    return rows


def cmd_watch(a):
    check_role(a.role)
    c = conn()
    poll = float(os.environ.get("MSG_POLL_SEC", "2"))
    while True:
        try:
            for m in claim(c, a.role):
                print(one_line(m), flush=True)
        except sqlite3.OperationalError as e:
            print("msg watch: db busy (%s); retrying" % e, file=sys.stderr)
        time.sleep(poll)


def cmd_check(a):
    check_role(a.role)
    for m in claim(conn(), a.role):
        print(one_line(m))


def cmd_inbox(a):
    q = "SELECT * FROM messages WHERE recipient=?" + ("" if a.all else " AND acked_at IS NULL") + " ORDER BY id"
    for m in conn().execute(q, (a.role,)):
        st = "acked" if m["acked_at"] else ("delivered" if m["delivered_at"] else "new")
        print("%s [%s] %s" % (m["ts"], st, one_line(m)))


def cmd_show(a):
    m = conn().execute("SELECT * FROM messages WHERE id=?", (a.id,)).fetchone()
    if not m:
        sys.exit("no message %s" % a.id)
    for k in ("id", "ts", "sender", "recipient", "reply_to", "thread", "urgent", "delivered_at", "acked_at"):
        print("%s: %s" % (k, m[k]))
    print("\n" + m["body"])


def cmd_ack(a):
    c = conn()
    n = c.execute("UPDATE messages SET acked_at=?, delivered_at=COALESCE(delivered_at,?) WHERE id=?",
                  (now(), now(), a.id)).rowcount
    if not n:
        sys.exit("no message %s" % a.id)
    print("acked %s" % a.id)


def parse_since(s):
    if "T" in s or "-" in s:
        return s
    return dt.date.today().isoformat() + "T" + (s if s.count(":") == 2 else s + ":00")


def cmd_log(a):
    q, p = "SELECT * FROM messages WHERE 1=1", []
    if a.role:
        q += " AND (sender=? OR recipient=?)"
        p += [a.role, a.role]
    if a.since:
        q += " AND ts>=?"
        p.append(parse_since(a.since))
    if a.thread:
        q += " AND thread=(SELECT COALESCE(thread,id) FROM messages WHERE id=?)"
        p.append(a.thread)
    for m in conn().execute(q + " ORDER BY id", p):
        print("%s to=%s %s" % (m["ts"], m["recipient"], one_line(m)))


def cmd_stale(a):
    """Roles with messages nobody has collected: usually a lane whose delivery cron died."""
    cut = (dt.datetime.now() - dt.timedelta(minutes=a.min)).isoformat(timespec="seconds")
    rows = conn().execute("""SELECT recipient, COUNT(*) n, MIN(ts) oldest FROM messages
        WHERE delivered_at IS NULL AND ts<=? GROUP BY recipient ORDER BY recipient""", (cut,)).fetchall()
    for r in rows:
        age = int((dt.datetime.now() - dt.datetime.fromisoformat(r["oldest"])).total_seconds() // 60)
        print(r["recipient"] if a.brief else "%s %d oldest=%dm" % (r["recipient"], r["n"], age))


def main():
    ap = argparse.ArgumentParser(prog="msg", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("send"); s.add_argument("to"); s.add_argument("text", nargs="*")
    s.add_argument("--from", dest="sender"); s.add_argument("--reply-to", type=int); s.add_argument("--urgent", action="store_true")
    s.set_defaults(f=cmd_send)
    s = sp.add_parser("watch"); s.add_argument("role"); s.set_defaults(f=cmd_watch)
    s = sp.add_parser("check"); s.add_argument("role"); s.set_defaults(f=cmd_check)
    s = sp.add_parser("inbox"); s.add_argument("role"); s.add_argument("--all", action="store_true"); s.set_defaults(f=cmd_inbox)
    s = sp.add_parser("show"); s.add_argument("id", type=int); s.set_defaults(f=cmd_show)
    s = sp.add_parser("reply"); s.add_argument("id", type=int); s.add_argument("text", nargs="*")
    s.add_argument("--from", dest="sender"); s.set_defaults(f=cmd_reply)
    s = sp.add_parser("ack"); s.add_argument("id", type=int); s.set_defaults(f=cmd_ack)
    s = sp.add_parser("log"); s.add_argument("--role"); s.add_argument("--since"); s.add_argument("--thread", type=int)
    s.set_defaults(f=cmd_log)
    s = sp.add_parser("stale"); s.add_argument("--min", type=int, default=10); s.add_argument("--brief", action="store_true")
    s.set_defaults(f=cmd_stale)
    a = ap.parse_args()
    a.f(a)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
