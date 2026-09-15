# ADR-0039: Extension repositories over plain HTTP, apt-sources style

- **Status:** Accepted; amended by [ADR-0066](0066-installable-providers.md), [ADR-0107](0107-semver-extension-updates.md), [ADR-0109](0109-https-repositories.md)
- **Date:** 2026-07-17
- **Deciders:** jka
- **Decision log:** AGENTS.md D39

## Context

rio had extension surfaces (themes, highlighters, editing modes) but no way to share
an extension other than copying files by hand. ADR-0019 ruled out operating a
marketplace. The maintainer set a durability requirement: distribution should still
work in 20 to 30 years, the way OpenBSD's plain HTTP mirrors do, even if git
disappears. The system also had to accept kinds of extension nobody has thought of
yet.

## Decision

Distribution follows the apt sources model over plain HTTP. There is no central
index and no central authority. The feature is called **Repositories**; it is not a
marketplace.

- **Sources:** `$XDG_CONFIG_HOME/rio/sources.list`, one base URL per line, editable by
  hand or in the Repositories… dialog.
- **Repository marker:** `<base>/rio-repository.conf` with at least `name`. A
  directory without a parseable marker is refused as not a rio repository.
- **Index:** `<base>/index`, one extension directory per line. It is optional;
  without it rio parses the web server's directory listing.
- **Extension manifest:** `<base>/<dir>/rio-extension.conf` with `name`, `kind`,
  `version` and `files` required. Payload files sit beside it: text only, no
  subdirectories, each fetch capped at 2 MB.
- **Safe names:** every remote-supplied name must match
  `^[A-Za-z0-9][A-Za-z0-9._-]*$` before it is joined into a URL or path.
- **Forward compatibility:** parsers ignore unknown keys; an unknown kind is listed
  but not installable ("needs a newer rio").

Fetching runs in the core (`rio::http::get`, surfaced as `repo.fetch`), bounded to
five redirects and 2 MB, so a remote core fetches from its own network and the GUI
has no network dependency. Themes install core-side (`theme.put`, `theme.list`,
`theme.delete`); highlighters and modes install into the GUI's existing drop-in
directories.

Same-named extensions from different repositories coexist as variants labelled with
version, author and source host; the user chooses. Every install is recorded in a
provenance ledger (`$XDG_DATA_HOME/rio/extensions.json`), used for replacement
consent, collision refusal and removing extensions whose source has gone. Consent
names code as code: highlighters and modes are "Tcl code that will run inside your
editor", themes are data. Installs are all-or-nothing. The trust model is apt's:
the sources list is the trust list. A `.well-known/rio-repository` file is specified
for later host validation but not yet consumed.

The UI is the non-modal Extensions window: one row per kind and name, every variant
in the detail section, and one row per unreachable source.

Initially `version` was an opaque string, rio used plain HTTP only, and an
`https://` source was refused with advice to use a TLS proxy. rio ships with one
default source, `http://rio.skylm.org/rio`, written only on the first run.

## Alternatives considered

A marketplace service, a curated central index, and git-backed sources. Each creates
an operator, a gatekeeper or a dependency that can decay. A plain HTTP directory can
be served by any web server and published with three text files.

## Consequences

- Anyone can publish, self-hosting is trivial, and there is nothing to shut down.
- Without a namespace, name collisions are expected and surfaced to the user.
- There is no signing or sandboxing; trust rests on the sources the user adds.
- The ledger is GUI-side, so a second frontend on the same daemon does not see what
  the first installed. For providers this was resolved by reading the core's own
  store (ADR-0107).
- Later changes: providers became an installable kind (ADR-0066); versions became
  semver and comparable (ADR-0107); https became an option beside http (ADR-0109).
- Network behaviour could not be tested live at first. A charset defect in fetched
  payloads went unnoticed until ADR-0106 found it, which is why network code is now
  also tested over loopback (ADR-0116).
