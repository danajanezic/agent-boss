---
name: doc-index
description: Use when a project's documents have grown past what a session can read at startup, when adding or moving a document that sessions need to know about, when a session is about to read a whole docs directory, or when setting up the one-line-per-document index and its searchable index. Covers `docidx add/check/size/refresh/schedule`.
---

# The document index

In this skill, `docidx` means `${CLAUDE_PLUGIN_ROOT}/bin/docidx`, run from the project root.

A session cannot read a project's documents at startup and still have room to work. It can read
**one line per document**, and open a document when that line touches the step it is about to take.
Two files make that work:

- `docs/INDEX.md`: one line per document, each a markdown link plus a hook saying when to open it.
- the documents themselves, as long as they need to be.

Beside them sits a **searchable index** (`.doc-index/index.sqlite`), which the `doc-index` MCP
server reads. The INDEX.md line is what a session reads for free; search is what it reaches for when
it does not know which document holds the answer. See the `searching-docs` skill for querying.

## An index line

```
- [Water rules](water.md) — canals and barays: read before moving water
```

The hook is the whole point. "Water rules" tells a session nothing about whether to open it; "read
before moving water" tells it exactly when. Write hooks as the condition that should make someone
open the document, not as a summary of its contents.

Keep a line under about 100 characters. `docidx add` refuses a hook over 120, because an index that
costs as much as the documents has stopped being an index.

## Commands

| Command | What it does |
|---|---|
| `docidx add <file> "<hook>"` | Add or update that file's line. Takes the title from the file's own first heading. |
| `docidx check` | Lines pointing at nothing, documents with no line, hooks missing, titles that have drifted from the document's heading. Exits non-zero on a problem, so it belongs in CI. |
| `docidx size` | What a session spends reading the index, against `DOC_INDEX_CTX`, and how much larger the documents it points at are. |
| `docidx list` | The index as it stands. |
| `docidx refresh [--root k=path] [--github owner/repo]` | Rebuild the searchable index. Incremental: unchanged files are left alone. |
| `docidx schedule [--every 30] [--off]` | Run that refresh on a timer: a launchd agent on macOS, or it prints the crontab line elsewhere. |

Settings come from the environment or `.doc-index/config`, read as plain `KEY="value"` lines and
never run as shell: `DOC_INDEX_FILE`, `DOC_INDEX_DOCS`, `DOC_INDEX_DB`, `DOC_INDEX_CTX`,
`DOC_INDEX_WARN`.

## Using it

**Setting a project up.** `docidx add` each document that a session should know exists, then
`docidx refresh`, then `docidx schedule` so the searchable index does not go stale. Add
`docidx check` to CI.

**Adding a document.** Add its index line in the same change. A document nobody can find is work
nobody will reuse, and a session will happily rewrite what it cannot see.

**Reading as a session.** Read `docs/INDEX.md`. Open a document when its line applies to the step
you are on, and always before a step the line names. The lines are instructions about when to read,
not background.

**When the index gets long.** `docidx size` warns past `DOC_INDEX_WARN` percent of the context
window. Shorten hooks first. If it is still long, split it: one index per area, and a short top
index pointing at those, so a session reads only the part that covers its work.

## What this does not do

It does not decide what belongs in a document, and it does not keep a document's contents true.
That is the `doc-maintainer` agent's job: recording a decision into the right document, and
sweeping for documents that have drifted from what the project now does.

A stale searchable index is worse than none, because it answers confidently from last week. That is
why `schedule` exists and why every answer from the server carries `last_refresh`.
