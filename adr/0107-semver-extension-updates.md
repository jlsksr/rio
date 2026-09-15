# ADR-0107: Extension versions are semver and are compared

- **Status:** Accepted
- **Date:** 2026-09-12
- **Deciders:** jka
- **Decision log:** AGENTS.md D107

## Context

The Extensions window could install and remove, but could not tell a user whether an
installed extension was out of date. ADR-0039 had made `version` an opaque string that rio
never compares. The maintainer asked for apt-like update checks and upgrades, run from the
window, when it opens, and optionally at start-up.

## Decision

**Versions are Semantic Versioning, and rio orders them.** This reverses ADR-0039's rule
while all extensions are still in-house.

- Parsing is lenient in one respect: one to three numeric components, missing ones treated
  as zero, so `1.1` reads as `1.1.0`. Pre-release identifiers require all three components;
  otherwise a date such as `2026-07-17` would parse as a version. Build metadata is ignored.
- A string that does not parse makes no claim: the extension still lists and installs,
  marked "version not comparable", but no update is offered.

**Updates come from the same source by default.** With no central namespace (ADR-0039),
an extension of the same name on another host may be a different program. An update is
offered only from the repository the ledger records. A higher version elsewhere is listed
as a variant to switch to explicitly, with consent that names the new source. A
per-extension `anysource` flag allows cross-source updates for mirrors and forks.

**The installed version of a provider comes from the core.** The GUI's view of installed
extensions starts from its ledger, but for providers `provider.list` is authoritative, so a
provider installed by another frontend or on a remote core shows its real version and can be
updated or removed. This derived view is never written back to the ledger.

**Consent matches the decision.** Update All asks once, listing each extension, its version
change and its host. Updates that cross into a different repository are listed separately
under their own heading.

**The start-up check is opt-in and quiet.** It is off by default, because a fresh rio makes
no network request it was not asked to make, and on a remote core the request comes from
someone else's machine. It runs on a timer after start-up, waits while another operation is
in flight, ignores failures, and reports only findings, in a plain dialog with a "Don't check
for updates at start-up" option. The dialog does not grab input. The setting lives in a new
Preferences ▸ Extensions page. A badge on the menu item was rejected as out of keeping with
the period style.

## Consequences

- Users can see and apply updates, individually or all at once.
- Publishers must follow semver to get update tracking; not doing so costs only that.
- No core changes were needed; the division of labour in ADR-0039 held.
- rio's own extensions were renumbered to three-component versions.
