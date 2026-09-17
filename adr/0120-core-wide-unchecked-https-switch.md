# ADR-0120: One core-wide switch for https without host-name checks

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** jka
- **Decision log:** AGENTS.md D114

## Context

On tcltls older than 1.8 a certificate's chain is verified but its name is never compared
with the host (ADR-0109). ADR-0110 let the user allow such connections for the agent only,
through a setting stored with the agent's configuration and shown under Preferences ▸ Agent.
https repositories on such a core stayed refused outright, with no way out but upgrading
tcltls or using the repository's http URL.

ADR-0110 justified leaving repositories without a switch on two grounds: nobody depended on
https repositories yet, and http is first-class. Reading the caveat that described the gap,
the maintainer asked why the user could not opt out there too. Neither ground holds up:

- Unchecked https is never weaker than plain http, which repositories already accept for
  code the core then runs. The chain is still checked; only the name is not.
- A repository that serves https only cannot be used at all on such a core.

The risk the switch accepts is also not a property of any one feature. It is the core's
tcltls, dialling the same network, whichever feature opens the connection.

## Decision

**One switch, the core's, for every https connection it makes.** On a tcltls older than 1.8,
agent requests and repository fetches ask the same question and refuse unless the user
allowed unchecked host names. The switch is off by default and has no effect on a tcltls that
checks names. Plain `http://` is never gated.

**It lives with the core's TLS policy**, not with either feature:

- **Storage:** `$XDG_CONFIG_HOME/rio/tls.conf` on the core's host, beside
  `certificates.conf`, in the conf format (ADR-0021), as `unchecked_hostnames = allow`. Only
  that top-level line allows. A missing file, another value, the line inside a section, or a
  malformed file all mean refuse. The file is read on every connection, so a hand edit applies
  without a restart.
- **Operations:** `tls.settings {}` returns `{unchecked checks_hostname tcltls}`;
  `tls.settings.set {unchecked}` writes the setting. A non-boolean is a `bad_request`, and a
  setting that cannot be written is an `io_error`. The tcltls version and whether it checks
  names let a client say whether the switch matters on the core it is attached to.

**The refusals name the ways out.** A refused repository fetch names three: upgrade tcltls,
use the http URL, or turn on the switch. The agent's refusal keeps the phrase the providers
already match, so providers need no new release; only the menu path in the message changes.

**A new Preferences category, Network,** between Extensions and Keyboard. It holds the
checkbox, a muted hint (ADR-0068) saying whether this core's tcltls makes the switch matter,
and **Accepted certificates…**, moved there from Extensions, since certificate exceptions
(ADR-0111) also apply to every https connection the core makes. The Agent category loses its
https setting. The GUI mirrors the core's setting at every attach and does nothing against a
core that lacks the operation.

**A clean move.** The agent's copy of the setting, its file, its operation and its field in
the agent's status are removed. An `allow` stored in the old agent file is not carried over:
it reads as refuse until the user ticks the box again. The protocol version is not bumped,
because GUI and core ship together; an older GUI on this core fails only when it toggles the
switch, and says so.

Accepting a single certificate (ADR-0111) still requires tcltls 1.8; this decision does not
change that.

## Alternatives considered

**Two switches, one per feature.** The risk is one fact, the core's tcltls on the same
network. Two checkboxes could only let the answers to that one question disagree.

**Keeping the agent's names for the setting.** The file, the operation and the preference
would all say "agent" about something that is no longer the agent's.

**Placing the switch under Agent or under Extensions.** Either category would hide half of
what the switch governs. The maintainer chose a new Network category.

**Migrating an existing allow from the agent's file.** The maintainer chose a clean move.
Dropping the old value leaves the user on the secure side, and costs one tick to restore.

**Leaving repositories without a switch**, as ADR-0110 did. Rejected for the reasons in the
context: an unchecked https fetch is no weaker than the http fetch repositories already
allow, and without the switch an https-only repository is unreachable on an older tcltls.

## Consequences

- https-only repositories are usable on a core with tcltls older than 1.8, after one explicit
  decision that also covers the agent.
- One setting, one file and one Preferences location describe the core's https policy;
  a new feature that opens https connections inherits it rather than adding its own.
- A user who had allowed unchecked https for the agent loses that choice on upgrade and has to
  set it again under Preferences ▸ Network.
- Clients that used the agent's operation or status field must move to the `tls.*`
  operations.
