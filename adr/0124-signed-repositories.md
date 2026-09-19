# ADR-0124: A repository can be signed, and rio checks it

- **Status:** Accepted; amended by [ADR-0125](0125-repository-signing-keys-list.md); trust on first use superseded by [ADR-0126](0126-signing-key-confirmed-by-the-user.md)
- **Date:** 2026-09-16
- **Deciders:** jka
- **Decision log:** AGENTS.md D118

## Context

ADR-0039 keeps plain http first-class, and that is why this decision exists: anyone on the
path between a user and a repository can rewrite an extension's Tcl in flight, and rio
would install it and run it inside the editor. ADR-0109 and ADR-0111 hardened the
transport, but https is an option, not a requirement, and a publisher who serves http has
no way to vouch for what a user receives.

The trust model must not change to fix that. There is no registry, no operator and no
account; the sources list is the trust list, and a repository is three text files on any
web server. A signature over the repository's contents fits that model, because it needs
nothing but more files in the same directory.

## Decision

**A publisher signs one root `SHA256SUMS` with an SSH key, and rio checks it by running
`ssh-keygen`.** The sums file is in `sha256sum`'s own format and covers everything the
repository serves: the marker, the index, every manifest and every payload. It is signed
as a detached OpenSSH signature in the namespace `rio-repository`, the way git signs
commits. rio verifies it with `ssh-keygen -Y verify` against an allowed-signers file it
writes itself, containing one line for the one key it trusts. File hashes stay in Tcl
(tcllib's `sha256`); only the public-key work is the tool's.

**The binding is the key and the namespace.** The signature identity only selects a line
in a file rio generated, so it contributes nothing to the verdict; rio uses the source URL
for it as a label, not as a claim. The namespace is what stops a signature made for git or
for ssh authentication being replayed as a repository signature.

**Trust on first use, with rio's own key seeded.** A repository publishes its public key
in `rio-repository.conf`. The first scan whose signature verifies against that key records
it, and from then on only that key speaks for that source. The trust store is
`repository-keys.conf`, beside `sources.list` in the GUI's configuration, in the conf
format (ADR-0021), commented and hand-editable: deleting a section is how a user takes a
trust decision back. Entries are keyed without the scheme, like the rest of the source
matching, so moving a repository from http to https (ADR-0109) is a change of route, not
of publisher. The default source ships with the project's own key already trusted, so a
fresh install is not asked a question it has no way to answer.

A key that later differs is refused as *changed*, with a review dialog in the shape
ADR-0111 gave a changed certificate: both fingerprints side by side in a bordered,
selectable box (ADR-0068), an explicit instruction to confirm the new one away from this
connection, **Go Back** as the default button, and trust granted to exactly the key the
dialog showed.

What first use cannot do is recorded rather than glossed. An attacker present on the very
first scan serves a marker, sums and signature of their own, and rio has nothing to
compare them against. What is defended is every scan and install after that one, which is
an extension's whole lifetime.

**No downgrade, and no partial trust.** Once a key is trusted for a source, a key that
disappears from the marker, a missing or unfetchable signature, a signature that does not
verify, and a file whose hash does not match are all refusals of the **whole** source.
"Most of it verified" is not a state a user can act on. Every file rio fetches from a
signed source must appear in `SHA256SUMS` with that hash: a publisher's sums cover
everything served, so a file the sums do not mention is not an omission but a file from
somewhere else. The web server's own directory listing is exempt, because it is not a file
of the repository; every directory it names must still produce a manifest the sums vouch
for.

**The one way out is for the missing tool, not for the missing signature.** Where
`ssh-keygen` is absent or older than OpenSSH 8.0, nothing can be checked. A source nobody
has trusted yet simply lists as *unsigned*; a source whose key **is** trusted is refused,
which is the fail-closed shape ADR-0120 gave https on a tcltls that cannot check host
names. Preferences ▸ Extensions ▸ "Use repositories rio can't check", off by default, lets
those through marked **unverified** — never *signed* — in the list and in the install
consent. It excuses nothing else: a bad signature, a changed key or a mismatched hash is
refused with the switch on. A tool too old to verify is reported as the version problem it
is, never as a bad signature.

**The core hashes; the GUI decides.** Verification is a core operation (`sig.verify`,
`sig.fingerprint`) because `ssh-keygen` has to be on the host that fetches — the same
split ADR-0109 made for tcltls, and the reason a GUI-only box stays Tk and nothing else.
The policy above is the GUI's, because the trust store belongs with the sources list.
`repo.fetch` gained an opt-in hash of the body **as it arrived**; opt-in because tcllib's
sha256 is pure Tcl and an unsigned repository must not pay for it.

Asking for the bytes forced an honest change in the fetch itself: it is now binary, and
rio's own decoder owns the charset the server declared. What it deliberately loses is
http's `\r\n` → `\n` translation, which alone would make a repository published from
Windows unverifiable. Because the client then holds the signed file as text and hands it
back over a JSON wire, `sig.verify` takes the hash the core reported, re-encodes the text
and checks that it lands on the same bytes before asking `ssh-keygen` anything. A round
trip that lost something says so in those words, instead of arriving as a forged
signature — the one message a user must never see for a repository that was fine.

**What the user sees.** Every variant line ends in *signed*, *unsigned* or *unverified*,
including the boring case, because "signed" means nothing to a user who has never seen rio
say "unsigned". The install consent names the fingerprint that vouched for the files, or
says plainly that nothing does. A refused source gets its own phrase in the list rather
than reading as unreachable. The provenance ledger records who vouched for an installed
extension's bytes.

## Alternatives considered

**Owning Ed25519 and SHA-512 in Tcl**, so rio depends on no external program. Rejected on
review as the heavier and less POSIX road: it is signature verification written from
scratch, and OpenSSH is present on every host rio targets. Running the same tool the
publisher used also keeps the two halves from drifting apart.

**Declaring the namespace in the allowed-signers file** as well as on the command line.
Written first, then removed: fault injection could not construct a test that fails when it
is absent, because the command-line namespace already enforces the match. An option no
test can break is decoration, not defence.

**Refusing outright where `ssh-keygen` is missing**, which is what the design originally
said. The maintainer pushed back, pointing at ADR-0120: fail closed by default, but give
one explicit, off-by-default way through, and never let it hide which way was taken.

**Putting that switch in the core**, as ADR-0120's is. Rejected because ADR-0120's switch
also governs the agent's transport, while this one governs nothing but the Extensions
window, and the trust store it belongs with is the GUI's.

**Hashing the decoded text rather than the bytes as received.** Rejected: the hash has to
be the one the publisher's `sha256sum` saw. Anything else silently excludes every
repository whose files were authored on a system with different line endings.

**A "Repository signing keys…" management dialog** mirroring ADR-0111's accepted
certificates. Deferred by the maintainer rather than grown onto an already large change: a
rotation already has its own dialog, and forgetting a key is a section deleted from a
commented file the dialogs name.

## Consequences

- Tampering in flight fails on every scan and install after the first, over plain http,
  with no registry, no account and nothing to shut down. ADR-0039's trust model is
  unchanged; signing sits on top of it.
- A publisher takes on an obligation: re-sign after every upload. A publish that uploads
  payloads without refreshing the sums, or the sums without the signature, refuses the
  whole source until it is fixed.
- The core's host needs OpenSSH 8.0 or newer for a signed repository to be usable. Hosts
  without it either see unsigned repositories only, or turn the preference on and accept
  unverified ones.
- There is no freshness check. A replayed older `SHA256SUMS` cannot introduce anything,
  but it can freeze a repository at an old version; ADR-0107 never downgrades an
  installation.
- There is no revocation and no cross-signing. A rotation is the "changed" step, answered
  by the user out of band.
- The trust store is the GUI's, so a second frontend on the same core keeps its own — the
  same limit ADR-0039 has for the provenance ledger.
- Every caller of `repo.fetch` now receives the body without line-ending translation.
  Repository files are line-oriented text, so this affects parsing nowhere, but it is a
  change in what the operation returns.
- Still open: a list of trusted signing keys with a Forget action, in the shape of
  ADR-0111's accepted certificates.
