"""Build and refresh the document index: a sqlite FTS5 database over a project's own writing.

    python3 indexer.py --db <file> refresh --root docs=./docs --root notes=~/code/proj-handover
    python3 indexer.py --db <file> refresh --root docs=./docs --github owner/repo
    python3 indexer.py --db <file> status

A root is <kind>=<path>: the kind is a label that comes back with every result, so a session can
tell a spec from a handover note. Refresh is incremental: a file whose size, mtime and digest are
unchanged is left alone, and a file that has disappeared is removed along with its chunks.

Nothing here reaches the network except `--github owner/repo`, which shells out to `gh` and is
skipped when `gh` is missing or not logged in.
"""
import argparse, hashlib, json, os, re, sqlite3, subprocess, sys, time

TEXT_SUFFIXES = {".md", ".markdown", ".txt", ".rst", ".tsv", ".csv", ".org"}
SKIP_DIRS = {".git", "node_modules", "target", "build", "dist", "__pycache__", ".venv", ".claude"}
MAX_BYTES = 2 << 20          # 2 MB: past that it is data, not writing
CHUNK_CHARS = 1800           # about 450 tokens, so three chunks still make a compact answer
CHUNK_OVERLAP = 200

# A decision is a line a human marked as one. Keep this loose: projects write them differently.
DECISION_RE = re.compile(
    r"(?im)^\s*(?:[-*]\s*)?(?:\*\*)?(?:decision|decided|ruling|agreed)(?:\*\*)?\s*[:—-]\s*(.+?)\s*$")
# "Decided 2026-11-04 by Dana." trailing attribution, pulled out of the decision text when present.
WHEN_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
WHO_RE = re.compile(r"\bby\s+([A-Z][A-Za-z.'-]{1,20}(?:\s+[A-Z][A-Za-z.'-]{1,20})?)")

SCHEMA = """
CREATE TABLE IF NOT EXISTS sources(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    root TEXT NOT NULL,              -- the kind label the root was given
    path TEXT NOT NULL UNIQUE,       -- absolute for files, owner/repo#123 for GitHub
    title TEXT NOT NULL,
    digest TEXT NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    modified INTEGER NOT NULL DEFAULT 0,
    indexed_at TEXT NOT NULL,
    kind TEXT NOT NULL,              -- doc | issue | pull-request | comment
    meta TEXT NOT NULL DEFAULT '{}');
CREATE TABLE IF NOT EXISTS chunks(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    ord INTEGER NOT NULL,
    heading TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS ix_chunk_src ON chunks(source_id);
CREATE TABLE IF NOT EXISTS decisions(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    topic TEXT NOT NULL,             -- the heading it sits under: what the decision is about
    text TEXT NOT NULL,
    decided_on TEXT NOT NULL DEFAULT '',
    decided_by TEXT NOT NULL DEFAULT '',
    line INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS ix_dec_topic ON decisions(topic);
CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
    body, heading, title, path UNINDEXED, chunk_id UNINDEXED, tokenize='porter unicode61');
CREATE TABLE IF NOT EXISTS state(k TEXT PRIMARY KEY, v TEXT NOT NULL);
"""


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def connect(db):
    d = os.path.dirname(os.path.abspath(db))
    if d:
        os.makedirs(d, exist_ok=True)
    c = sqlite3.connect(db, timeout=30, isolation_level=None)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA busy_timeout=30000")
    c.execute("PRAGMA foreign_keys=ON")
    c.executescript(SCHEMA)
    return c


def digest(text):
    return hashlib.sha256(text.encode("utf-8", "ignore")).hexdigest()[:32]


def title_of(text, fallback):
    for line in text.splitlines():
        if line.startswith("#"):
            t = line.lstrip("#").strip()
            if t:
                return t[:200]
        if line.strip():
            break
    return fallback


def split_chunks(text):
    """Split on markdown headings, then on size, so a chunk is quotable and carries its heading."""
    parts, heading, buf = [], "", []
    for line in text.splitlines():
        if line.startswith("#"):
            if any(x.strip() for x in buf):
                parts.append((heading, "\n".join(buf).strip()))
            heading, buf = line.lstrip("#").strip()[:200], []
        else:
            buf.append(line)
    if any(x.strip() for x in buf):
        parts.append((heading, "\n".join(buf).strip()))
    out = []
    for h, body in parts:
        if len(body) <= CHUNK_CHARS:
            out.append((h, body))
            continue
        i = 0
        while i < len(body):
            out.append((h, body[i:i + CHUNK_CHARS]))
            i += CHUNK_CHARS - CHUNK_OVERLAP
    return out or [("", text[:CHUNK_CHARS])]


def find_decisions(text, trusted_author=None):
    """Marked decision lines, with the heading they sit under and any date or name on the line.

    `trusted_author`, when given, overrides whatever name the line claims. A decision's weight
    comes from who made it, so for anything that arrives from outside the repository the authority
    is the author the API reports, never the "by X" somebody typed into the text.
    """
    found, heading = [], ""
    today = time.strftime("%Y-%m-%d")
    for n, line in enumerate(text.splitlines(), 1):
        if line.startswith("#"):
            heading = line.lstrip("#").strip()[:200]
            continue
        m = DECISION_RE.match(line)
        if not m:
            continue
        body = m.group(1).strip()
        when = WHEN_RE.search(body)
        who = WHO_RE.search(body)
        on = when.group(1) if when else ""
        if on > today:
            on = ""   # a date in the future cannot order anything; treat the line as undated
        found.append({"topic": heading, "text": body[:800], "line": n, "decided_on": on,
                      "decided_by": trusted_author or (who.group(1) if who else "")})
    return found


def put_source(c, root, path, title, text, kind, meta, size=0, modified=0,
               decisions=True, decision_author=None):
    """Insert or update one source and everything derived from it. Returns 'new', 'updated', 'same'.

    `decisions=False` indexes the text for search but records no decisions from it. Use it for
    anything a stranger can write: a comment on a public issue is worth searching and is not
    evidence of what the project decided.
    """
    dg = digest(text)
    row = c.execute("SELECT id, digest FROM sources WHERE path=?", (path,)).fetchone()
    if row and row["digest"] == dg:
        c.execute("UPDATE sources SET indexed_at=? WHERE id=?", (now(), row["id"]))
        return "same"
    c.execute("BEGIN IMMEDIATE")
    try:
        if row:
            sid = row["id"]
            for cid, in c.execute("SELECT id FROM chunks WHERE source_id=?", (sid,)).fetchall():
                c.execute("DELETE FROM search WHERE chunk_id=?", (cid,))
            c.execute("DELETE FROM chunks WHERE source_id=?", (sid,))
            c.execute("DELETE FROM decisions WHERE source_id=?", (sid,))
            c.execute("""UPDATE sources SET root=?, title=?, digest=?, size=?, modified=?,
                         indexed_at=?, kind=?, meta=? WHERE id=?""",
                      (root, title, dg, size, modified, now(), kind, json.dumps(meta), sid))
            state = "updated"
        else:
            cur = c.execute("""INSERT INTO sources(root,path,title,digest,size,modified,indexed_at,kind,meta)
                               VALUES(?,?,?,?,?,?,?,?,?)""",
                            (root, path, title, dg, size, modified, now(), kind, json.dumps(meta)))
            sid = cur.lastrowid
            state = "new"
        for i, (h, body) in enumerate(split_chunks(text)):
            cid = c.execute("INSERT INTO chunks(source_id,ord,heading,body) VALUES(?,?,?,?)",
                            (sid, i, h, body)).lastrowid
            c.execute("INSERT INTO search(body,heading,title,path,chunk_id) VALUES(?,?,?,?,?)",
                      (body, h, title, path, cid))
        for d in (find_decisions(text, decision_author) if decisions else []):
            c.execute("""INSERT INTO decisions(source_id,topic,text,decided_on,decided_by,line)
                         VALUES(?,?,?,?,?,?)""",
                      (sid, d["topic"], d["text"], d["decided_on"], d["decided_by"], d["line"]))
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise
    return state


def walk_root(c, kind, path, counts):
    base = os.path.abspath(os.path.expanduser(path))
    if not os.path.isdir(base):
        if os.path.isfile(base):
            index_file(c, kind, base, counts)
            return
        print("  skipped %s: no such directory" % base, file=sys.stderr)
        return
    # followlinks stays off, and symlinked files are skipped as well: a link in a docs directory
    # can point at ~/.ssh/id_rsa, and indexing it would copy the contents into a database that a
    # session can then search. Anything whose real path leaves the root is skipped too.
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and not d.startswith(".")
                       and not os.path.islink(os.path.join(dirpath, d))]
        for fn in filenames:
            if os.path.splitext(fn)[1].lower() not in TEXT_SUFFIXES:
                continue
            full = os.path.join(dirpath, fn)
            if os.path.islink(full):
                counts["symlink skipped"] = counts.get("symlink skipped", 0) + 1
                continue
            if not os.path.realpath(full).startswith(base + os.sep):
                counts["outside the root"] = counts.get("outside the root", 0) + 1
                continue
            index_file(c, kind, full, counts)


def index_file(c, kind, full, counts):
    try:
        if os.path.islink(full):
            counts["symlink skipped"] = counts.get("symlink skipped", 0) + 1
            return
        st = os.stat(full)
        if st.st_size > MAX_BYTES:
            counts["too big"] = counts.get("too big", 0) + 1
            return
        with open(full, "r", encoding="utf-8", errors="ignore") as f:
            text = f.read()
    except Exception as e:
        print("  skipped %s: %s" % (full, e), file=sys.stderr)
        return
    if not text.strip():
        return
    state = put_source(c, kind, full, title_of(text, os.path.basename(full)), text, "doc",
                       {"name": os.path.basename(full)}, st.st_size, int(st.st_mtime))
    counts[state] = counts.get(state, 0) + 1


def index_github(c, repo, counts, limit=200):
    """Issues and pull requests with their comments, through the gh CLI. Skipped when gh cannot."""
    def gh(args):
        p = subprocess.run(["gh"] + args, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(p.stderr.strip()[:200] or "gh failed")
        return json.loads(p.stdout or "[]")

    try:
        items = []
        for what in ("issue", "pr"):
            items += [(what, x) for x in gh([what, "list", "-R", repo, "--state", "all",
                                             "--limit", str(limit), "--json",
                                             "number,title,body,state,updatedAt,comments,"
                                             "author,authorAssociation"])]
    except Exception as e:
        print("  GitHub skipped for %s: %s" % (repo, e), file=sys.stderr)
        counts["github skipped"] = 1
        return
    for what, it in items:
        path = "%s#%s" % (repo, it["number"])
        kind = "issue" if what == "issue" else "pull-request"
        author = ((it.get("author") or {}).get("login")) or ""
        # Anyone can open an issue on a public repository and type "Decision: ... by <someone>".
        # Only an insider's OWN body may carry a decision, and it is attributed to the login the
        # API reports, not to the name in the text. Comments are indexed for search either way:
        # worth finding, never evidence of what the project decided.
        insider = (it.get("authorAssociation") or "").upper() in ("OWNER", "MEMBER", "COLLABORATOR")
        own_body = "# %s\n\n%s" % (it.get("title") or path, it.get("body") or "")
        parts = [own_body]
        for cm in (it.get("comments") or []):
            who = ((cm.get("author") or {}).get("login")) or "someone"
            parts.append("\n--- comment from %s (comments are not decisions)\n%s"
                         % (who, cm.get("body") or ""))
        # The decision scan runs over the body only, so a comment can never contribute one.
        state = put_source(c, "github", path, (it.get("title") or path)[:200],
                           "\n\n".join(parts), kind,
                           {"number": it["number"], "state": it.get("state"),
                            "updated": it.get("updatedAt"), "repo": repo, "author": author,
                            "author_association": it.get("authorAssociation"),
                            "decisions_trusted": insider},
                           decisions=False)
        if insider and state != "same":
            for d in find_decisions(own_body, author or None):
                sid = c.execute("SELECT id FROM sources WHERE path=?", (path,)).fetchone()["id"]
                c.execute("""INSERT INTO decisions(source_id,topic,text,decided_on,decided_by,line)
                             VALUES(?,?,?,?,?,?)""",
                          (sid, d["topic"] or path, d["text"], d["decided_on"], d["decided_by"],
                           d["line"]))
        counts[state] = counts.get(state, 0) + 1


def prune(c, counts):
    """Forget files that are gone. GitHub sources are left alone: a closed issue is still history."""
    for row in c.execute("SELECT id, path FROM sources WHERE root != 'github'").fetchall():
        if not os.path.exists(row["path"]):
            for cid, in c.execute("SELECT id FROM chunks WHERE source_id=?", (row["id"],)).fetchall():
                c.execute("DELETE FROM search WHERE chunk_id=?", (cid,))
            c.execute("DELETE FROM sources WHERE id=?", (row["id"],))
            counts["gone"] = counts.get("gone", 0) + 1


def cmd_refresh(a):
    c = connect(a.db)
    counts = {}
    for spec in a.root or []:
        kind, _, path = spec.partition("=")
        if not path:
            sys.exit("a root is <kind>=<path>, for example docs=./docs (got %r)" % spec)
        print("indexing %s: %s" % (kind, path))
        walk_root(c, kind, path, counts)
    for repo in a.github or []:
        print("indexing github: %s" % repo)
        index_github(c, repo, counts, a.github_limit)
    prune(c, counts)
    c.execute("INSERT INTO state(k,v) VALUES('last_refresh',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
              (now(),))
    c.execute("INSERT INTO state(k,v) VALUES('roots',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
              (json.dumps((a.root or []) + ["github=" + r for r in (a.github or [])]),))
    print("done: " + ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items())) if counts else "done: nothing to index")
    cmd_status(a, c)


def cmd_status(a, c=None):
    c = c or connect(a.db)
    s = dict(c.execute("SELECT k, v FROM state").fetchall())
    n = lambda q: c.execute(q).fetchone()[0]
    print("index %s: %d sources, %d chunks, %d decisions, last refresh %s" % (
        a.db, n("SELECT COUNT(*) FROM sources"), n("SELECT COUNT(*) FROM chunks"),
        n("SELECT COUNT(*) FROM decisions"), s.get("last_refresh", "never")))
    for row in c.execute("SELECT root, kind, COUNT(*) n FROM sources GROUP BY root, kind ORDER BY n DESC"):
        print("  %-12s %-12s %d" % (row["root"], row["kind"], row["n"]))


def main():
    ap = argparse.ArgumentParser(prog="indexer", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True)
    sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("refresh")
    r.add_argument("--root", action="append", help="<kind>=<path>, repeatable")
    r.add_argument("--github", action="append", help="owner/repo, repeatable (needs gh)")
    r.add_argument("--github-limit", type=int, default=200)
    r.set_defaults(f=cmd_refresh)
    s = sp.add_parser("status")
    s.set_defaults(f=lambda a: cmd_status(a))
    a = ap.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
