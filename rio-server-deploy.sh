#!/bin/sh
#
# rio-server-deploy.sh — install rio-core's server-mode runtime on a headless box.
#
# Server mode (AGENTS.md D29) runs the UI-less core behind a socket; a remote rio
# GUI then drives it over an SSH tunnel. The core is Tk-FREE (D1) and, with the
# agent kept client-side this iteration, needs no TLS — so the server's whole
# runtime is just tclsh + tcllib (for JSON), plus git if you want the git pane.
# This is the slim counterpart to rio-dev-deploy.sh (which sets up a full GUI/dev
# toolchain). POSIX sh; targets Alpine (apk), Debian/Ubuntu (apt), OpenBSD (pkg_add).
#
# What it installs:
#   - tclsh     the Tcl interpreter the core runs on (no Tk — the server is headless)
#   - tcllib    provides the json package the wire protocol parses with
#               (Alpine names this package tcl-lib, in the community repo)
#   - git       recommended: the git pane shells out to it (skip with --no-git)
#
# Usage:
#   ./rio-server-deploy.sh [--no-git] [--verify-only] [--dry-run] [-h|--help]
#
# Safe to re-run: installs are idempotent, and it finishes by actually loading the
# core (sourcing server.tcl + binding an ephemeral port) — the real proof it works.

set -eu

# --- options ----------------------------------------------------------------

WITH_GIT=1
VERIFY_ONLY=0
DRY_RUN=0

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#//'
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--no-git)      WITH_GIT=0 ;;
		--verify-only) VERIFY_ONLY=1 ;;
		--dry-run)     DRY_RUN=1 ;;
		-h|--help)     usage 0 ;;
		*) echo "rio-server-deploy: unknown option: $1" >&2; usage 1 ;;
	esac
	shift
done

# --- helpers ----------------------------------------------------------------

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Run a privileged command, using sudo/doas only when not already root and not a
# dry run. In dry-run mode we just print it.
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
# apk first (the typical headless/Alpine target). The verify step below is what
# actually decides success, so if a package name is wrong on your distro, fix it
# in install_server and the verifier will confirm.

detect_pm() {
	if   have apk;     then PM=apk        # Alpine (and other apk distros)
	elif have apt-get; then PM=apt        # Debian/Ubuntu
	elif have pkg_add; then PM=pkg_add    # OpenBSD
	else die "no supported package manager found (need apk, apt-get, or pkg_add)"
	fi
	log "package manager: $PM"
}

install_server() {
	# No Tk, no tcl-tls: the server is headless and the agent stays client-side.
	# The pure-Tcl json library is "tcllib" on Debian/OpenBSD, but Alpine renamed it
	# to "tcl-lib" (community repo); old Alpine still calls it "tcllib".
	case "$PM" in
		apt)
			set -- tcl tcllib
			[ "$WITH_GIT" = 1 ] && set -- "$@" git
			run apt-get update
			run apt-get install -y "$@"
			;;
		apk)
			run apk update
			lib=tcl-lib
			if [ "$DRY_RUN" != 1 ]; then
				if   apk search -x tcl-lib 2>/dev/null | grep -q .; then lib=tcl-lib
				elif apk search -x tcllib  2>/dev/null | grep -q .; then lib=tcllib
				else die "no tcl-lib/tcllib in the apk index — enable the 'community' repository in /etc/apk/repositories, then re-run"
				fi
			fi
			set -- tcl "$lib"
			[ "$WITH_GIT" = 1 ] && set -- "$@" git
			run apk add --no-interactive "$@"
			;;
		pkg_add)
			set -- tcl%8.6 tcllib
			[ "$WITH_GIT" = 1 ] && set -- "$@" git
			# shellcheck disable=SC2086
			run pkg_add -I "$@"
			;;
	esac
}

# --- verification -----------------------------------------------------------
#
# The real proof: load the core the way the server does and bind a throwaway
# socket. Sourcing server.tcl pulls in core.tcl + wire.tcl (so every module the
# server needs must parse), and its direct-exec guard does NOT fire when sourced
# from here, so it won't block in the event loop.

verify() {
	if [ "$DRY_RUN" = 1 ]; then
		log "verify: skipped (dry run)"
		return 0
	fi
	have tclsh || die "tclsh not found after install"
	srv="$SCRIPT_DIR/rio-core/server.tcl"
	[ -f "$srv" ] || die "cannot find $srv (run this from inside the rio checkout)"
	log "verifying server runtime"
	RIO_SERVER_TCL="$srv" tclsh <<'EOF'
set fail 0
if {[catch {package require json} ver]} {
	puts "  json     MISSING ($ver)"
	incr fail
} else {
	puts "  json     ok $ver"
}
# Load the core exactly as server mode does, then bind an ephemeral loopback port.
if {[catch {
	source $env(RIO_SERVER_TCL)
	set port [rio::server::listen 0]
} err]} {
	puts "  core     FAILED to load/bind ($err)"
	incr fail
} else {
	puts "  core     ok (sourced server.tcl; bound 127.0.0.1:$port)"
}
puts "  tclsh    [info patchlevel]"
if {$fail} { puts stderr "verify: $fail check(s) failed" ; exit 1 }
exit 0
EOF
	if have git; then log "git present (git pane enabled)"
	else warn "git not installed — the git pane will be unavailable over the socket"; fi
	log "server runtime OK"
}

# --- main -------------------------------------------------------------------

pick_sudo
detect_pm

if [ "$VERIFY_ONLY" = 1 ]; then
	verify
	exit 0
fi

install_server
verify

log "done."
cat <<'EOF'

Run the core (binds 127.0.0.1 by default — keep it behind an SSH tunnel, D29):

    tclsh rio-core/server.tcl 7711

From your workstation, tunnel in and attach the GUI:

    ssh -L 7711:127.0.0.1:7711 <this-host>
    wish rio-gui/rio-gui.tcl --connect 127.0.0.1:7711 /path/on/server

Bind all interfaces only behind a firewall:   tclsh rio-core/server.tcl 7711 --any
EOF
