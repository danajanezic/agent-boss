# Standing rules

The rules and settled decisions that change rarely, in full. Nobody reads this file start to
finish: every session reads `STANDING-RULES-SUMMARY.md` instead, and greps a rule's **bold title**
out of this file when a summary line touches the step it is about to take.

Two habits keep that working. When you add a rule here, add its one line to the summary in the same
edit. When a rule changes, edit it here and leave its summary line pointing at the same bold title,
so every session's grep still finds it.

Keep each rule short enough to act on, and say what to do rather than what went wrong. Record the
date and who decided, because a session reading a rule a month later needs to know whether it still
holds.

## How work moves

**One lane per piece of work.** Each lane owns its area and takes instructions only from the
orchestrator. A lane that needs something from another lane asks the orchestrator, which decides the
order. Two lanes editing the same files at once is the one thing this arrangement exists to prevent.

**Messages go through the mailbox.** Send with `orch.sh msg send <role> "..."`. It is addressed to
the role, so it waits if that lane is restarting. Do not report a result only in your own session,
where nobody else can see it.

**Nothing counts until it is written down.** A decision that exists only in a conversation is lost
when that session ends. Decisions belong here, today's state in `CURRENT-STATE.md`, and a lane's own
habits in its notes.

## Example rules (replace these)

**Push before you park.** Commit and push every worktree before handing off, because a parked
session's disk may not survive. Decided <date> by <user>.

**Ask before anything hard to reverse.** Deleting, force-pushing, publishing and spending money wait
for the user, even when the task implies them. Decided <date> by <user>.
