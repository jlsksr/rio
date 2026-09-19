# ADR-0126: A signing key is trusted when the user confirms it, never because it arrived first

- **Status:** Accepted
- **Date:** 2026-09-19
- **Deciders:** jka
- **Decision log:** AGENTS.md D119

## Context

ADR-0124 records a repository's signing key the first time a signature from it verifies,
and ADR-0125 built the window that lists what was recorded. Writing that window forced a
sentence into the open: forgetting a key is not distrust, because the next scan trusts on
first use again. The maintainer read it and rejected the premise rather than the mechanism
— a security decision has to be taken consciously by the user — and named the bar: ssh
asks on first use too.

It does. `ssh` prints the fingerprint and waits for `yes`. Silent recording is
`StrictHostKeyChecking=accept-new`, which exists precisely because it is not the default.
ADR-0124 shipped `accept-new` while rio's manual said it works the way an ssh client does:
the documentation described the stronger behaviour and the code did the weaker one, which
is the worst version of this gap to leave standing.

What silent recording costs is exact. An attacker on the path during the very first scan
serves a marker, a sums file and a signature made with their own key; rio records that key
and then defends it faithfully for the rest of the repository's life. The only thing the
user ever observes is a row that says *signed* — which is exactly what a successful attack
looks like.

## Decision

**A repository's signing key is trusted when the user confirms it.** A first scan that
verifies against a published key records nothing. It refuses the source, shows the
fingerprint, and asks. Once confirmed, that key and only that key speaks for that source,
and ADR-0124's changed-key step is unchanged from there on.

**Where the refusal is raised is the security property, not an implementation detail.** It
comes after the signature has verified and after the marker the key vouches for has been
checked against the signed hashes. Raised any earlier, rio would put a fingerprint in
front of a user for a key that signs nothing in this repository — an invitation to confirm
something meaningless, which is how people are taught to click through. The fingerprint a
user is asked about is therefore always a fingerprint that already governs files rio
holds.

**A refused row, not a modal.** ADR-0107 scans repositories at start-up, so a dialog
raised mid-scan would ambush someone who opened rio to edit a file. The shape is ADR-0111's
instead, which rio already uses for an untrusted certificate and for a changed key: the
source is refused whole, its row says the signing key is not confirmed, and the detail pane
offers to review the key. The review is the same dialog a rotation uses, with a first-sight
branch: one fingerprint instead of two, an instruction to check it against the publisher's
own page, **Go Back** as the default button, and trust granted to exactly the key the dialog
showed rather than one refetched at the click.

**A section with no key means rio trusts no key for that source.** In
`repository-keys.conf`, a section carrying only a `forgotten` date is the written form of a
withdrawal, and it beats the key rio ships with. That gives the seed — ADR-0124's
pre-trusted key for rio's own repository, a fallback rather than a stored entry — something
that can be taken back. The seed stays, because a fresh install must not be asked a question
it has no way to answer, but the row for it now says it has been withdrawn instead of
apologising that there is nothing to forget. A decision rio took on the user's behalf should
be visible and reversible, not merely absent.

**Forgetting an ordinary key needs nothing written.** Deleting the section is the whole act:
the question simply comes back on the next scan, and nothing is installed or listed from that
source until it is answered. This is the part worth keeping — the objection removed a state
instead of requiring one.

**Keys already recorded under ADR-0124 stay trusted.** The change is forward-looking.
Re-asking about keys a user has been relying on for a week teaches them to say yes.

This is GUI-side policy throughout, as ADR-0124 placed it and ADR-0030 requires: the core's
verification and hashing are untouched.

## Alternatives considered

**Keeping silent first use and adding a "forgotten" tombstone**, so that *Forget* would at
least mean something. This was the first proposal, and it was answered at the premise: the
problem was not that forgetting was weak but that trusting was silent. Once trust is
confirmed, ordinary sources need no tombstone at all.

**A modal dialog raised during the scan.** Rejected: ADR-0107 scans at start-up, and a
repository's key is not a question to put to someone who came to edit a file. The refused
row waits indefinitely and costs nothing to ignore.

**Raising the refusal before the marker-hash check**, which is the simpler code. Rejected
for the reason above: it would offer a fingerprint for a key that signs nothing here.

**Re-asking about keys recorded under first use.** Rejected: a wave of questions about
sources that have been working for weeks produces reflexive confirmation, which is the
behaviour this decision exists to avoid.

**Dropping the seeded key entirely**, so that every key without exception is confirmed by a
human. Rejected: a fresh rio would then refuse its own repository and ask a question a new
user has no means to answer. Keeping it withdrawable was the maintainer's choice among
keeping it fixed, dropping it, and this.

## Consequences

- Adding a signed repository costs one confirmation. That is a rare act, and it is the only
  point at which a user is asked; a prompt per install would have been a different and much
  worse trade.
- The first-scan hole is narrowed, not closed. An attacker present at the first scan can
  still present their own key — but they must now persuade a human to accept a fingerprint
  the publisher's own page contradicts, and rio cannot tell whether that check was made.
- *Forget* now means what it says for an ordinary source, and the keys window of ADR-0125
  gains a trust state it did not have: a source rio knows and trusts no key for.
- `repository-keys.conf` has a second meaningful shape. A hand edit can express "trust
  nothing here", including against the key rio ships with, and the file remains the
  definition.
- Trust decisions taken under ADR-0124 are inherited unexamined, an impostor's key among
  them if one was ever recorded. A user who wants to re-verify can forget the key and answer
  the question again.
- There is still no revocation, no expiry, and no way to distrust a key other than
  withdrawing it for its source.
