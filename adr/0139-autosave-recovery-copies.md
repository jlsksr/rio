# ADR-0139: Autosave writes a separate recovery copy, never the file you are editing

- **Status:** Accepted
- **Date:** 2026-09-26
- **Deciders:** jka
- **Decision log:** AGENTS.md D132

## Context

rio could lose work. A buffer's edits lived only in the core's memory until someone
saved: kill the process, lose the tunnel, pull the plug, and everything typed since the
last save was gone. Every editor rio measures itself against protects against that, and
rio had no protection at all — not a preference, not an operation, not a line in the
roadmap. The maintainer asked for emacs-style autosave, on by default and toggleable.

The word carries two incompatible promises, so the decision has to state which one it
means. In VSCode, autosave means *write my real file for me*. In emacs it means a
separate copy kept beside your unsaved work, and the file itself is left alone.

## Decision

**rio's autosave is emacs's model: the file you are editing is never written without an
explicit save.** What autosave writes is a separate **recovery copy**, dropped the moment
the buffer is really saved and offered back the next time that file is opened. Until you
save, the bytes on disk are the ones you last put there. That is why the preference reads
*"Keep recovery files for unsaved changes"* rather than using the word that would promise
the opposite.

**It lives in the core.** Three facts force it, all of them already decided:

- The file is the **core's** ([ADR-0030](0030-always-a-channel-client.md)). A GUI-side
  autosave would write on the *client's* disk, beside a path that may not exist there —
  the rule of [ADR-0055](0055-core-answers-host-questions.md) exactly.
- A persistent daemon holds buffers with **no frontend attached**. Autosave has to work
  for them, so the core cannot wait to be told the policy when a client arrives.
- Detecting a waiting copy means comparing two files on the core's host, which only the
  core can do.

The frontend keeps what a frontend keeps: a mirror of the setting, and the question. That
is the split of [ADR-0132](0132-decline-a-file-too-big-to-open.md) verbatim — the core
states the fact, the frontend owns the question — the shape `file.open`'s over-budget
refusal already uses.

**What counts as changed is a document revision, not a dirty flag.** The core has no
notion of dirty on purpose: "does this differ from disk" is view-local state, which each
frontend answers for itself and two frontends may answer differently
([ADR-0022](0022-encoding-line-endings-cursor.md)). Autosave wants a different question —
"has this document's text changed since *I* last wrote it" — which is a fact about the
document. So the document model gains a monotonic per-buffer **revision counter**,
incremented at the single mutation choke point that every edit, whole-text replacement,
replace-all, undo and redo already passes through, so one increment catches every one of
them and nothing else. Autosave records the revision at its last write, and *changed* is
one comparison. Undoing back to the written state still reads as changed, because the
counter is monotonic: that costs one identical rewrite and can never wrongly *skip* one,
which is the direction the error has to fall.

**The copies go out of the project tree.** This was the one question put to the
maintainer, who chose out-of-tree over emacs's own placement. The reasoning is
[ADR-0031](0031-sessions-and-preferences.md)'s, applied to the same kind of state: kept
under the data dir rather than in the repository, a recovery copy never shows in
`git status`, needs no `.gitignore`, and cannot be committed by accident. The name is kept
and only the place moves — the file's own directory is mirrored below an autosave root,
holding emacs's `#name#`:

```
/home/jka/Projekte/rio/rio-gui/rio-gui.tcl
    -> ~/.local/share/rio/autosave/home/jka/Projekte/rio/rio-gui/#rio-gui.tcl#
```

The mirrored path is readable on purpose: a recursive listing of the autosave root is a
plain report of what is unsaved and where it belongs, which a hash of the path
(ADR-0031's own key) would not give.

**The mirrored path is built by splitting the file path, never by string surgery**, and
that is worth recording because the failure mode is silent and destructive: joining an
absolute remainder onto a root yields the remainder, so a Windows drive or a UNC share
would escape the autosave root and overwrite something real. Every head a split can
produce becomes exactly one readable segment (`C:/` becomes `C`), the result is checked to
sit under the root before it is returned, and the head mapping is separated out so the
volume branch is testable on a host whose split never produces one.

**The setting fails open, which is the inverse of the neighbouring rule.**
`autosave.conf` sits beside `tls.conf` in the same flat format, parsed and never executed
([ADR-0021](0021-plain-text-config-xdg.md)), with an `autosave` key and an `interval_ms`
key (default 30 seconds, floor 1 second). Absent, unreadable, malformed, or any value that
is not a plain `off` leaves autosave **on**.
[ADR-0120](0120-core-wide-unchecked-https-switch.md)'s `tls.conf` fails **closed** for the
opposite reason, and stating both together is the point: there the safe side is refusing a
connection, here it is protecting work the user has not saved. A typo must not silently
switch off the thing standing between someone and a lost afternoon. Both keys are re-read
on every tick, so a hand edit applies without a restart — `tls.conf`'s habit, for the same
reason. Turning the setting on reads the interval first and writes it back, so ticking the
box never discards a hand-tuned one.

**An autosave is silent on the wire, by decision.** It emits no event.
`fs.changed` ([ADR-0047](0047-fs-changed-event.md)) exists for files a view cares about;
firing it every interval would spam pane repaints and the stale checks of
[ADR-0094](0094-stale-buffers.md) for a file no pane shows. This is also the core's first
*recurring* timer — every other deferred call there is one-shot — and it needs none of the
guards the frontend's deferred work carries: a sweep dispatches no operation, emits no
event and touches no channel, so it is safe wherever the event loop reaches it, including
inside a nested wait in the HTTP layer. It is armed only when the core is run as a
program, so a test that *sources* the core gets no timer behind it and drives a sweep
itself.

**Operations.** `autosave.settings` and `autosave.settings.set {enabled}` both answer
`{enabled interval}`. They are flat, so the default encoder carries them, and the setter
answers with what the setting now **reads back as**, not with what it was handed, so a
frontend's control can only ever show what the core holds.

`buffers.recover {buffer}` sits beside `buffers.reload` (ADR-0094), which it is shaped
after: the whole text through the ordinary edit path, so it is **one undo step** and a
recovery can be taken back like any other edit, and one `buffer.changed` so every attached
view repaints through the path it already has. Two things it deliberately does not do. It
does not touch the file, so the buffer's recorded disk identity still describes the file
correctly and must not be refreshed — **a recovered buffer is not stale**. And unlike a
reload it leaves the buffer's encoding and line-ending facts alone, because those describe
the real file and not the copy.

`file.open` reports any waiting copy as three **flat, additive** keys — its path, its
modification time, and whether it is newer than the file. No protocol bump: an added key
is additive and a client too old simply ignores it
([ADR-0055](0055-core-answers-host-questions.md),
[ADR-0019](0019-plugin-manifest-and-permissions.md)).

**The frontend: one door, and one question.** The toggle is **Preferences ▸ Editor** and
nothing else — **no menu twin**, because [ADR-0085](0085-agent-config-in-preferences.md)
keeps the menubar for *fast* switches and this is set-once policy. It is also not a
preferences-file key of the frontend's own: the control adopts from the core at every
attach, beside the TLS settings it already mirrors, and writes only on a click, then shows
what the core **accepted**, so a refusal snaps it back rather than claiming a state the
core is not in.

The question is asked when a file is opened. Recovering marks the buffer **modified** —
nothing reaches disk until the user saves. Declining leaves the copy alone: it is not
rio's to delete on a shrug, and the next save of that buffer drops it anyway. **A session
restore at startup asks once** for the whole set rather than once per file, which is
ADR-0094's own rule reached from the other direction.

**Which button is the default** follows ADR-0094: the choice that loses nothing.
Recovering loses nothing either way — the file is untouched and the recovery is undoable —
but nodding through text **older** than the file would be an odd thing to default to, so
an older copy defaults to No and the prompt says which way round it is. An older copy is
still **offered**, not hidden: it can hold work the file never had, if a checkout or
another editor landed on top of it, so treating it as spent would be a lie.

## Alternatives considered

- **Writing the user's own file on a timer** — the other meaning of the word, and
  VSCode's. Not what was asked for, and the opposite promise: it would make every edit
  reach disk without an act, which is precisely what the propose-and-approve posture of
  the rest of rio refuses. Recorded because the word invites the reading.
- **emacs's placement, beside the edited file.** Costed and rejected for reasons that only
  appear when the whole of rio is in view. The copy is untracked, so it would appear in the
  git pane *while you type*, which would also make the destructive *Discard all* button of
  [ADR-0093](0093-discard-tree-and-bulk.md) permanently visible and put the copy in
  `git clean`'s path. It would be found by project search, so every match in an edited file
  would be reported twice. And it would have to be hidden from the files pane, from project
  search, from the agent's filesystem tools and from git's own porcelain — four copies of
  one rule, and [ADR-0117](0117-derived-facts-register.md) then owes four guards. Out of
  tree costs none of that.
- **Keying a copy by a hash of its path**, as the session store does (ADR-0031). Rejected
  here: the mirrored path costs nothing and is a report a person can read.
- **A dirty flag in the core.** Rejected: dirty is a view's word for how a buffer differs
  from disk, and it belongs to each frontend (ADR-0022). A revision counter answers the
  question autosave actually has, and answers it about the document.
- **Announcing each sweep with an event.** Rejected: repaints and stale checks for a file
  no view is showing, every interval, to report something the user is meant not to notice.
- **Making the toggle a menu item as well.** Rejected under ADR-0085: the menubar is for
  switches you flip often, and this is set once.

## Consequences

- A crash, a lost tunnel or a power cut costs at most one interval of typing, and the file
  on disk is still exactly what was last saved.
- The document model now has a change counter, so anything else that needs "has this text
  changed since I looked" has an answer to use rather than a second one to invent.
- A recovered buffer is modified and unsaved, deliberately: recovery is an edit, undoable,
  and reaching disk stays the user's act.
- An **untitled** buffer gets no copy. Buffer ids are per-process, so there is no identity
  to recover one under; a "restore unsaved buffers" list at startup is a feature of its
  own.
- Nothing sweeps copies whose file is never reopened. The normal lifecycle drops a copy on
  save, close, reload and rename, so what lingers is a file rio never saw again.
- There is no visible sign that a sweep happened — the status bar is one label, and a
  flash would want the event this decision deliberately does not emit — and no per-project
  or per-file opt-out.
- A deep project path on Windows can push the mirrored copy past the platform's path
  limit, where the write is caught and that buffer is skipped. Noted in CAVEATS, and
  untested on Windows.
- A very large buffer is written in full on each sweep. [ADR-0133](0133-big-files-are-slow-for-what-rio-does-to-them.md)'s
  measurements put that near 20 ms per megabyte, so a one-megabyte file is imperceptible
  and a sixty-four-megabyte one is not. That is what the hand-editable interval is for,
  until someone measures a case that warrants a size cap.
- Every guard is headless.
