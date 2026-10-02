# ADR-0141: macOS gets its own installer, and rio.app is a copy of wish

- **Status:** Accepted
- **Date:** 2026-09-29
- **Deciders:** jka
- **Decision:** D134

## Context

ADR-0136 (D129) put macOS inside `install-unix.sh`, as a Homebrew branch nobody had run.
ADR-0140 (D133) then ran rio on a Mac for the first time. That machine had no root and a
Homebrew it could not write to, so the toolchain had to be built by hand.

The Mac branch shared nothing with the rest of `install-unix.sh`:

| | `install-unix.sh` | macOS |
|---|---|---|
| Package managers | apt, apk, pkg_add | Homebrew, MacPorts |
| Fallback | none | a source build |
| Launcher | `.desktop` file, hicolor icons | `.app` bundle, `.icns` icon |

It was also broken. `brew install tcl-tk` now installs Tcl 9, which rio has never run on,
and there is no `tcllib` formula.

A Mac launcher also has to give rio its own identity. Tk names the application menu from the
main bundle's `CFBundleName`.

## Decision

**macOS has its own script, `install-macos.sh`.** It keeps ADR-0136's rules: the platform
is in the name, a per-user install needs no root, `--uninstall` removes what was installed,
and packages are never uninstalled. `install-unix.sh` drops its Homebrew branch and, on a
Mac, points at the new script.

**The toolchain is the first of four sources that works**, and `--use` forces one:
1. **`path`**: a Tcl 8.6 with Aqua Tk and tcllib already on `PATH`.
2. **`brew`**: Homebrew's `tcl-tk@8`, installed only when Homebrew is writable.
3. **`macports`**: the pinned subports `tcl8 tk8-quartz tcllib tcl8-tls`, after a y/N,
   through sudo.
4. **`source`**: Tcl/Tk 8.6.18, tcllib 2.0 and tcltls 1.8, built into `~/.local/rio-env`.
   Every tarball is pinned by SHA-256. tcltls is fetched by fossil check-in rather than by
   tag.

Apple's Tcl 8.5 and any Tcl 9 are refused with a reason.

**A tcltls older than 1.8 is topped up** to 1.8 in the toolchain directory, never inside
Homebrew's or MacPorts' tree. Both launchers put that directory on `TCLLIBPATH`.

**The launcher is a `rio` command and a `rio.app`.**
- The app's executable is a **copy of the `wish` binary**, so the main bundle is `rio.app`
  and the menu says rio.
- That wish runs `Resources/Scripts/AppMain.tcl` by itself. The script puts a `tclsh` link
  to the chosen interpreter first on `PATH`, so the core starts on it, and starts rio.
- The bundle is ad-hoc signed.
- The `rio` wrapper gives wish an empty pipe for stdin when there is no tty.

**`--uninstall` removes only what a manifest names**, and each thing only if it still looks
like ours. The install refuses to overwrite a `rio` command or `rio.app` that isn't ours.

**On Aqua, rio defines `::tk::mac::Quit` to run `do_quit`**, so Cmd-Q asks about unsaved work.

## Alternatives considered

- **Keep macOS in `install-unix.sh`.** Rejected. The two halves share no code, and ADR-0136's
  drift argument only applies to scripts that install the same packages.
- **Make `Contents/MacOS/rio` a shell script that execs wish.** Rejected, after measuring it
  with `::tk::mac::GetAppPath`. The main bundle is then wish's own directory, so the menu
  reads *Wish*, and *Quit Wish*.
- **Make it a symlink to wish.** Rejected for the same reason: the link is resolved.
- **Plain `brew install tcl-tk`, or the plain MacPorts `tcl`/`tk` ports.** Rejected. The
  formula is Tcl 9 already, and the ports are metaports that can follow it.
- **ActiveTcl.** Not offered. The free anonymous download has ended. A user who has it gets
  it through `path`.
- **Upscale the icon to 1024 px for the iconset.** Rejected. The source is 516 px, so the
  1024 would only be a blurrier copy of the 512.

## Consequences

- A Mac without root can install rio with one command and the Xcode command-line tools.
- rio appears in Spotlight, the Dock and Finder under its own name and icon.
- The copied wish doesn't follow a toolchain upgrade. Re-running the script refreshes it.
- The source path, the top-up, the app and uninstall were verified on macOS 27, and the full
  suite passes on Tcl/Tk 8.6.18 with a separately installed tcltls 1.8.
- The `brew` and `macports` install branches have not been run. Nor has MacPorts' tcltls
  2.0.1 been tested against rio's TLS code.
- That the menu bar reads "rio" follows from `GetAppPath` and Tk's source. Nobody has looked
  at it on a screen.
