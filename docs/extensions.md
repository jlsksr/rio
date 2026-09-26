# Extensions

Adding to rio: syntax highlighters, editing modes, themes and agent providers,
from repositories you choose.

***Extensions ▸ Browse…*** opens the window where you browse, install, update
and remove. Below it, the same menu lists one entry per installed extension that
has anything to configure, named after the extension, so an installed agent
provider is ***Extensions ▸ `<provider>`…***. Those settings belong to the
extension. *Preferences ▸ Extensions* holds what rio keeps about extensions:
whether it checks for updates, your repository list, and the signing keys you
trust.

With nothing installed that offers settings, the menu says so. Past a dozen of
them it offers a single *Extension settings…* entry with a picker, so the menu
cannot outgrow your screen.

**Most of this topic is still to be written.** It will cover: what a repository
is (a plain directory served over `http://` or `https://`; no marketplace, no
central index); adding and removing repository URLs under
***Extensions ▸ Browse…*** and its *Repositories…* button; browsing and
installing; the four kinds of extension and where each is installed; which
repository and version an installed extension came from, and choosing between
same-named extensions by different authors; keeping them up to date; what is
code and what is only data; and installing over a [remote core](remote.md).

Until then: **Extensions & repositories** in [README.md](../README.md) explains
the model, [preferences](preferences.md#your-repository-list-by-hand) documents
the `sources.list` file and
[checking for updates](preferences.md#checking-for-extension-updates), and
*Extension repositories* in [CONTRIBUTING.md](../CONTRIBUTING.md) is the full
spec for publishing one.

The sections below, on signatures and on certificates, are complete.

## A repository that is signed

A repository can sign what it publishes, and rio checks the signature before it
offers you anything from it.

This matters most over plain `http://`, which rio treats as a first-class
choice: there is no certificate in the way, so anyone between you and the server
could rewrite an extension as it is fetched. A signature makes that fail. An
`https://` repository gains from it too, because a signature covers the files
themselves rather than only the connection that carried them.

Signing is optional. What a publisher does to sign is in *Extension
repositories* in [CONTRIBUTING.md](../CONTRIBUTING.md). From your side:

- The repository publishes a public key in its `rio-repository.conf`, a root
  `SHA256SUMS` listing every file it serves, and `SHA256SUMS.sig` signing that
  list.
- rio verifies that signature by running `ssh-keygen` on the core's host, then
  checks every file it fetches against those hashes: the marker, the index, each
  extension's manifest, each payload. It checks while scanning, and again at
  install time before anything is written to disk.
- If one file does not match, the whole repository is refused.

### What you see

Every version line in the detail pane of ***Extensions ▸ Browse…*** ends in one
of three words:

| Mark | Means |
| ---- | ----- |
| `signed` | The signature verified, and these files were checked against it. |
| `unsigned` | The repository publishes no key. Nothing vouches for the files. |
| `unverified` | It is signed, but this core could not check it. See [below](#repositories-rio-cant-check). |

The word is on the version line because that is where you choose between two
repositories offering the same extension. The line names its repository by its
whole URL, because two repositories can share a domain and differ only in scheme
or path.

The install confirmation says the same at more length: on a signed repository it
names the fingerprint that vouched for the files; on an unsigned one it says
plainly that nothing does. The list *Update All* shows before it starts marks
every row the same way. The ledger `extensions.json` records the fingerprint as
`signed_by`.

### Confirming a repository's key

There is no central index and no authority to ask, so rio does what an `ssh`
client does with a host it has never seen: it shows you the key and waits.

**A scan never trusts a key by itself.** The first time rio meets a repository
that publishes one, that repository is refused. It lists as
`!! <url> — signing key not confirmed`, and nothing from it is listed or
installed until you say the key is the publisher's.

**To confirm a key:**

1. Select that row in ***Extensions ▸ Browse…***.
2. Press **Review signing key…** in the detail pane. A dialog headed **Confirm
   signing key** shows the repository and the one fingerprint it offered, in a
   box you can select and copy.
3. Check that fingerprint **away from this connection**: the publisher's own
   page, a release note, a message from them.
4. Press **Trust This Key**, or **Go Back**, which is the default button and
   changes nothing.

rio records exactly the key the dialog showed you. From then on that key, and
only that key, speaks for that repository: the next scan lists it as `signed`,
and a change of key is [a question again](#the-publisher-changed-their-key).

rio asks only where the answer is worth something. The refusal comes *after* the
signature has verified and after `rio-repository.conf` has been checked against
the hashes that signature covers, so the fingerprint you are shown always
governs files rio is holding.

rio's own repository ships with its key already trusted, so a fresh install is
never asked a question it has no way to answer. You can take that back.

**What confirming cannot do.** If someone is already between you and a
repository the very first time rio looks at it, they can serve their own key,
their own hashes and a signature over them, and the dialog will show you their
fingerprint with nothing inside rio to contradict it. That is why step 3
matters, and rio cannot tell whether you did it. What confirming does guarantee
is everything afterwards: every later scan and every install is checked against
the key you confirmed.

### The keys you have confirmed

***Preferences ▸ Extensions ▸ Repository signing keys…*** lists them: one row
per repository, with the key's fingerprint and the date you confirmed it. The
scheme is left off the URL, because moving a repository from `http://` to
`https://` is a change of route, not of publisher, and its key still counts.

**Forget selected** takes a key back. That repository is refused again on the
next scan, as `signing key not confirmed`, until you confirm a key for it.

rio's own repository is listed `(built in)` while it is still in your sources.
**Forget selected** there withdraws the key rio ships with: the row stays,
marked `(built in, withdrawn)`, and rio then asks about its own repository like
any other. Selecting either form of that row explains it in the line under the
list. Confirming a key for that repository later replaces the withdrawal.

The list is the file `repository-keys.conf`, beside your `sources.list` (see
[where everything lives](preferences.md#where-everything-lives)). Deleting a
section there is what **Forget selected** does; a section with no `key` line is
the written form of a withdrawal.

### The publisher changed their key

A repository later signed by a different key than the one you confirmed is
refused, and lists as `!! <url> — signing key changed`. That is what a publisher
rotating their key looks like, and it is also what someone else answering for
the repository looks like. rio cannot tell them apart, so it asks.

Select that row and press **Review signing key…**. The dialog is headed
**Signing key changed** and shows one fingerprint more: the repository, the
fingerprint rio trusted with the date you confirmed it, and the one now offered.
**Go Back** is the default and changes nothing; **Trust the New Key** records
the key the dialog showed.

Trust it only if you can confirm that fingerprint away from this connection. If
you change your mind later, forgetting that key in
*Preferences ▸ Extensions ▸ Repository signing keys…* puts the repository back
to being asked about.

### When rio refuses a signed repository

rio refuses a repository whole: nothing from it is listed or installed, and it
never quietly stops checking one. Each case puts its own phrase on the row:

| In the list | What happened |
| ----------- | ------------- |
| `signing key not confirmed` | It signs with a key you have never confirmed. Confirm it, [above](#confirming-a-repositorys-key). |
| `signing key changed` | Signed by a different key than the one you confirmed. Review it, above. |
| `signature doesn't verify` | The signature is not a valid signature over that list of hashes. |
| `signature missing` | `SHA256SUMS` or `SHA256SUMS.sig` could not be fetched. |
| `no longer signed` | It used to publish a key and no longer does. |
| `files don't match the signature` | A file rio fetched is not the file the signature vouches for, or is not listed in `SHA256SUMS` at all. |
| `can't check the signature` | Nothing is wrong with the signature: this core has no way to check it. See [below](#repositories-rio-cant-check). |
| `unreachable` | The repository did not answer at all. |
| `certificate not trusted` | Its https certificate did not verify. See [below](#a-certificate-that-isnt-trusted). |

Select the row and the detail pane gives the whole sentence, naming the file
where there is one.

The common innocent cause is a publisher who uploaded files without re-signing
them, or who was mid-upload while you scanned; `⟳` after they finish clears it.
Everything else is worth taking seriously.

### Repositories rio can't check

Checking a signature is the core's work, since it fetches the files and hashes
them. It needs two things there:

- **`ssh-keygen` from OpenSSH 8.0 or newer.** [INSTALL.md](../INSTALL.md) lists
  it as an optional dependency.
- **A core new enough to know about repository signatures.** This only matters
  if you attach a window to an [older remote core](remote.md).

Where either is missing, rio says `can't check the signature` rather than
pretending it checked, and:

- a repository **you have confirmed no key for** lists as `unsigned` and
  installs like any unsigned repository. The confirmation question is never
  raised here, whatever the repository publishes, because rio would be putting a
  fingerprint in front of you that it cannot check a signature against.
- one whose key you **have** confirmed is refused, as `can't check the
  signature`. Using it unchecked is what confirming the key was meant to
  prevent.

The fix is to mend it on the core's host. Where that is not possible,
*Preferences ▸ Extensions ▸ "Use repositories rio can't check"* lets such a
repository through, marked `unverified` everywhere a checked one would say
`signed`, and named as such in the install confirmation. It is off by default.
It covers only the missing means to check: it confirms no key for you, and a
signature that does not verify, a key that changed and a file that does not
match its hash are all still refused. See
[preferences](preferences.md#using-a-repository-rio-cant-check).

Two more things:

- **The checking happens on the core's host**, because that is what fetches the
  repositories. The keys you trust are the window's, in your own
  `repository-keys.conf`.
- **Signing and certificates are separate checks.** A signed `https://`
  repository whose certificate is not trusted is still refused for its
  certificate, and a certificate you accepted vouches for no file.

## A certificate that isn't trusted

An `https://` repository is checked the way a browser checks a site: the
certificate must come from an authority the core's host trusts, be in date, and
be issued for that server's name. rio ships no certificates of its own.
[INSTALL.md](../INSTALL.md) lists where that trust comes from, and what an https
repository needs: `tcltls` 1.8 or newer on the core's host.

A `tcltls` older than 1.8 cannot check that a certificate was issued for the
server, so on such a core an https repository is refused. Three ways out:
upgrade `tcltls`, use the repository's `http://` URL, or turn on
*Preferences ▸ Network ▸ "Allow https without host-name checks"* — one switch
for the whole core, the agent included, off by default (see
[preferences](preferences.md#network-how-the-core-checks-https)).

A repository whose certificate fails is refused: self-signed, from a private
certificate authority, expired, or issued for another name. It lists as
`!! <url> — certificate not trusted` rather than *unreachable*, and nothing from
it is offered. rio never asks about it during a scan or the start-up update
check; it waits until you look.

**To review and accept one:**

1. Select that row in ***Extensions ▸ Browse…***.
2. Press **Review certificate…** in the detail pane. The dialog shows what is
   wrong in plain words ("It expired on …", "It was issued for other.example,
   not for repo.example") and the certificate itself: issued to, its names,
   issued by, the dates it is valid, and its SHA-256 fingerprint. Right-click
   the box for *Copy*.
3. Compare that fingerprint with the one on the server.
4. Press **Accept the Risk and Continue**, or **Go Back**, which is the default
   and changes nothing.

Accepting trusts exactly that certificate, on that host and port, and nothing
else. The Extensions window then fetches the repository again. If the server
later presents a different certificate it is refused again, and the dialog says
first that it is not the certificate you accepted.

**To take an acceptance back:** *Preferences ▸ Network ▸ Accepted
certificates…* lists every one, with its host and port. **Remove selected**
forgets it. They are kept in `certificates.conf` in rio's config directory,
which you may also edit by hand: delete a section to take one back (see
[where everything lives](preferences.md#where-everything-lives)).

Also worth knowing:

- **It is the core's certificate, on the core's network.** With a
  [remote core](remote.md), `certificates.conf` is on that server, and every
  window attached to it shares it.
- **An exception counts for every https connection the core makes** to that host
  and port, the [agent's](agent.md) included.
- **For a private certificate authority, trust the authority instead.**
  Accepting is for one server. To trust every server a private CA signs, add the
  CA to the certificate store on the core's host: `update-ca-certificates` on
  Debian and Alpine, `trust anchor` on RHEL-family systems, the Trusted Root
  store on Windows. Only where that is impossible, set `SSL_CERT_FILE` to a PEM
  bundle holding your CA *and* the public ones, then restart the core. That
  variable replaces the host's store rather than adding to it, so a file holding
  only your CA cuts the core off from every public server, your agent's provider
  included ([INSTALL.md](../INSTALL.md)).
- **No revocation checking.** rio does not consult CRLs or OCSP, so a revoked
  certificate still verifies. Replace it on the server; an exception you
  accepted for the old one then no longer matches.
- **It needs `tcltls` 1.8 or newer** on the core's host. On an older one,
  allowing https without host-name checks does not make a certificate
  reviewable: one that does not verify stays refused.
- **A redirect to another server.** If the repository redirects to a different
  https server and *that* certificate is refused, the review can only reach the
  repository's own address, whose certificate is fine. The dialog says so and
  offers **Close** instead of Accept. A plain `http://` repository refused on
  such a redirect gets no review button at all.
- **https to http is refused.** A repository you added as `https://` that
  redirects to plain `http://` is not followed. http to https is.

## Further reading

- [The agent](agent.md) — installing Claude or an OpenAI-compatible provider.
- [Editing modes](editing-modes.md) — installing vi or emacs.
