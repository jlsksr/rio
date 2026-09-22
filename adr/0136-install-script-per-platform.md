# ADR-0136: One install script per platform, and a launcher that makes rio an application

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** jka
- **Decision log:** AGENTS.md D129

## Context

rio was a day from its first release with three setup scripts that did not read as an
install.

Two of them carried **`dev-deploy`** in the name and so announced themselves as
development-environment setup, which is not what a stranger who has just cloned rio is
looking for. Which script belonged to which operating system was visible only in the file
extension, `.sh` against `.ps1`. Both of those were jka's own observation.

The third problem was larger. `rio-dev-deploy.sh` **stopped at packages**: it installed the
Tcl/Tk toolchain, verified that it loaded, and ended. The user was left to type
`wish rio-gui/rio-gui.tcl` from inside the checkout — there was no `rio` command, no
application-menu entry and no icon anywhere but inside the running window, although
`rio-gui/icons/` has carried a full set of sizes since [ADR-0127](0127-artwork-rio-can-pass-on.md).
`rio-dev-deploy.ps1`, meanwhile, had been a real installer all along: its own synopsis read
*"set up rio for daily use on Windows 11"*, and it winget-installed the toolchain, set the
persistence variables and could drop a shortcut. Its name was the lie, not its content.

One constraint shapes everything below: **rio has no packaging path.** It runs from a
checkout — a fact [ADR-0100](0100-manual-renderer.md) already leaned on when it dropped
the question of installing `docs/`, since the manual is already beside the code wherever
rio runs. So "installing rio" cannot mean copying rio anywhere.

## Decision

**Three scripts, one per platform, named for the platform.**

| Script | For |
|--------|-----|
| `install-unix.sh` | Linux, the BSDs, macOS |
| `install-windows.ps1` | Windows 11 |
| `install-server.sh` | a headless box running only the core, edited remotely |

**One script per platform, not a user script beside a developer script.** jka offered
either. The developer extras stay as flags: `--with-ck` is labelled *for contributors*, and
`--no-launcher` installs the toolchain alone, which is what someone with several clones
wants. `--launcher-only` takes the other half, and doubles as the answer for a system whose
package manager rio does not know.

**An install is the toolchain plus a launcher that points back into the checkout.** On
POSIX that is a `rio` command in `~/.local/bin`, rio's icon at every shipped size in
`~/.local/share/icons/hicolor`, and a `.desktop` entry in `~/.local/share/applications`.
Everything is per-user, nothing needs root, nothing lands outside the account, and
`--uninstall` removes exactly those three things. `--prefix` covers a system-wide install.
The script never uninstalls packages: other things on the machine need Tcl.

**The launcher is a generated wrapper script, never a symlink.** Tcl's `file normalize`
does not resolve symlinks, so `[info script]` would stay the *link's* path — and
`rio-gui.tcl`'s first act is to source `../rio-core/deps.tcl` relative to it. A symlink in
`~/.local/bin` would therefore send rio looking for its core in `~/.local/` and kill it
before the dependency gate of [ADR-0122](0122-missing-dependency-names-its-package.md)
could say anything useful. The wrapper also execs **`wish`, not `tclsh`**, because
`rio-gui.tcl` calls `rio::deps::gui_require`, which assumes Tk is already up and never
requires Tk itself.

**`StartupWMClass` is set to the window's real `WM_CLASS`.** Tk derives that from the
script's name, so it is `rio-gui.tcl` rather than `wish`. It was read with `xprop` from a
live window before being written down, the way [ADR-0127](0127-artwork-rio-can-pass-on.md)
verified `_NET_WM_ICON`. Without it the taskbar shows a running rio as a stray window
instead of grouping it under its own launcher.

**macOS ships attempted, not verified.** `install-unix.sh` now knows Homebrew, and knows
the two things that would otherwise make a first run fail confusingly: Homebrew's Tcl is
keg-only, so its `tclsh` and `wish` are not on `PATH`, and the `tclsh` that *is* on a Mac's
`PATH` is Apple's deprecated 8.5 without Tk or tcllib. Both the verification probe and the
launcher are pointed at Homebrew's by full path. The formula names are a guess — `tcllib`
may not be a formula at all — so a missing one **warns rather than aborting** and the
verify step decides. The run states that macOS is unverified and asks for a report.

**On Windows the shortcut becomes the default** (`-NoShortcut` opts out), a Start Menu
entry joins the Desktop one, and both carry rio's committed `rio.ico` instead of
inheriting wish.exe's Tk feather. Each is a shortcut to `wish.exe` with rio's script as an
argument, never to the `.tcl` file, which would follow whatever Windows currently
associates with `.tcl`.

**`rio::deps::provides` is left unchanged.** `deps.test` holds that table against
INSTALL.md §1's operating-system package names as sets, in both directions. Naming
Homebrew packages in §1's *table* would therefore have required naming them in the one
message a user gets when a package is missing — a claim to make after somebody has run rio
on a Mac, not before. The macOS note is prose beside the table, which that parser skips by
construction, so the guard keeps its full strength.

## Alternatives considered

**A separate pair of user-facing scripts, leaving the dev ones alone.** jka offered this as
the other option. Rejected because two scripts that both apt-install Tcl drift apart, which
is the failure this project's own history records: under
[ADR-0131](0131-changelog-with-a-guard.md) the changelog in PITCH.md sat
fifteen decisions behind, for exactly the reason that keeping it current was an instruction
addressed to whoever happened to be editing.

**A symlink for the launcher.** One line instead of a generated file, and wrong: probed
before the design was fixed, and it breaks rio's module resolution outright.

**Fixing `rio-gui.tcl` to resolve symlinks itself.** Defensible, and the wrong week — a
change to the startup path of the main file the day before a release, to enable a launcher
shape that has no advantage over a wrapper.

**Adding `Utility` to the desktop entry's `Categories`.** `desktop-file-validate` suggested
it as a hint. Refused after trying it: it produces two *main* categories, and the validator
then warns that rio "might appear more than once in the application menu". A hint is not a
defect; a duplicate menu entry is.

**Leaving macOS to stop at "no supported package manager found".** Honest, and it was
weighed. Rejected because the verify step is already the script's stated arbiter for an
unfamiliar system, so a labelled attempt costs nothing a wrong guess would not also cost,
and gives a Mac user somewhere to start and something to report.

## Consequences

A user clones rio, runs one script named after their operating system, and then has `rio`
on the command line and in the application menu. The scripts say what they are, and the
Windows one no longer has to be explained as the counterpart of a "dev" script.

**The launcher bakes in an absolute path**, so moving the checkout requires re-running the
script. The scripts say so and so does INSTALL.md.

**There is a name collision in the wild**: a well-known terminal emulator is also called
`rio`. The script checks before installing and says which `rio` was already on `PATH`,
leaving the user to decide; it does not refuse.

**A new register row, and the guard for it** (AGENTS.md §7). A rename is invisible to every
other check: a document naming a script that no longer exists reads perfectly well and is
simply wrong, which is how `rio-dev-deploy` survived in WINDOWS.md for three decisions
until a reader noticed. `docs.tcl` check 20 holds the shipped `install-*` scripts against
the names the user-facing documents quote, both directions, plus INSTALL.md naming all of
them since it is the canonical home. `Start` joined `prose_not` in the same file, because
Windows' Start Menu is somebody else's proper noun and check 7 would otherwise insist rio
have a *Start* menu.

**Unverified surface.** `install-windows.ps1` has not been run — the development box has no
PowerShell — and macOS has not been run by anyone. Both are stated rather than implied, in
the scripts, in INSTALL.md §8 and in the release notes.

**Still open:** real packaging (.deb, .apk, a Homebrew formula) remains the roadmap's
*Install / packaging path*; this is a deliberately smaller claim, that a checkout can feel
installed. A systemd unit for the headless core, and a `MimeType` association making rio a
handler for `text/plain`, were both left out — the latter competes for every text file on
the machine and should be the user's own choice.
