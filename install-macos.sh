#!/bin/sh
#
# install-macos.sh — install rio on macOS, with root or without.
#
# rio is a small IDE written in Tcl/Tk. There is nothing to compile: it runs from
# this checkout. So "installing" it is three things, and this script does all three.
#
#   1. FIND OR INSTALL A TOOLCHAIN: Tcl/Tk 8.6 with the native (Aqua) Tk, tcllib,
#      and tcltls 1.8 or newer. It takes the first of these that works:
#        path      a suitable tclsh already on your PATH
#        brew      Homebrew's tcl-tk@8 (installed if the Homebrew is yours to write)
#        macports  MacPorts' tcl8 + tk8-quartz + tcllib + tcl8-tls (needs sudo)
#        source    built from pinned, checksummed sources into your home
#                  directory — no root, needs only the Xcode command-line tools
#      Apple's own /usr/bin/tclsh is Tcl 8.5 without Tk or tcllib, and Tcl 9 is
#      refused: rio has never run on it.
#   2. VERIFY it by actually loading it. That, not a successful install, is the
#      real answer — so this runs even when there was nothing to install.
#   3. INSTALL A LAUNCHER: a `rio` command, and a rio.app for the Dock, Finder and
#      Spotlight, with rio's own name in the menu bar. Per-user, nothing needs root.
#
# Usage:
#   ./install-macos.sh [options]
#
# Options:
#   --use SOURCE       take the toolchain from SOURCE only: auto (the default),
#                      path, brew, macports or source
#   --no-launcher      toolchain only: no `rio` command, no rio.app
#   --launcher-only    no installing: find an existing toolchain, verify it, and
#                      install the launcher
#   --prefix DIR       where the `rio` command goes, as DIR/bin/rio
#                      (default: $HOME/.local)
#   --app-dir DIR      where rio.app goes (default: $HOME/Applications)
#   --toolchain-dir DIR  where a source build, or a tcltls 1.8 top-up, goes
#                      (default: $HOME/.local/rio-env)
#   --with-openssl DIR   the OpenSSL tcltls builds against (default: Homebrew's
#                      openssl@3, else MacPorts' /opt/local)
#   --download-dir DIR   keep the source tarballs here and reuse them on the next
#                      run; each is checked against its pinned SHA-256 either way
#   --keep-build       keep the build directory (default: delete it)
#   --skip-tls-upgrade   don't build tcltls 1.8 when the toolchain's is older.
#                      Hosted agent providers and https repositories then refuse
#                      https until you allow it in Preferences > Network
#   --uninstall        remove what this script installed: the `rio` command,
#                      rio.app, the core's tclsh link and a tcltls top-up. Never
#                      packages or Homebrew
#   --toolchain        with --uninstall: also remove a toolchain it BUILT
#   --verify-only      find the toolchain and check it loads; change nothing
#   --dry-run          print every step without doing any of it
#   -h, --help         this text
#
# Safe to re-run: an existing toolchain is found and reused, a finished build is
# not repeated, and the launcher is rewritten to match whatever was chosen.
#
# Verified end to end on macOS 27 (arm64) without root, through the `source` path.
# The brew and macports paths follow those tools' own published package data but
# have not been run by us; the verify step is the arbiter either way.

set -eu

# --- options ----------------------------------------------------------------

USE=auto
VERIFY_ONLY=0
DRY_RUN=0
NO_LAUNCHER=0
LAUNCHER_ONLY=0
UNINSTALL=0
UNINSTALL_TOOLCHAIN=0
KEEP_BUILD=0
SKIP_TLS_UPGRADE=0
PREFIX="${HOME:-}/.local"
APP_DIR="${HOME:-}/Applications"
TOOLCHAIN="${HOME:-}/.local/rio-env"
OPENSSL_DIR=""
DOWNLOAD_DIR=""

# --- helpers ----------------------------------------------------------------

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#//'
	exit "${1:-0}"
}

needarg() { [ "$2" -gt 1 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--use)            needarg "$1" $#; shift; USE=$1 ;;
		--use=*)          USE=${1#--use=} ;;
		--no-launcher)    NO_LAUNCHER=1 ;;
		--launcher-only)  LAUNCHER_ONLY=1 ;;
		--prefix)         needarg "$1" $#; shift; PREFIX=$1 ;;
		--prefix=*)       PREFIX=${1#--prefix=} ;;
		--app-dir)        needarg "$1" $#; shift; APP_DIR=$1 ;;
		--app-dir=*)      APP_DIR=${1#--app-dir=} ;;
		--toolchain-dir)  needarg "$1" $#; shift; TOOLCHAIN=$1 ;;
		--toolchain-dir=*) TOOLCHAIN=${1#--toolchain-dir=} ;;
		--with-openssl)   needarg "$1" $#; shift; OPENSSL_DIR=$1 ;;
		--with-openssl=*) OPENSSL_DIR=${1#--with-openssl=} ;;
		--download-dir)   needarg "$1" $#; shift; DOWNLOAD_DIR=$1 ;;
		--download-dir=*) DOWNLOAD_DIR=${1#--download-dir=} ;;
		--keep-build)     KEEP_BUILD=1 ;;
		--skip-tls-upgrade) SKIP_TLS_UPGRADE=1 ;;
		--uninstall)      UNINSTALL=1 ;;
		--toolchain)      UNINSTALL_TOOLCHAIN=1 ;;
		--verify-only)    VERIFY_ONLY=1 ;;
		--dry-run)        DRY_RUN=1 ;;
		-h|--help)        usage 0 ;;
		*) echo "install-macos: unknown option: $1" >&2; usage 1 ;;
	esac
	shift
done

case "$USE" in
	auto|path|brew|macports|source) ;;
	*) die "--use takes auto, path, brew, macports or source (not '$USE')" ;;
esac
if [ "$NO_LAUNCHER" = 1 ] && [ "$LAUNCHER_ONLY" = 1 ]; then
	die "--no-launcher and --launcher-only ask for opposite halves; pick one"
fi
if [ "$UNINSTALL_TOOLCHAIN" = 1 ] && [ "$UNINSTALL" = 0 ]; then
	die "--toolchain only means something with --uninstall"
fi
[ "$(uname -s)" = Darwin ] || die "this is the macOS installer — on Linux or a BSD, use ./install-unix.sh"

# This checkout — the launcher points into it, so rio keeps running from here.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RIO_GUI="$SCRIPT_DIR/rio-gui/rio-gui.tcl"
ICNS="$SCRIPT_DIR/rio-gui/icons/rio.icns"

BINDIR="$PREFIX/bin"
APP="$APP_DIR/rio.app"
MANIFEST="$PREFIX/share/rio/installed"
MARKER="$TOOLCHAIN/.rio-toolchain"     # present only in a toolchain this script built
SHIM="$TOOLCHAIN/shim"                 # holds the `tclsh` rio starts its core with
BUNDLE_ID="org.skylm.rio"

# Every action that changes the machine goes through one of these, so --dry-run
# is honest by construction.
run() {
	if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi
}
run_sudo() {
	if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] sudo %s\n' "$*"; else sudo "$@"; fi
}

# Quote a string for a POSIX shell script we generate: 'it'\''s'.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# y/N, and N whenever nobody is there to answer.
confirm() {
	[ -t 0 ] || return 1
	printf '%s [y/N] ' "$1"
	read -r ans || return 1
	case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

mktmp()  { mktemp "${TMPDIR:-/tmp}/rio-install.XXXXXX"; }
mktmpd() { mktemp -d "${TMPDIR:-/tmp}/rio-install.XXXXXX"; }

# --- the probe --------------------------------------------------------------
#
# The real test of a toolchain: does it load? One tclsh run reports every piece.
# Its stdin is an EMPTY PIPE, never /dev/null: Tk on macOS treats a non-tty
# character device on stdin as "launched from Finder" and sends stdout to
# /dev/null, and this probe loads Tk — so /dev/null would swallow the answer.
#
# Sets P_TCL, P_TK (aqua|x11|MISSING), P_JSON, P_TLS ("" = none). Extra library
# directories (a tcltls top-up) come in through $1 as TCLLIBPATH.

probe() {
	tclsh=$1 extra=${2:-}
	P_TCL="" P_TK="MISSING" P_JSON="" P_TLS=""
	[ -x "$tclsh" ] || return 1
	script=$(mktmp) || die "cannot create a temporary file"
	cat > "$script" <<'EOF'
puts "tcl [info patchlevel]"
if {[catch {package require Tk}]} {
	puts "tk MISSING"
} else {
	wm withdraw .
	puts "tk [tk windowingsystem]"
}
puts "json [expr {[catch {package require json} v] ? "" : $v}]"
puts "tls [expr {[catch {package require tls} v] ? "" : $v}]"
exit 0
EOF
	out=$(: | TCLLIBPATH="$extra${TCLLIBPATH:+ $TCLLIBPATH}" "$tclsh" "$script" 2>/dev/null) || true
	rm -f "$script"
	P_TCL=$(printf '%s\n' "$out"  | sed -n 's/^tcl //p')
	P_TK=$(printf '%s\n' "$out"   | sed -n 's/^tk //p')
	P_JSON=$(printf '%s\n' "$out" | sed -n 's/^json //p')
	P_TLS=$(printf '%s\n' "$out"  | sed -n 's/^tls //p')
	[ -n "$P_TCL" ]
}

# Why a probed toolchain can't carry rio, in a sentence — or nothing if it can.
unsuitable() {
	case "$P_TCL" in
		8.6.*) ;;
		9.*)   echo "Tcl $P_TCL — rio targets 8.6 and has never run on Tcl 9"; return ;;
		"")    echo "does not run"; return ;;
		*)     echo "Tcl $P_TCL — rio needs 8.6"; return ;;
	esac
	case "$P_TK" in
		aqua) ;;
		x11)  echo "its Tk draws through X11, not natively (Aqua)"; return ;;
		*)    echo "has no Tk"; return ;;
	esac
	[ -n "$P_JSON" ] || { echo "has no tcllib (the json package)"; return; }
}

# 1 if a tcltls version checks certificate names (1.8+, D109).
tls_ok() {
	[ -n "$1" ] || return 1
	major=${1%%.*} rest=${1#*.}; minor=${rest%%.*}
	[ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 8 ]; }
}

# A tcltls top-up from an earlier run lives in the toolchain dir; the probe
# should see it, or it would build it again.
topup_lib() {
	for d in "$TOOLCHAIN"/lib/tls1.8*; do
		[ -f "$d/pkgIndex.tcl" ] && { printf '%s\n' "$TOOLCHAIN/lib"; return; }
	done
}

# Accept a candidate: probe, judge, and on success record it in T_*.
T_KIND="" T_TCLSH="" T_WISH="" T_EXTRA=""
consider() {
	kind=$1 tclsh=$2 wish=$3
	extra=""
	[ "$(dirname "$tclsh")" = "$TOOLCHAIN/bin" ] || extra=$(topup_lib)
	if ! probe "$tclsh" "$extra"; then
		log "  $kind: $tclsh does not run"; return 1
	fi
	why=$(unsuitable)
	if [ -n "$why" ]; then log "  $kind: $tclsh — $why"; return 1; fi
	if [ ! -x "$wish" ]; then log "  $kind: no wish beside $tclsh"; return 1; fi
	T_KIND=$kind T_TCLSH=$tclsh T_WISH=$wish T_EXTRA=$extra
	log "  $kind: $tclsh — Tcl $P_TCL, Tk aqua, json $P_JSON, tcltls ${P_TLS:-none}"
}

# --- toolchain sources, each "find it" and, if allowed, "install it" ----------

find_path() {
	for n in tclsh8.6 tclsh; do
		t=$(command -v "$n" 2>/dev/null) || continue
		d=$(dirname "$t")
		for w in "$d/wish8.6" "$d/wish"; do
			[ -x "$w" ] && { consider path "$t" "$w" && return 0; break; }
		done
	done
	log "  path: nothing suitable on PATH"
	return 1
}

brew_keg() { brew --prefix tcl-tk@8 2>/dev/null; }

find_brew() {
	have brew || { log "  brew: Homebrew is not installed"; return 1; }
	k=$(brew_keg) || k=""
	if [ -n "$k" ] && [ -x "$k/bin/tclsh8.6" ]; then
		consider brew "$k/bin/tclsh8.6" "$k/bin/wish8.6" && return 0
	fi
	[ "$1" = install ] || { log "  brew: tcl-tk@8 is not installed"; return 1; }
	# Homebrew refuses sudo, so "not writable" means "not ours" — skip, don't escalate.
	if [ ! -w "$(brew --prefix)/Cellar" ]; then
		log "  brew: Homebrew is installed but not writable by you — skipped"
		return 1
	fi
	# tcl-tk@8, NEVER plain tcl-tk: that is Tcl 9 now. The formula bundles tcllib
	# and tcltls (1.7.22 — topped up to 1.8 below).
	log "  brew: installing tcl-tk@8"
	run brew install tcl-tk@8 || { warn "brew install tcl-tk@8 failed"; return 1; }
	if [ "$DRY_RUN" = 1 ]; then
		T_KIND=brew T_TCLSH="<brew>/bin/tclsh8.6" T_WISH="<brew>/bin/wish8.6"; return 0
	fi
	k=$(brew_keg)
	consider brew "$k/bin/tclsh8.6" "$k/bin/wish8.6"
}

PORT=""
find_macports() {
	if have port; then PORT=$(command -v port)
	elif [ -x /opt/local/bin/port ]; then PORT=/opt/local/bin/port
	else log "  macports: MacPorts is not installed"; return 1
	fi
	mp=$(dirname "$PORT")
	if [ -x "$mp/tclsh8.6" ]; then
		consider macports "$mp/tclsh8.6" "$mp/wish8.6" && return 0
	fi
	[ "$1" = install ] || { log "  macports: tcl8 is not installed"; return 1; }
	# Pinned to the 8.x subports: the plain tcl/tk ports are metaports that could
	# move to 9, as Homebrew's did. tk8-quartz is the native Tk; tcl8-tls is 2.x,
	# which already checks certificate names.
	pkgs="tcl8 tk8-quartz tcllib tcl8-tls"
	if [ "$DRY_RUN" = 0 ] && ! confirm "Install $pkgs with MacPorts (sudo)?"; then
		log "  macports: not confirmed — skipped"; return 1
	fi
	# shellcheck disable=SC2086
	run_sudo "$PORT" -N install $pkgs || { warn "port install failed"; return 1; }
	if [ "$DRY_RUN" = 1 ]; then
		T_KIND=macports T_TCLSH="$mp/tclsh8.6" T_WISH="$mp/wish8.6"; return 0
	fi
	consider macports "$mp/tclsh8.6" "$mp/wish8.6"
}

find_source() {
	if [ -x "$TOOLCHAIN/bin/tclsh8.6" ]; then
		consider source "$TOOLCHAIN/bin/tclsh8.6" "$TOOLCHAIN/bin/wish8.6" && return 0
	fi
	[ "$1" = install ] || { log "  source: nothing built in $TOOLCHAIN"; return 1; }
	build_toolchain || return 1
	if [ "$DRY_RUN" = 1 ]; then
		T_KIND=source T_TCLSH="$TOOLCHAIN/bin/tclsh8.6" T_WISH="$TOOLCHAIN/bin/wish8.6"; return 0
	fi
	consider source "$TOOLCHAIN/bin/tclsh8.6" "$TOOLCHAIN/bin/wish8.6"
}

# $1 = find | install. Walks the sources in order and stops at the first that works.
choose_toolchain() {
	log "looking for a toolchain (--use $USE)"
	for s in path brew macports source; do
		[ "$USE" = auto ] || [ "$USE" = "$s" ] || continue
		"find_$s" "$1" && return 0
	done
	return 1
}

# --- building from source -----------------------------------------------------
#
# Every download is pinned by version AND SHA-256, and checked before it is
# unpacked. The Tcl and Tk hashes are the ones Homebrew's tcl-tk@8 pins for the
# same files; tcltls is fetched by fossil CHECK-IN, not by tag, because a tag can
# move — and the tarball for a check-in is byte-stable (checked twice, and against
# the build of 2026-09-29).

TCL_V=8.6.18
TCL_SHA=14f9af32b1767ff718477a8f974ad03c34341097e6b43f4ce54644ee974e268e
TK_SHA=95cd528a80f5e4bdb557af9b14a7197d6860793a3894e25e7c9fad2ed05d4c3c
TCLLIB_V=2.0
TCLLIB_SHA=590263de0832ac801255501d003441a85fb180b8ba96265d50c4a9f92fde2534
TLS_CHECKIN=ca1a846290939404a5ed4c440fd512da3ba731874cfb356a471fc33d423fc47f   # tag tls-1-8
TLS_SHA=255b89358c5e8efff013667e02bd424870037b5b2e3a4bb9826ef3bbea26f680

SF=https://downloads.sourceforge.net/project/tcl/Tcl/$TCL_V

BUILD=""
cleanup() {
	if [ -n "$BUILD" ] && [ -d "$BUILD" ]; then
		if [ "$KEEP_BUILD" = 1 ]; then log "build directory kept: $BUILD"
		else rm -rf "$BUILD"; fi
	fi
}
trap cleanup EXIT

need_build_tools() {
	if ! xcode-select -p >/dev/null 2>&1; then
		warn "building needs Apple's command-line developer tools. Install them with"
		warn "    xcode-select --install"
		warn "and re-run this script."
		return 1
	fi
	have curl || { warn "building needs curl"; return 1; }
}

# fetch URL FILE SHA — into the download dir, verified. A file already there is
# checked too, and a bad one refused rather than trusted.
fetch() {
	url=$1 file=$2 sha=$3
	dir=${DOWNLOAD_DIR:-$BUILD}
	dest="$dir/$file"
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] fetch %s, check SHA-256 %s\n' "$url" "$sha"; return 0
	fi
	mkdir -p "$dir"
	if [ -f "$dest" ]; then
		log "  $file: reusing $dest"
	else
		log "  $file: downloading"
		curl -fL --retry 2 -sS -o "$dest.part" "$url" || { rm -f "$dest.part"; warn "download failed: $url"; return 1; }
		mv "$dest.part" "$dest"
	fi
	got=$(shasum -a 256 "$dest" | cut -d' ' -f1)
	if [ "$got" != "$sha" ]; then
		warn "$file does not match its pinned checksum — refusing it"
		warn "    expected $sha"
		warn "    got      $got"
		warn "It has been deleted; re-run to download it again."
		rm -f "$dest"
		return 1
	fi
	tar -xzf "$dest" -C "$BUILD"
}

# step NAME LOG CMD... — run a build step in a subshell, keep its output in a log,
# and show the log's tail when it fails.
step() {
	name=$1 logf=$2; shift 2
	if [ "$DRY_RUN" = 1 ]; then printf '  [dry-run] %s: %s\n' "$name" "$*"; return 0; fi
	log "  $name"
	if ! "$@" > "$logf" 2>&1; then
		warn "$name failed; the end of $logf:"
		tail -20 "$logf" >&2
		KEEP_BUILD=1
		return 1
	fi
}

# The OpenSSL tcltls links against. The system has LibreSSL but ships no headers.
find_openssl() {
	if [ -n "$OPENSSL_DIR" ]; then
		[ -f "$OPENSSL_DIR/include/openssl/ssl.h" ] || die "--with-openssl $OPENSSL_DIR has no include/openssl/ssl.h"
		printf '%s\n' "$OPENSSL_DIR"; return 0
	fi
	for d in "$(brew --prefix openssl@3 2>/dev/null || true)" /opt/homebrew/opt/openssl@3 \
	         /usr/local/opt/openssl@3 /opt/local; do
		[ -n "$d" ] && [ -f "$d/include/openssl/ssl.h" ] && { printf '%s\n' "$d"; return 0; }
	done
	return 1
}

ncpu() { sysctl -n hw.ncpu 2>/dev/null || echo 2; }

# build_tls TCLCONFIG_DIR — tcltls 1.8 into $TOOLCHAIN. --exec-prefix matters:
# TEA otherwise defaults it to TCL_EXEC_PREFIX, which for a Homebrew Tcl would
# install INTO the keg.
build_tls() {
	ssl=$(find_openssl) || {
		warn "no OpenSSL with headers found, so tcltls is not built. rio still runs,"
		warn "but a hosted agent provider and https repositories will refuse https."
		warn "Point this script at one with --with-openssl DIR (Homebrew: openssl@3)."
		return 1
	}
	fetch "https://core.tcl-lang.org/tcltls/tarball/$TLS_CHECKIN/tcltls.tar.gz" \
		"tcltls-$TLS_CHECKIN.tar.gz" "$TLS_SHA" || return 1
	step "tcltls 1.8 (OpenSSL: $ssl)" "$BUILD/tls.log" sh -c "cd '$BUILD/tcltls' &&
		./configure --prefix='$TOOLCHAIN' --exec-prefix='$TOOLCHAIN' --with-tcl='$1' \
			--with-openssl-dir='$ssl' && make -j$(ncpu) && make install"
}

build_toolchain() {
	need_build_tools || return 1
	log "  source: building Tcl/Tk $TCL_V, tcllib $TCLLIB_V and tcltls 1.8 into $TOOLCHAIN"
	log "  (a few minutes; nothing outside that directory is touched)"
	[ "$DRY_RUN" = 1 ] || BUILD=$(mktmpd) || die "cannot create a build directory"
	fetch "$SF/tcl$TCL_V-src.tar.gz" "tcl$TCL_V-src.tar.gz" "$TCL_SHA" || return 1
	fetch "$SF/tk$TCL_V-src.tar.gz"  "tk$TCL_V-src.tar.gz"  "$TK_SHA"  || return 1
	fetch "https://core.tcl-lang.org/tcllib/uv/tcllib-$TCLLIB_V.tar.gz" \
		"tcllib-$TCLLIB_V.tar.gz" "$TCLLIB_SHA" || return 1
	T=$TOOLCHAIN j=$(ncpu)
	step "Tcl $TCL_V" "$BUILD/tcl.log" sh -c "cd '$BUILD/tcl$TCL_V/unix' &&
		./configure --prefix='$T' --enable-threads --enable-64bit && make -j$j && make install" || return 1
	step "Tk $TCL_V (Aqua)" "$BUILD/tk.log" sh -c "cd '$BUILD/tk$TCL_V/unix' &&
		./configure --prefix='$T' --with-tcl='$T/lib' --enable-aqua && make -j$j && make install" || return 1
	step "tcllib $TCLLIB_V" "$BUILD/tcllib.log" sh -c "cd '$BUILD/tcllib-$TCLLIB_V' &&
		./configure --prefix='$T' --with-tclsh='$T/bin/tclsh8.6' && make install-libraries" || return 1
	build_tls "$T/lib" || true
	run ln -sf tclsh8.6 "$T/bin/tclsh"
	run ln -sf wish8.6 "$T/bin/wish"
	# The marker is what makes --uninstall --toolchain safe: it only ever deletes a
	# directory that says this script built it.
	if [ "$DRY_RUN" = 0 ]; then
		printf 'built by rio install-macos.sh on %s\ntcl %s\ntcllib %s\ntcltls %s\n' \
			"$(date +%Y-%m-%d)" "$TCL_V" "$TCLLIB_V" "$TLS_CHECKIN" > "$MARKER"
		manifest_add toolchain "$TOOLCHAIN"
	fi
}

# tcltls older than 1.8 checks a certificate's chain but not its name, so rio
# refuses https through it (D109/D110/D114). Top it up beside the toolchain —
# into our own directory, never into Homebrew's keg or MacPorts' tree.
tls_upgrade() {
	tls_ok "$P_TLS" && return 0
	[ "$T_KIND" = source ] && [ -z "$P_TLS" ] && return 0   # build_toolchain already said why
	if [ "$SKIP_TLS_UPGRADE" = 1 ]; then
		warn "tcltls is ${P_TLS:-missing}; --skip-tls-upgrade, so https stays refused until"
		warn "you allow it in rio's Preferences > Network."
		return 0
	fi
	log "tcltls is ${P_TLS:-missing} — building 1.8 into $TOOLCHAIN/lib (skip with --skip-tls-upgrade)"
	need_build_tools || { warn "so tcltls stays at ${P_TLS:-missing}"; return 0; }
	[ "$DRY_RUN" = 1 ] || BUILD=${BUILD:-$(mktmpd)} || die "cannot create a build directory"
	build_tls "$(dirname "$T_TCLSH")/../lib" || return 0
	[ "$DRY_RUN" = 1 ] && return 0
	manifest_add tls "$TOOLCHAIN/lib/tls1.8.0"
	consider "$T_KIND" "$T_TCLSH" "$T_WISH" || die "the toolchain stopped loading after the tcltls build"
}

# --- the manifest: what --uninstall may remove ------------------------------

manifest_add() {
	[ "$DRY_RUN" = 1 ] && return 0
	mkdir -p "$(dirname "$MANIFEST")"
	touch "$MANIFEST"
	grep -qxF "$1 $2" "$MANIFEST" || printf '%s %s\n' "$1" "$2" >> "$MANIFEST"
}

# --- the launcher ---------------------------------------------------------------

rio_version() { sed -n 's/^[[:space:]]*variable version \([0-9][^[:space:]]*\).*/\1/p' "$SCRIPT_DIR/rio-core/version.tcl"; }

# The `tclsh` rio's core runs on. rio starts its core with the first `tclsh` on
# PATH — that exact name, not tclsh8.6 — and a Mac's default one is Apple's 8.5,
# which cannot run it. Only a source build is sure to have a `tclsh` beside its
# tclsh8.6; Homebrew's or MacPorts' may carry tclsh8.6 alone, and then the lookup
# would fall straight through to Apple's. So both launchers put this directory
# first on PATH, and the one thing in it is a `tclsh` that IS the chosen one.
# Always made, whichever toolchain was chosen, so the path that is verified is the
# path every install takes.
write_shim() {
	run mkdir -p "$SHIM"
	run ln -sf "$T_TCLSH" "$SHIM/tclsh"
	manifest_add shim "$SHIM"
	[ "$DRY_RUN" = 1 ] && return 0
	# The core needs json from the first line; ask the link for it, as the core will.
	got=$(printf 'package require json\nputs [info patchlevel]\n' |
		TCLLIBPATH="$T_EXTRA${TCLLIBPATH:+ $TCLLIBPATH}" "$SHIM/tclsh" 2>/dev/null) || got=""
	[ "$got" = "$P_TCL" ] ||
		die "$SHIM/tclsh does not run the chosen Tcl with tcllib (expected $P_TCL, got '${got:-nothing}')"
}

# The `rio` command. A wrapper, not a symlink: rio finds its modules relative to
# [info script], and Tcl does not resolve symlinks. It puts $SHIM first on PATH,
# so the core starts on the chosen tclsh (write_shim says why).
write_wrapper() {
	tmp=$(mktmp) || die "cannot create a temporary file"
	{
		echo '#!/bin/sh'
		echo '# rio — generated by install-macos.sh. Re-run it to regenerate this file.'
		echo "PATH=$(shq "$SHIM"):\$PATH; export PATH"
		if [ -n "$T_EXTRA" ]; then
			echo "TCLLIBPATH=$(shq "$T_EXTRA")\${TCLLIBPATH:+ \$TCLLIBPATH}; export TCLLIBPATH"
		fi
		cat <<'EOF'
# Tk on macOS sends stdout and stderr to /dev/null when stdin is a non-tty
# character device (it takes that for a Finder launch), which would swallow
# `rio --version` run from a script. An empty pipe is not one.
if [ ! -t 0 ]; then
EOF
		echo "	: | $(shq "$T_WISH") $(shq "$RIO_GUI") \"\$@\"; exit \$?"
		echo 'fi'
		echo "exec $(shq "$T_WISH") $(shq "$RIO_GUI") \"\$@\""
	} > "$tmp"
	run mkdir -p "$BINDIR"
	run cp "$tmp" "$BINDIR/rio"
	run chmod 0755 "$BINDIR/rio"
	rm -f "$tmp"
	manifest_add file "$BINDIR/rio"
	log "command: $BINDIR/rio"
}

# rio.app. Its executable is a COPY of wish, not a script that runs wish and not
# a symlink: macOS takes an app's identity — the name in the menu bar, "Quit rio"
# — from the bundle its executable sits in, and both of those resolve to wish's
# own directory (measured with ::tk::mac::GetAppPath). A wish inside rio.app then
# finds Resources/Scripts/AppMain.tcl by itself, which starts rio.
write_app() {
	[ -f "$ICNS" ] || warn "$ICNS is missing — rio.app will have Tk's icon until rio sets its own"
	ver=$(rio_version)
	minos=$(otool -l "$T_WISH" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] build %s (a copy of %s, Info.plist, rio.icns, AppMain.tcl)\n' "$APP" "$T_WISH"
		return 0
	fi
	stage=$(mktmpd) || die "cannot create a temporary directory"
	c="$stage/rio.app/Contents"
	mkdir -p "$c/MacOS" "$c/Resources/Scripts"
	cp "$T_WISH" "$c/MacOS/rio"
	[ -f "$ICNS" ] && cp "$ICNS" "$c/Resources/rio.icns"
	cat > "$c/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>               <string>rio</string>
	<key>CFBundleDisplayName</key>        <string>rio</string>
	<key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>         <string>rio</string>
	<key>CFBundleIconFile</key>           <string>rio</string>
	<key>CFBundlePackageType</key>        <string>APPL</string>
	<key>CFBundleShortVersionString</key> <string>$ver</string>
	<key>CFBundleVersion</key>            <string>$ver</string>
	<key>NSHighResolutionCapable</key>    <true/>${minos:+
	<key>LSMinimumSystemVersion</key>     <string>$minos</string>}
</dict>
</plist>
EOF
	# AppMain.tcl is written BY tclsh, so every path in it is quoted by Tcl's own
	# [list] — a checkout under "My Projects" or a name with braces stays one word.
	gen=$(mktmp) || die "cannot create a temporary file"
	cat > "$gen" <<'EOF'
lassign $argv out bindir extra gui
set f [open $out w]
puts $f "# rio.app's start-up script -- generated by install-macos.sh; re-run it to regenerate."
puts $f "# Launched from Finder or the Dock, PATH is launchd's minimal one, where tclsh is"
puts $f "# Apple's 8.5: put the chosen tclsh first so rio spawns its core with the right one."
puts $f "set env(PATH) \[join \[list [list $bindir] \$env(PATH)\] :\]"
if {$extra ne ""} {
	puts $f "# tcltls 1.8, built beside a toolchain whose own is older; the core inherits this."
	puts $f "set env(TCLLIBPATH) [list $extra]"
}
puts $f "# Finder passes a -psn_ argument on some macOS versions; it is not a file."
puts $f "set argv \[lsearch -all -inline -not -glob \$argv -psn_*\]"
puts $f "set argc \[llength \$argv\]"
puts $f "source [list $gui]"
close $f
EOF
	"$T_TCLSH" "$gen" "$c/Resources/Scripts/AppMain.tcl" \
		"$SHIM" "$T_EXTRA" "$RIO_GUI" || die "could not write AppMain.tcl"
	rm -f "$gen"
	# The copied wish keeps its own ad-hoc signature, which no longer holds once it
	# sits in a bundle ("code has no resources but signature indicates they must be
	# present"). Sign the whole bundle ad hoc — no certificate, nothing notarised;
	# it only makes the signature describe what is actually there.
	if have codesign; then
		codesign --force --sign - "$stage/rio.app" >/dev/null 2>&1 ||
			warn "could not ad-hoc sign rio.app; it will most likely still launch"
	fi
	if [ -e "$APP" ] && ! ours_app "$APP"; then
		rm -rf "$stage"
		die "$APP exists and is not one this script made — move it away and re-run"
	fi
	rm -rf "$APP"
	mkdir -p "$APP_DIR"
	mv "$stage/rio.app" "$APP"
	rm -rf "$stage"
	# Tell LaunchServices now, so Spotlight and the Dock know it before a reboot.
	lsr=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
	[ -x "$lsr" ] && "$lsr" -f "$APP" >/dev/null 2>&1 || true
	manifest_add app "$APP"
	log "app: $APP (rio $ver)"
}

install_launcher() {
	[ -f "$RIO_GUI" ] || die "$RIO_GUI not found — is this a complete checkout?"
	# Both targets first, so a refusal never leaves half an install behind. There is
	# a terminal emulator called rio; its binary is not ours to overwrite.
	if [ -e "$BINDIR/rio" ] && ! ours_wrapper "$BINDIR/rio"; then
		die "$BINDIR/rio exists and is not one this script made — move it away, or use --prefix"
	fi
	if [ -e "$APP" ] && ! ours_app "$APP"; then
		die "$APP exists and is not one this script made — move it away, or use --app-dir"
	fi
	prior=$(command -v rio 2>/dev/null || true)
	write_shim
	write_wrapper
	write_app
	case ":$PATH:" in
		*":$BINDIR:"*) ;;
		*) warn "$BINDIR is not on your PATH, so \`rio\` won't be found yet. Add to ~/.zshrc:"
		   warn "    export PATH=\"$BINDIR:\$PATH\"" ;;
	esac
	if [ -n "$prior" ] && [ "$prior" != "$BINDIR/rio" ]; then
		warn "there was already a \`rio\` at $prior (the terminal emulator, perhaps?) — whichever comes first on PATH wins"
	fi
}

# --- uninstall ----------------------------------------------------------------
#
# Removes only what the manifest names, and each thing only if it still looks like
# ours — a `rio` command we generated, a rio.app with our bundle id.

gone() { [ "$DRY_RUN" = 1 ] || log "$*"; }   # run() already printed the dry-run line
ours_wrapper() { grep -q 'generated by install-macos.sh' "$1" 2>/dev/null; }
ours_app() { grep -q "<string>$BUNDLE_ID</string>" "$1/Contents/Info.plist" 2>/dev/null; }

uninstall() {
	[ -f "$MANIFEST" ] || {
		log "no manifest at $MANIFEST — looking in the default places instead"
		printf 'file %s\napp %s\n' "$BINDIR/rio" "$APP" > "${TMPDIR:-/tmp}/rio-manifest.$$"
		MANIFEST_READ="${TMPDIR:-/tmp}/rio-manifest.$$"
	}
	src=${MANIFEST_READ:-$MANIFEST}
	while read -r kind path; do
		case "$kind" in
			file)
				if [ -e "$path" ] && ours_wrapper "$path"; then run rm -f "$path"; gone "removed $path"
				elif [ -e "$path" ]; then warn "$path is not ours — left alone"; fi ;;
			app)
				if [ -d "$path" ] && ours_app "$path"; then run rm -rf "$path"; gone "removed $path"
				elif [ -e "$path" ]; then warn "$path is not ours — left alone"; fi ;;
			tls)
				if [ -d "$path" ]; then run rm -rf "$path"; gone "removed the tcltls top-up $path"; fi ;;
			shim)
				# Only ever a link we made; a real file of that name is left alone.
				if [ -L "$path/tclsh" ]; then run rm -f "$path/tclsh"; gone "removed $path/tclsh"; fi
				if [ -d "$path" ]; then run rmdir "$path" 2>/dev/null || true; fi
				# The toolchain dir too, if the link was all it held (a Homebrew or
				# MacPorts install); rmdir leaves a built toolchain alone.
				if [ -d "$(dirname "$path")" ]; then run rmdir "$(dirname "$path")" 2>/dev/null || true; fi ;;
			toolchain)
				if [ "$UNINSTALL_TOOLCHAIN" = 0 ]; then
					log "kept the toolchain in $path (remove it too with --uninstall --toolchain)"
				elif [ -f "$path/.rio-toolchain" ]; then
					run rm -rf "$path"; gone "removed the toolchain $path"
				else warn "$path has no .rio-toolchain marker — left alone"; fi ;;
		esac
	done < "$src"
	# A kept toolchain stays in the manifest, so a later --uninstall --toolchain finds it.
	kept=$(grep '^toolchain ' "$src" 2>/dev/null || true)
	[ -n "${MANIFEST_READ:-}" ] && rm -f "$MANIFEST_READ"
	if [ "$UNINSTALL_TOOLCHAIN" = 0 ] && [ -n "$kept" ]; then
		[ "$DRY_RUN" = 1 ] || printf '%s\n' "$kept" > "$MANIFEST"
	else
		run rm -f "$MANIFEST"
		run rmdir "$(dirname "$MANIFEST")" 2>/dev/null || true
	fi
	log "done. Homebrew and MacPorts packages are never touched."
	log "The checkout itself is still here: $SCRIPT_DIR"
}

# --- main -----------------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
	uninstall
	exit 0
fi

if [ "$VERIFY_ONLY" = 1 ] || [ "$LAUNCHER_ONLY" = 1 ]; then
	choose_toolchain find || die "no suitable toolchain found — run ./install-macos.sh without --verify-only/--launcher-only to install one"
else
	choose_toolchain install || die "no toolchain could be found or installed — see the lines above for why each source was passed over"
	tls_upgrade
fi

if [ "$DRY_RUN" = 0 ]; then
	log "toolchain: $T_KIND — Tcl $P_TCL (Aqua), json $P_JSON, tcltls ${P_TLS:-none}"
	if ! tls_ok "$P_TLS"; then
		warn "tcltls ${P_TLS:-is missing}: a hosted agent provider and https repositories will"
		warn "refuse https. Plain http repositories and local providers work."
	fi
	have git || warn "git is not installed, so the git pane will be empty (xcode-select --install provides it)"
fi
[ "$VERIFY_ONLY" = 1 ] && exit 0

if [ "$NO_LAUNCHER" = 0 ]; then
	install_launcher
fi

log "done."
if [ "$NO_LAUNCHER" = 0 ] && [ "$DRY_RUN" = 0 ]; then
	log "Start rio from Spotlight, the Dock or Finder ($APP), or:"
	printf '    rio [file-or-folder ...]\n'
else
	log "Start rio with:"
	printf '    %s %s [file-or-folder ...]\n' "${T_WISH:-wish}" "$RIO_GUI"
fi
