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
over a [remote core](remote.md). The section on
[certificates](#a-certificate-that-isnt-trusted) below is complete.

For now, **Extensions & repositories** in [README.md](../README.md) explains the
model, [preferences](preferences.md#your-repository-list-by-hand) documents the
`sources.list` file by hand and
[checking for updates](preferences.md#checking-for-extension-updates), and
*Extension repositories* in
[CONTRIBUTING.md](../CONTRIBUTING.md) is the complete spec for publishing one
yourself.

## A certificate that isn't trusted

An `https://` repository is checked the way a browser checks a site: its certificate
must come from an authority the core's host trusts, be in date, and be issued for
that server's name. rio ships no certificates of its own; it trusts what the core's
host trusts. [INSTALL.md](../INSTALL.md) lists where that comes from, and what an
https repository needs — `tcltls` 1.8 or newer on the core's host.

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
  and its **SHA-256 fingerprint**, which you can select and copy;
- two buttons: **Go Back**, the default, which changes nothing, and **Accept the
  Risk and Continue**.

**Accept only if you know it is the server's own certificate** — compare the
fingerprint with the one on the server, for example. Accepting trusts *exactly that
certificate*, on *that host and port*, and nothing else; the Extensions window then
fetches the repository again. If the server later presents a different certificate,
it is refused again, and the dialog says first that it is **not the certificate you
accepted** — if you didn't replace it yourself, someone may be impersonating the
server. A certificate that later verifies normally never needs the exception.

**To take one back:** *Preferences ▸ Extensions ▸ Accepted certificates…* lists every
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
- **It needs `tcltls` 1.8 or newer** on the core's host — as every https repository
  does.
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
