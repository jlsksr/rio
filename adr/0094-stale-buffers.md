# ADR-0094: Buffers detect changes to their files

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** jka
- **Decision log:** AGENTS.md D94

## Context

`fs.changed` (ADR-0047) refreshed the panes but never the buffers. After an external
write (a `git pull`, an agent write, rio's own discard) a tab kept showing the old text,
and a later save wrote it back over the new content: silent data loss one keystroke away.

## Decision

**rio announces its own writes.** `git.discard` and `git.discard_all` emit `fs.changed`
for every path they touch, including both names of a reverted rename.

**Detection runs in the core.** With a remote core the file is on the server, so a
frontend's `file mtime` would describe the wrong machine. The buffer's disk identity is
modification time plus size, recorded on open and after save. It is recorded after
reading, so a write landing during the read makes the buffer look stale rather than
current.

**Three list-based operations**, because one external write can affect every open tab:

- `buffers.stale {}` returns `{stale: [{buffer, path, gone}]}`.
- `buffers.reload {buffers}` re-reads each file, replaces the buffer text, re-detects
  encoding and line endings, and records the new identity. Failures are reported per
  buffer, never raised for the batch.
- `buffers.stamp {buffers}` records "I have seen this version" without changing text.

A reload replaces the text through the ordinary edit path, as **one undo step** that
also ends any typing run, and emits one `buffer.changed`. No frontend text code is
needed: the event updates whichever view shows the buffer.

**The frontend decides what to do**, because the decision depends on whether the buffer
is modified, which is frontend state (ADR-0022). The default button is always the choice
that loses nothing:

- Unmodified and still present: reload silently.
- Modified and changed on disk: ask once for the whole set, default **No** (keep my
  edits). No records the version so the question is not repeated; a further change
  asks again.
- Deleted on disk: "has been deleted on disk. Keep it open in the editor? Saving it
  later will recreate the file." Default **Yes**. Keeping it marks the buffer modified;
  declining closes the tab. This acknowledgement is kept in the GUI, since a deleted file
  has nothing to stat.

**Triggers:** a burst of `fs.changed` events, and the application regaining focus, the
same two triggers as the files pane. A check never runs while another core call is in
flight (it defers and retries), and it cannot re-enter through a dialog's event loop. A
burst of events is debounced into one refresh with a 60 ms timer; an idle callback would
split a burst read line by line from the channel.

## Consequences

- Stale buffers can no longer overwrite newer files unnoticed.
- A same-second, same-length rewrite is not detected; a content hash is the upgrade path
  if it matters.
- There is still no live file watching. Changes made outside rio are noticed on the next
  focus return.
