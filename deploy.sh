#!/bin/sh
# deploy.sh — set up a Debian box to build/run rio AND the O1 Ck spike.
#
# rio's core+GUI need only tclsh/wish (already present on most boxes). This
# script additionally provisions the TUI spike (AGENTS.md O1): it installs the
# build deps and compiles Ck (the curses Tk) from source into a LOCAL prefix
# under spike/ck8.6 — no `make install`, nothing lands in /usr. The only step
# that touches the system is the apt-get install (hence sudo); everything else
# is contained in this repo and removable with `rm -rf spike/ck8.6`.
#
# Debian/Ubuntu only (apt). On Alpine/OpenBSD install the equivalents by hand:
#   tcl-dev, ncurses(-dev), tmux, autoconf, a C compiler + make.
#
# Usage:  ./deploy.sh            # full setup (prompts for sudo on the apt step)
#         ./deploy.sh --no-apt   # skip apt (deps already present); just build Ck
set -eu

repo="$(cd "$(dirname "$0")" && pwd)"
ck_src="$repo/spike/ck8.6"
ck_url="https://github.com/vzvca/ck8.6"

log() { printf '\n=== %s ===\n' "$*"; }

# --- 1. system build deps (the only privileged step) -------------------------
if [ "${1:-}" != "--no-apt" ]; then
	log "installing build deps (sudo apt-get)"
	# build-essential: cc/make. tcl-dev: tcl.h + tclConfig.sh (Ck links libtcl).
	# libncurses-dev: ncursesw headers/lib (Ck's screen backend). autoconf: in
	# case the shipped ./configure must be regenerated. tmux: lets the spike be
	# driven/inspected headlessly (capture-pane, resize) on this box.
	sudo apt-get update
	sudo apt-get install -y build-essential tcl-dev libncurses-dev autoconf tmux git
else
	log "skipping apt (per --no-apt)"
fi

# --- 2. fetch Ck source ------------------------------------------------------
log "fetching Ck (vzvca/ck8.6) into spike/ck8.6"
if [ -d "$ck_src/.git" ]; then
	git -C "$ck_src" pull --ff-only || echo "(pull skipped; using existing checkout)"
else
	mkdir -p "$repo/spike"
	git clone --depth 1 "$ck_url" "$ck_src"
fi

# --- 3. locate Tcl's config (tclConfig.sh) -----------------------------------
log "locating tclConfig.sh"
tclconf="$(find /usr/lib /usr/lib64 -name tclConfig.sh 2>/dev/null | sort | tail -1 || true)"
if [ -z "$tclconf" ]; then
	echo "ERROR: tclConfig.sh not found — is tcl-dev installed?" >&2
	exit 1
fi
tcldir="$(dirname "$tclconf")"
echo "using --with-tcl=$tcldir"

# --- 4. build Ck (into the source tree; no install) --------------------------
log "building Ck"
cd "$ck_src"
# Ck is old K&R-ish C: it uses functions before they're defined (relying on
# implicit declaration) and tentative globals. GCC 14 (Debian 13) makes both a
# hard error by default, so demote them back to warnings — the GCC-14-documented
# porting flags — and add -fcommon for the tentative-definition case. The
# implicitly-declared functions here are all int-returning Tcl init helpers, so
# the assumed `int` is correct (no 64-bit pointer truncation). This configure
# ignores $CFLAGS and hardcodes `CFLAGS = -g3`, so override it on the make line
# (CC_SWITCHES re-adds the -fPIC shlib flags, so we keep -g3 and add ours).
ck_cflags="-g3 -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion"
# Prefer the shipped configure; regenerate from configure.in only if it's absent.
[ -x ./configure ] || autoconf
./configure --with-tcl="$tcldir" --enable-shared
make CFLAGS="$ck_cflags"
cd "$repo"

# --- 5. verify ---------------------------------------------------------------
log "verifying"
if [ -x "$ck_src/cwsh" ]; then
	echo "OK: built $ck_src/cwsh"
	echo
	echo "Run a spike probe in YOUR terminal, e.g.:"
	echo "  LD_LIBRARY_PATH=$ck_src CK_LIBRARY=$ck_src/library $ck_src/cwsh $repo/spike/probes/01-build-run.tcl"
	echo "or drive the whole suite headlessly via tmux:"
	echo "  $repo/spike/probes/run-all.sh"
else
	echo "ERROR: cwsh did not build — check the make output above." >&2
	exit 1
fi
