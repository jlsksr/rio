# ADR-0125: Every repository signing key rio trusts is listed, and can be forgotten

- **Status:** Accepted; amended by [ADR-0126](0126-signing-key-confirmed-by-the-user.md)
- **Date:** 2026-09-19
- **Deciders:** jka
- **Decision log:** AGENTS.md D118 (amendment of 2026-09-19)

## Context

ADR-0124 trusts a repository's signing key on first use and writes it to
`repository-keys.conf` beside the sources list. That file is hand-editable on purpose, and
deleting a section is how a user takes a trust decision back — but it was the only way to
see what rio had trusted at all, and the only way to undo it. A management dialog was
weighed there and deferred, to keep an already large change reviewable. The maintainer
asked for it as soon as that change had merged: nothing about it was unresolved.

ADR-0111 had already settled the shape for the same job on certificates — a list, a
*Forget*, and the file underneath staying the definition.

## Decision

**A "Repository signing keys…" window under Preferences ▸ Extensions**, in the shape
ADR-0111 gave accepted certificates: a hint, a list, a status line, *Forget selected* and
*Close*. It sits under Extensions and not under Network, where ADR-0120 moved the
certificates, because a certificate exception governs every https connection the core makes
and a signing key is consulted by nothing but the Extensions window. The trust store is the
GUI's, which is ADR-0124's argument for where the policy lives; the window belongs with it.

**A row per recorded trust decision**, carrying the scheme-less source it is filed under,
the key's fingerprint, and the date it was trusted. The fingerprint is the core's to compute,
since ADR-0124 put the public-key work in `ssh-keygen` on the host that fetches. Where that
host has no usable tool the row falls back to the key type and a truncated base64 of the key
itself, because a row still has to identify which key it is about, and a key printed in full
is not something a person compares.

**The seeded key is a row of its own, marked as built in.** rio trusts its own key for its
own repository through a fallback, so a first scan of that repository stores nothing, and a
window listing only the file would be empty on a fresh install while rio does trust a key —
the one thing the window exists to show. The row appears only while that repository is still
in the sources list, since a key for a source the user removed speaks for nothing. It cannot
be forgotten: selecting it says there is nothing stored to forget, and names *Repositories…*
as what actually stops rio using that repository. The reason is given on selection rather
than when the button is pressed, because a control that does nothing is worse than one that
says beforehand why.

**Forgetting is not distrust, and the window says so.** After a key is forgotten the next
scan trusts whatever that repository publishes then, exactly as the first scan did and
exactly as deleting the section by hand always did. The window therefore introduces no trust
state of its own: it is the hand edit ADR-0124 already invited, done for the user, and every
verdict still comes from the same file.

## Alternatives considered

**Listing the keys under Preferences ▸ Network, beside the accepted certificates**, so that
everything about verified connections is in one place. Rejected: the two look alike and
govern different scopes. An exception is the core's and applies to the agent as well; a
signing key is the GUI's and applies to extension repositories only.

**Leaving the built-in key out**, on the ground that there is nothing stored for it and the
window lists the store. Rejected: it makes the honest case — a fresh install that trusts
exactly one key — look like a window with nothing in it, and teaches a user that an empty
list means nothing is trusted.

**Giving *Forget* a meaning on the built-in row**: removing the repository, or recording a
refusal that survives the next scan. Rejected on both counts. Removing a repository is what
*Repositories…* does, and a recorded refusal would be revocation, which ADR-0124 deliberately
does not have; the conf file has no way to express it, and the window must not be able to
reach a state a hand edit cannot.

## Consequences

- What ADR-0124 records silently is now visible, and a trust decision can be taken back
  without finding a file. The file remains the definition; the window is a second way to
  reach it.
- Forgetting a key puts that repository back on first use, with first use's one weakness:
  an attacker present on the next scan is not detected. That is the same trade ADR-0124
  accepted, re-entered deliberately rather than by accident.
- A GUI attached to a core whose host has no `ssh-keygen` can hold keys it cannot fingerprint,
  because the store is the GUI's and the tool is the core's. Such a host cannot use a signed
  repository anyway, so the rows are informational there.
- ADR-0124's open item is closed. There is still no revocation, no expiry and no way to
  distrust a key other than removing its repository.
