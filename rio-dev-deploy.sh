#!/bin/sh
#
# rio-dev-deploy.sh — set up a development environment for rio.
#
# rio is built on Tcl/Tk (core + GUI) with optional Ck (curses Tk) for the
# terminal frontend. This script installs that toolchain so you can build and
# hack on rio. It is POSIX sh and tries to work across the systems rio targets:
# Debian/Ubuntu (apt), Alpine (apk), and OpenBSD (pkg_add).
#
# What it installs:
#   - tclsh + Tk        the language and GUI toolkit rio is written in
#   - tcltls            TLS sockets, needed for the HTTPS agent provider
#   - tcllib            json + assorted pure-Tcl libraries
#   - git               (verified; rio integrates with it and we build Ck from it)
#
# Optional, behind --with-ck:
#   - Ck (curses Tk)    the terminal frontend toolkit. Not packaged by distros,
#                       so we build the maintained vzvca/ck8.6 fork from source.
#                       This is the deferred TUI path (see AGENTS.md O1) — only
#                       pull it in if you mean to work on the terminal frontend.
#
# Usage:
#   ./rio-dev-deploy.sh [--with-ck] [--verify-only] [--dry-run] [-h|--help]
#
# It is safe to re-run: installs are idempotent and the script finishes by
# verifying the toolchain actually loads, which is the real source of truth.

set -eu

# --- options ----------------------------------------------------------------

WITH_CK=0
VERIFY_ONLY=0
DRY_RUN=0

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--with-ck)     WITH_CK=1 ;;
		--verify-only) VERIFY_ONLY=1 ;;
		--dry-run)     DRY_RUN=1 ;;
		-h|--help)     usage 0 ;;
		*) echo "rio-dev-deploy: unknown option: $1" >&2; usage 1 ;;
	esac
	shift
done

# --- helpers ----------------------------------------------------------------

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Run a privileged command, using sudo/doas only when we are not already root
# and only when not a dry run. In dry-run mode we just print it.
SUDO=""
pick_sudo() {
	[ "$(id -u)" = 0 ] && return 0
	if   have doas; then SUDO="doas"
	elif have sudo; then SUDO="sudo"
	else warn "not root and no sudo/doas found — install steps may fail"
	fi
}

run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] %s\n' "$*"
	else
		# shellcheck disable=SC2086
		$SUDO "$@"
	fi
}

# --- package manager detection ----------------------------------------------
#
# Per-manager package name lists. The verify step below is what actually
# decides success, so if a name is wrong on your distro, fix it here and the
# verifier will confirm.

detect_pm() {
	if   have apt-get; then PM=apt
	elif have apk;     then PM=apk
	elif have pkg_add; then PM=pkg_add   # OpenBSD
	else die "no supported package manager found (need apt-get, apk, or pkg_add)"
	fi
	log "package manager: $PM"
}

install_base() {
	case "$PM" in
		apt)
			run apt-get update
			run apt-get install -y tcl tk tcl-tls tcllib git
			;;
		apk)
			run apk add --no-interactive tcl tk tcl-tls tcllib git
			;;
		pkg_add)
			# OpenBSD package stems; pkg_add resolves the 8.6 flavors.
			run pkg_add -I tcl%8.6 tk%8.6 tcl-tls tcllib git
			;;
	esac
}

# --- optional: build Ck (curses Tk) from source -----------------------------

CK_REPO="https://github.com/vzvca/ck8.6.git"
CK_SRC="${TMPDIR:-/tmp}/rio-ck-build"

install_ck_deps() {
	case "$PM" in
		apt)     run apt-get install -y build-essential tcl-dev libncurses-dev ;;
		apk)     run apk add --no-interactive build-base tcl-dev ncurses-dev ;;
		pkg_add) warn "OpenBSD: install C toolchain + ncurses headers yourself if missing" ;;
	esac
}

build_ck() {
	have git || die "git is required to build Ck"
	install_ck_deps
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] clone+build Ck from %s into %s\n' "$CK_REPO" "$CK_SRC"
		return 0
	fi
	log "building Ck from $CK_REPO"
	rm -rf "$CK_SRC"
	git clone --depth 1 "$CK_REPO" "$CK_SRC"
	# configure needs the dir holding tclConfig.sh (it otherwise assumes
	# ../../tcl8.0 and fails to find Tcl).
	tclconf=$(find /usr/lib /usr/lib64 /usr/local/lib -name tclConfig.sh 2>/dev/null | sort | tail -1)
	[ -n "$tclconf" ] || die "tclConfig.sh not found — install the Tcl dev package"
	# Ck is old K&R-ish C: it calls functions before they're declared and uses
	# tentative globals. GCC 14+ makes both HARD ERRORS by default, so demote
	# them back to warnings (+ -fcommon). This configure ignores env CFLAGS and
	# hardcodes `CFLAGS = -g3`, so override on the make line (CC_SWITCHES re-adds
	# the -fPIC shlib flags). The implicitly-declared funcs are int-returning Tcl
	# init helpers, so the assumed `int` is correct. (Validated by the O1 spike;
	# see spike/probes/VERDICT.md.)
	ck_cflags="-g3 -fcommon -Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=int-conversion"
	( cd "$CK_SRC" && ./configure --with-tcl="$(dirname "$tclconf")" --enable-shared \
		&& make CFLAGS="$ck_cflags" )
	run make -C "$CK_SRC" install
	# Built --enable-shared: if `cwsh` later can't find libck8.6.so, either run
	# ldconfig or set LD_LIBRARY_PATH to the install libdir / "$CK_SRC".
}

# --- verification -----------------------------------------------------------
#
# The real test: does the toolchain load? We probe with tclsh itself. Tk needs
# a display to fully initialize, so we treat "package present but no display" as
# success — we only fail if the package can't be found at all.

verify() {
	if [ "$DRY_RUN" = 1 ]; then
		log "verify: skipped (dry run)"
		return 0
	fi
	have tclsh || die "tclsh not found after install"
	log "verifying Tcl toolchain ($(tclsh <<'EOF'
puts [info patchlevel]
EOF
))"
	tclsh <<'EOF'
set fail 0
proc check {name {require 1}} {
	global fail
	if {[catch {package require $name} ver]} {
		# Tk legitimately errors with no DISPLAY; that still means it is installed.
		if {[string match {*find package*} $ver] || [string match {*can't find*} $ver]} {
			puts [format "  %-8s MISSING (%s)" $name $ver]
			if {$require} {incr fail}
		} else {
			puts [format "  %-8s ok (installed; load note: %s)" $name $ver]
		}
	} else {
		# Loading Tk creates the main window "." and it would map on exit,
		# flashing an empty window. We only care that the package loads, so
		# withdraw it immediately (before any event-loop turn maps it).
		if {$name eq "Tk"} {catch {wm withdraw .}}
		puts [format "  %-8s ok %s" $name $ver]
	}
}
check Tk
check tls
check json
puts [format "  %-8s %s" tclsh [info patchlevel]]
if {$fail} {
	puts stderr "verify: $fail required package(s) missing"
	exit 1
}
# With Tk loaded, tclsh would otherwise enter the event loop at stdin EOF
# and hang. Exit explicitly.
exit 0
EOF
	log "toolchain OK"
}

# --- main -------------------------------------------------------------------

pick_sudo
detect_pm

if [ "$VERIFY_ONLY" = 1 ]; then
	verify
	exit 0
fi

install_base
[ "$WITH_CK" = 1 ] && build_ck
verify

log "done."
[ "$WITH_CK" = 1 ] || log "TUI/Ck skipped — re-run with --with-ck when you need it."
