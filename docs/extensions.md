# Extensions

Adding to rio: syntax highlighters, editing modes, themes, and agent providers —
from repositories you choose.

**Most of this topic is still to be written.** It will cover: what a repository is
(a plain directory served over `http://` or `https://` — no marketplace, no central
index); adding and removing repository URLs under *Settings ▸ Extensions… ▸
Repositories…*; browsing and installing; the four kinds of extension and where each
installs to; provenance — which repository and version an installed extension came
from, and choosing between same-named extensions from different authors; keeping
them up to date (what `[1.1.0 → 1.2.0]` on a row means, *Update All*, and the
optional check at start-up); what is code and what is merely data; and installing
over a [remote core](remote.md). The sections on
[signatures](#a-repository-that-is-signed) and on
[certificates](#a-certificate-that-isnt-trusted) below are complete.

For now, **Extensions & repositories** in [README.md](../README.md) explains the
model, [preferences](preferences.md#your-repository-list-by-hand) documents the
`sources.list` file by hand and
[checking for updates](preferences.md#checking-for-extension-updates), and
*Extension repositories* in
[CONTRIBUTING.md](../CONTRIBUTING.md) is the complete spec for publishing one
yourself.

## A repository that is signed

A repository can **sign** what it publishes, and rio checks the signature before it
offers you anything from it. This matters most over plain `http://`, which rio
treats as first-class: there is no certificate in the way, so anyone between you and
the server could rewrite an extension as it is fetched. A signature is what makes
that attempt fail — no certificate, no registry and no account anywhere. An
`https://` repository gains from it too, because a signature covers the files
themselves rather than only the connection that carried them.

Signing is optional, and what a publisher does to sign is in
*Extension repositories* in [CONTRIBUTING.md](../CONTRIBUTING.md). From your side:

- The repository publishes a **public key** in its `rio-repository.conf`, a root
  `SHA256SUMS` listing every file it serves, and `SHA256SUMS.sig` signing that list.
- rio verifies that signature by running **`ssh-keygen`** on the core's host, then
  checks **every file it fetches** against those hashes — the marker, the index,
  each extension's manifest, each payload. It checks while scanning, and again at
  install time before anything is written to disk.
- If one file doesn't match, the **whole** repository is refused. It is signed as
  one thing, and "most of it verified" is not a state you could act on.

### What you see

Every version line in the detail pane of *Settings ▸ Extensions…* ends in one of
three words:

| Mark | Means |
| ---- | ----- |
| `signed` | the signature verified, and these files were checked against it |
| `unsigned` | the repository publishes no key — nothing vouches for the files |
| `unverified` | it is signed, but this core couldn't check it (see [below](#repositories-rio-cant-check)) |

That word is on the version line because that is where you choose between two
repositories offering the same extension. The install confirmation says the same
thing at more length: on a signed repository it names the **fingerprint** that
vouched for the files; on an unsigned one it says plainly that nothing does. The
list *Update All* shows before it starts marks every row the same way, since that
one confirmation stands in for all of them. The provenance ledger `extensions.json`
records the fingerprint as `signed_by`.

### Confirming a repository's key

There is no central index and no authority to ask, so rio does what an `ssh` client
does with a host it has never seen: it shows you the key and waits. **A scan never
trusts a key by itself.** The first time rio meets a repository that publishes one,
that repository is **refused** — it lists as `!! <url> — signing key not confirmed`,
and nothing from it is listed or installed until you say the key is the publisher's.

**To look:** select that row. Its detail pane offers a **Review signing key…**
button, which opens a dialog headed **Confirm signing key**: the repository, the one
fingerprint it **offered** — in a box you can select and copy, since comparing a
fingerprint is the whole point — and two buttons, **Go Back**, the default, which
changes nothing, and **Trust This Key**. One fingerprint, because there is nothing
inside rio to compare it against; that comparison is yours to make.

**Confirm that fingerprint away from this connection** — the publisher's own page, a
release note, a message from them. Anyone who can answer for the repository can offer
a key whose signature verifies; only the publisher can tell you which key is theirs.
rio then records exactly the key the dialog showed you, and from then on that key,
and only that key, speaks for that repository: the next scan lists it as `signed`,
and a change of key is [a question again](#the-publisher-changed-their-key).

rio asks only where the answer is worth something. The refusal comes *after* the
signature has verified and after `rio-repository.conf` has been checked against the
hashes that signature covers, so the fingerprint you are shown always already governs
files rio holds — rather than being a key that signs nothing here.

rio's **own** repository ships with its key already trusted, so a fresh install is
never asked a question it has no way to answer. It is the one key you were not asked
about, and you can take it back.

### The keys you have confirmed

***Preferences ▸ Extensions ▸ Repository signing keys…*** lists them: one row per
repository, with the key's **fingerprint** and the date you confirmed it. The scheme
is left off the URL on purpose — moving a repository from `http://` to `https://` is
a change of route, not of publisher, so its key still counts. rio's own repository is
listed `(built in)` while it is still in your sources.

**Forget selected** takes a key back, and it means what it says: that repository is
refused again on the next scan, as `signing key not confirmed`, until you confirm a
key for it. On the `(built in)` row it **withdraws** the key rio ships with — the row
stays, marked `(built in, withdrawn)`, and rio then asks about its own repository
like any other's. Selecting either form of that row explains it, in the line under
the list, before you press anything. Confirming a key for that repository later
replaces the withdrawal.

The same list is the file `repository-keys.conf`, beside your `sources.list` (see
[where everything lives](preferences.md#where-everything-lives)). It is commented and
you may edit it: deleting a section is exactly what **Forget selected** does for you,
and a section with no `key` line at all is the written form of a withdrawal — it says
rio trusts no key for that repository, and it outranks the key rio ships with.

Worth knowing what confirming can and cannot do. If someone is already between you
and a repository the **very first** time rio looks at it, they can serve their own
key, their own hashes and a signature over them, and the dialog will show you their
fingerprint with nothing inside rio to contradict it — which is why the check against
the publisher's own page is the part that matters, and rio cannot tell whether you
made it. What it does guarantee is everything afterwards: every later scan and every
install is checked against the key you confirmed, which is the whole life of an
installed extension.

### The publisher changed their key

A repository later signed by a **different** key than the one you confirmed is
refused, and lists as `!! <url> — signing key changed`. That is what a publisher
rotating their key looks like — and exactly what someone else answering for the
repository looks like. rio cannot tell them apart, so it asks you.

**To look:** select that row. Its detail pane offers the same **Review signing key…**
button, and the dialog is the same one with a fingerprint more: headed **Signing key
changed**, it gives the repository, the fingerprint rio **trusted** (and the date you
confirmed it), and the one now **offered**. Two buttons: **Go Back**, the default,
which changes nothing, and **Trust the New Key**.

**Trust it only if you can confirm that fingerprint away from this connection** —
the publisher's own page, a release note, a message from them. rio then trusts
exactly the key the dialog showed you, for that repository, and asks again if it
ever changes. If you later change your mind, forgetting that key in
*Preferences ▸ Extensions ▸ Repository signing keys…* puts the repository back to
being asked about ([above](#the-keys-you-have-confirmed)).

### When rio refuses a signed repository

rio refuses a repository **whole** — nothing from it is listed or installed — and
never quietly stops checking one. Each of these puts its own phrase on the row:

| In the list | What happened |
| ----------- | ------------- |
| `signing key not confirmed` | it signs with a key you have never confirmed — confirm it, [above](#confirming-a-repositorys-key) |
| `signing key changed` | signed by a different key than the one you confirmed — review it, above |
| `signature doesn't verify` | the signature is not a valid signature over that list of hashes |
| `signature missing` | `SHA256SUMS` or `SHA256SUMS.sig` couldn't be fetched |
| `no longer signed` | it used to publish a key and no longer does |
| `files don't match the signature` | a file rio fetched isn't the file the signature vouches for, or isn't listed in `SHA256SUMS` at all |
| `can't check the signature` | nothing is wrong with the signature: this core has no way to check it — see [below](#repositories-rio-cant-check) |

Select the row and the detail pane gives the whole sentence, naming the file where
there is one. The common innocent cause is a publisher who uploaded files without
re-signing them, or who was mid-upload while you scanned; `⟳` after they finish
clears it. Everything else is worth taking seriously, because the refusal is the
signature doing its job.

### Repositories rio can't check

Checking a signature is the core's side of the work — it fetches the files and
hashes them — and it needs two things there: **`ssh-keygen` from OpenSSH 8.0 or
newer** ([INSTALL.md](../INSTALL.md) lists it as an optional dependency), and a core
new enough to know about repository signatures at all, which matters only if you
attach a window to an [older remote core](remote.md). Where either is missing rio
says `can't check the signature` rather than pretending it checked, and:

- a repository **you have confirmed no key for** simply lists as `unsigned`, and
  installs like any unsigned repository. **The confirmation question is never raised
  here**, whatever the repository publishes: rio would be putting a fingerprint in
  front of you that it could not check a single signature against. So on such a core
  a signed repository you have not confirmed is used exactly as an unsigned one is —
  nothing vouches for the files, and the install confirmation says so;
- one whose key you **have** confirmed is **refused**, as `can't check the signature`.
  Using it unchecked is the one thing confirming the key was meant to prevent.

*Can't check* never turns into *checked and failed*: whatever is missing, rio says
which. The fix is to mend it on the core's host. Where that isn't possible,
*Preferences ▸ Extensions ▸ "Use repositories rio can't check"* — off by default —
lets such a repository through, marked `unverified` everywhere a checked one would
say `signed`, and named as such in the install confirmation. It covers **only** the
missing means to check: it confirms no key on your behalf, and a signature that
doesn't verify, a key that changed and a file that doesn't match its hash are all
refused with it on
(see [preferences](preferences.md#using-a-repository-rio-cant-check)).

Two more things worth knowing:

- **The checking happens on the core's host**, because that is what fetches the
  repositories — so it is that machine's `ssh-keygen` that matters. The keys you
  trust, though, are the GUI's: the list under
  *Preferences ▸ Extensions ▸ Repository signing keys…*, kept in your own
  `repository-keys.conf`. The sources list is your trust list, and a key belongs to
  an entry in it.
- **Signing and certificates are separate checks.** A signed `https://` repository
  whose certificate isn't trusted is still refused for its certificate, and a
  certificate you accepted does not vouch for a single file.

## A certificate that isn't trusted

An `https://` repository is checked the way a browser checks a site: its certificate
must come from an authority the core's host trusts, be in date, and be issued for
that server's name. rio ships no certificates of its own; it trusts what the core's
host trusts. [INSTALL.md](../INSTALL.md) lists where that comes from, and what an
https repository needs — `tcltls` 1.8 or newer on the core's host.

A `tcltls` older than 1.8 cannot check that a certificate was issued for the server,
so on such a core an https repository is refused with three ways out: upgrade
`tcltls`, use the repository's `http://` URL, or turn on *Preferences ▸ Network ▸
"Allow https without host-name checks"* — one switch for the whole core, the agent
included, off by default (see
[preferences](preferences.md#network-how-the-core-checks-https)).

A repository whose certificate fails — self-signed, from a private certificate
authority, expired, or issued for another name — is **refused**. It lists in the
Extensions window as `!! <url> — certificate not trusted` rather than *unreachable*,
and nothing from it is offered. rio never asks you about it during a scan or the
start-up update check; it waits until you look.

**To look:** select that row. Its detail pane shows the refusal and a
**Review certificate…** button, which opens a dialog with:

- what is wrong with the certificate, in plain words — "It expired on …", "It was
  issued for other.example, not for repo.example";
- the certificate itself — issued to, its names, issued by, the dates it is valid,
  and its **SHA-256 fingerprint**, which you can select and copy (right-click the box
  for *Copy*, since comparing that fingerprint is the whole point of the dialog);
- two buttons: **Go Back**, the default, which changes nothing, and **Accept the
  Risk and Continue**.

**Accept only if you know it is the server's own certificate** — compare the
fingerprint with the one on the server, for example. Accepting trusts *exactly that
certificate*, on *that host and port*, and nothing else; the Extensions window then
fetches the repository again. If the server later presents a different certificate,
it is refused again, and the dialog says first that it is **not the certificate you
accepted** — if you didn't replace it yourself, someone may be impersonating the
server. A certificate that later verifies normally never needs the exception.

**To take one back:** *Preferences ▸ Network ▸ Accepted certificates…* lists every
certificate you accepted, with its host and port, and **Remove selected** forgets
one. They are kept in `certificates.conf` in rio's config directory, which you may
also edit by hand — delete a section to take it back (see
[where everything lives](preferences.md#where-everything-lives)).

Things worth knowing:

- **It is the core's certificate, on the core's network.** The core fetches
  repositories, so the certificate reviewed and the exception stored are the core's.
  With a [remote core](remote.md), `certificates.conf` is on that server, and every
  window attached to it shares it.
- **An exception counts for every https connection the core makes** to that host and
  port, the [agent's](agent.md) included.
- **For a private certificate authority, trust the authority instead.** Accepting is
  for one server; to trust every server a private CA signs, add the CA to the
  certificate store on the core's host — `update-ca-certificates` on Debian and Alpine,
  `trust anchor` on RHEL-family systems, the Trusted Root store on Windows. Only where
  that isn't possible, set `SSL_CERT_FILE` to a PEM bundle holding your CA *and* the
  public ones, then restart the core. That variable replaces the host's store rather
  than adding to it, so a file holding only your CA cuts the core off from every public
  server, your agent's provider included ([INSTALL.md](../INSTALL.md)).
- **No revocation checking.** rio does not consult CRLs or OCSP, so a certificate the
  authority has revoked still verifies. The fix is to replace it on the server — and
  once it is replaced, an exception you accepted for the old one no longer matches.
- **It needs `tcltls` 1.8 or newer** on the core's host. On an older one, allowing
  https without host-name checks does not make a certificate reviewable: one that
  doesn't verify stays refused.
- **A redirect to another server.** If the repository redirects to a different https
  server and *that* certificate is refused, the review can only reach the repository's
  own address, whose certificate is fine. The dialog says so and offers **Close**
  instead of Accept. A plain `http://` repository refused on such a redirect gets no
  review button at all.
- **https to http is refused.** A repository you added as `https://` that redirects to
  plain `http://` is not followed; http to https is.

## Further reading

- [The agent](agent.md) — installing Claude or an OpenAI-compatible provider.
- [Editing modes](editing-modes.md) — installing vi or emacs.
