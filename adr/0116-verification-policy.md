# ADR-0116: Verification is automated, offline, and proven against injected faults

- **Status:** Accepted
- **Date:** 2026-09-11
- **Deciders:** jka
- **Decision log:** AGENTS.md D31, D39, D95, D109; project policy

## Context

Over time several ways of verifying changes proved unreliable:

- Manual click-through checklists handed to the maintainer cost time and cannot be repeated.
- Tests against live network services depend on the environment and cannot run everywhere.
  Having no network test at all hid a charset defect in repository fetches for two months
  (ADR-0106).
- A GUI test that raised a dialog waited for a human, whose answer then shaped the result
  (ADR-0095).
- Tests that call core operations directly passed while the wire encoder dropped a field
  (ADR-0110).
- A test that has never been seen to fail may not test anything.

## Decision

- **The automated suites are the verification.** The core suite, the provider and runtime
  suites, the syntax suite, and the headless GUI suites (including the documentation checks)
  must pass. Manual checks are mentioned only where nothing headless can observe the result,
  such as the feel of a drag or the legibility of a glyph, and they are never a gate.
- **Tests do not use the internet.** Network code is tested through stubbed seams
  (`rio::http::get` in the core, `repo_fetch` in the GUI), and real protocol behaviour is
  tested over loopback against a server running as a child process
  (`rio-core/tests/tls-server.tcl`, `openssl s_server`) with certificates generated per run.
  A server in the same process would deadlock against the synchronous HTTP client. Tests
  needing a tool that is absent (`openssl`, `git`, tcltls 1.8) are skipped, not failed.
- **Tests that spend money need permission.** Tests that call hosted LLM APIs with real keys
  run only when the maintainer agrees each time. Everything else runs freely.
- **GUI tests are isolated.** They redirect XDG directories to a temporary location
  (`rio-gui/tests/sandbox.tcl`), run under `RIO_GUI_HEADLESS`, and fail on any dialog
  (ADR-0095).
- **Wire shapes are tested through the encoder**, using each operation's real result.
- **A new check is proven by injection.** The change it guards is deliberately broken, and
  the check must fail, by name, before the fix is considered verified. Decision records list
  the injections used.

## Consequences

- Results are repeatable on any machine and in any network environment.
- Test code is a substantial part of the project.
- Some behaviour (live model responses, platform-specific stores, visual feel) is outside
  automated reach and is stated as such rather than claimed.
