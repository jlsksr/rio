# ADR-0111: A certificate that fails verification can be accepted by fingerprint

- **Status:** Accepted; amended by [ADR-0120](0120-core-wide-unchecked-https-switch.md)
- **Date:** 2026-09-15
- **Deciders:** jka
- **Decision log:** AGENTS.md D111

## Context

After ADR-0109, an https repository whose certificate failed verification (self-signed,
issued by a private CA, expired, or issued for another name) was unusable. The only remedy was
`SSL_CERT_FILE` on the core's host and a restart, which suits a private CA but cannot help an
expired certificate or a name mismatch. The maintainer asked for web-browser behaviour: secure
by default, but letting the user accept the risk for a specific certificate without it being
cumbersome.

## Decision

**The browser model.** Refuse by default; explain why and show the certificate; offer
**Go Back** as the default button beside **Accept the Risk and Continue**; remember the
exception; allow it to be removed.

**An exception pins one certificate.** It is the SHA-256 fingerprint of the server's leaf
certificate, filed under `host:port`.

- It covers every way that certificate fails verification.
- A different certificate on the same host and port is refused, and both the error and the
  review say the certificate **changed** since it was accepted, shown first and in the error
  colour.
- A certificate that verifies normally never consults exceptions, so a stale exception cannot
  break a site that later obtains a valid certificate.
- An exception for one port does not apply to another.

**Stored and enforced in the core.**

- The file is `$XDG_CONFIG_HOME/rio/certificates.conf` on the core's host, one section per
  `host:port` in the conf format (ADR-0021). A malformed file, or an entry without a valid
  fingerprint, grants nothing. The file is read each time a chain fails, so hand edits apply
  immediately.
- Enforcement is in `rio::tls`, so every https connection the core makes honours exceptions,
  the agent's included. An exception describes a server's certificate, not the feature that
  connects to it. Restricting it to repositories would also have required threading a caller
  flag through the shared `http::register` handler.

**How a chain is judged.** tcltls 1.8's `-validatecommand` is called once per certificate,
from the top of the chain down. Probing established that the last call is always for the leaf
at depth 0, that the certificate data includes `sha256_hash`, and that a callback raising an
error fails the handshake. A failure higher in the chain therefore passes provisionally, and
only if the `host:port` has an exception at all; the verdict is given at depth 0 against the
leaf. Faults inside the check refuse. tcltls 1.7 lacks the option and is unchanged.

**Reviewing sends no request.** `rio::tls::inspect` completes a handshake with a callback that
accepts everything and records every problem, then closes without sending a request. It opens
a plain TCP connection first and adds TLS on top, because an asynchronous tcltls socket never
reports a refused connection.

**The accepted fingerprint is the one the user saw.** `tls.accept {host port sha256
?subject?}` takes the fingerprint from the dialog and never fetches the certificate again, so
a server cannot substitute a certificate between review and acceptance.

**A distinct error code.** The error taxonomy (ADR-0113) gains `untrusted_cert`, raised when
`rio::tls` refused the chain. It is the one failure a client handles differently.

**Operations:** `tls.inspect {url ?timeout?}`, `tls.accept`, `tls.accepted {}`,
`tls.forget {host port}`.

**The GUI.**

- No dialog appears during scans or the start-up update check.
- A refused source is listed as "certificate not trusted" rather than "unreachable", and its
  detail pane offers **Review certificate…**.
- The review lists problems as sentences ("It expired on …", "It was issued for
  other.example, not for repo.example") and shows the subject, names, issuer, validity and
  fingerprint in a bordered, selectable box (ADR-0068).
- Preferences ▸ Extensions ▸ Accepted certificates… lists exceptions and removes them.

## Alternatives considered

Trusting a host rather than a certificate. Rejected: it would accept whatever certificate the
host presents next, which is the impersonation the refusal exists to prevent.

## Consequences

- Self-hosted repositories with private or expired certificates are usable after one explicit
  decision, and a later certificate change is visible.
- If a repository redirects to a different https server whose certificate is refused, the
  review inspects the repository's own origin, which verifies; the dialog says so and offers
  no Accept.
- The agent honours exceptions but has no review prompt of its own.
- There is no revocation. An accepted certificate is trusted until it changes or the exception
  is removed, as in browsers.
- tcltls 1.8 or newer is required.
