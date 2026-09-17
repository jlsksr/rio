# ADR-0109: https beside http, trusted from the host's CA store

- **Status:** Accepted; amended by [ADR-0110](0110-agent-https-hostname-checks.md), [ADR-0111](0111-certificate-exceptions.md), [ADR-0120](0120-core-wide-unchecked-https-switch.md)
- **Date:** 2026-09-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D109

## Context

The maintainer asked for https support in extension repositories, using each platform's
certificate store, while keeping plain http first-class: "like with Debian sources, https is
an option, not an obligation". ADR-0039 had refused https. `tcltls` was already a core
dependency for the agent.

The providers' transport had its own TLS setup: `-require 1` and a CA file chosen from three
Unix paths. On Windows none of those paths exist, so verification depended on wherever the
OpenSSL build happened to look.

## Decision

**One TLS policy for every https connection the core makes.** `rio-core/tls.tcl`
(`rio::tls`) is used by repository fetches and by provider requests alike. The CA source is
the first that applies:

1. `SSL_CERT_FILE` or `SSL_CERT_DIR`, passed explicitly;
2. the system CA bundle;
3. on Windows with tcltls 1.8 or newer on OpenSSL 3.2 or newer, the Windows certificate store;
4. otherwise no CA source, and `-require 1` regardless, so the handshake fails closed.

The choice is a pure function of platform, environment and library versions, tested on any
host.

**Host names are checked, which requires tcltls 1.8.** A loopback probe showed that tcltls
1.8.0 verifies the host name (through `-servername`) and 1.7.22 does not. An https repository
on an older tcltls is refused with an explanation.

**http remains first-class.** `tcltls` loads on the first https connection, so a core without
it serves http repositories as before. No warning attaches to http. A redirect from https to
http is refused (as apt does); http to https is followed; a scheme-relative location inherits
the scheme.

**Errors explain themselves.** A refused certificate had surfaced as a generic socket failure
("check your connection"). On tcltls 1.8 the verification reason is captured and reported
("self-signed certificate", "hostname mismatch"), with `SSL_CERT_FILE` named where trusting
a CA is the fix.

**Source identity ignores the scheme.** Updates are offered from the same source (ADR-0107).
Comparing sources without their scheme means moving a repository from http to https does not
make installed extensions look foreign.

## Alternatives considered

A CA bundle shipped with rio. Rejected: rio would become a certificate distributor with a
refresh obligation; a stale bundle breaks sites or trusts revoked roots; and it would ignore
roots an administrator installed, which is exactly the private-CA case self-hosted
repositories need.

## Consequences

- Repositories and providers verify certificates identically on every platform.
- The Windows store path follows tcltls documentation and has not yet run on Windows.
- The default repository stays http until its host serves https; the change is one line and
  does not affect existing installs.
- Two follow-ups: the agent on old tcltls (ADR-0110), and certificates that fail
  verification (ADR-0111).
