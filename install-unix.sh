#!/bin/sh
#
# install-unix.sh — install rio on Linux, the BSDs, and macOS.
#
# rio is a small IDE written in Tcl/Tk. There is nothing to compile: it runs from
# this checkout. So "installing" it is three things, and this script does all three.
#
#   1. INSTALL THE TOOLCHAIN rio runs on, through your system's package manager:
#        tclsh + Tk    the language and GUI toolkit rio is written in
#        tcltls        TLS sockets — HTTPS for an agent provider and for https
#                      extension repositories
#        tcllib        the json package the wire protocol parses with
#        git           the git pane shells out to it
#   2. VERIFY it by actually loading it. That, not a successful package install,
#      is the real answer — so this runs even when there was nothing to install.
#   3. INSTALL A LAUNCHER so you can run rio like any other application: a `rio`
#      command, and an entry with rio's icon in your desktop's application menu.
#      Both go under ~/.local, so nothing needs root and nothing leaves your
#      account. Skip this half with --no-launcher.
#
# Usage:
#   ./install-unix.sh [options]
#
# Options:
#   --no-launcher    install only the toolchain: no `rio` command, no menu entry
#   --launcher-only  the other half: skip the packages (you already have Tcl/Tk,
#                    or your system isn't one of the four below), verify, and
#                    install the launcher
#   --prefix DIR     where the launcher goes (default: $HOME/.local)
#   --uninstall      remove the launcher, the menu entry and the icons. Never
#                    touches your packages — other things on this machine need Tcl
#   --verify-only    check the toolchain loads; change nothing
#   --dry-run        print every step without doing any of it
#   --with-ck        also build Ck (curses Tk) from source. FOR CONTRIBUTORS: it is
#                    the deferred terminal-frontend path (AGENTS.md O1), not needed
#                    to run rio
#   -h, --help       this text
#
# Safe to re-run: every step is idempotent, and it finishes by verifying, which is
# the part that actually tells you whether rio will start.
#
# Supported: Debian/Ubuntu (apt), Alpine (apk), OpenBSD (pkg_add), macOS (Homebrew).
# macOS is UNVERIFIED — nobody has yet run it there; see the note in install_base.

set -eu

# --- options ----------------------------------------------------------------

WITH_CK=0
VERIFY_ONLY=0
DRY_RUN=0
NO_LAUNCHER=0
LAUNCHER_ONLY=0
UNINSTALL=0
PREFIX="${HOME:-}/.local"

# --- helpers ----------------------------------------------------------------

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//;s/^#//'
	exit "${1:-0}"
}

# A temp file, portably: OpenBSD's mktemp wants a template.
mktmp() { mktemp "${TMPDIR:-/tmp}/rio-install.XXXXXX"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--with-ck)     WITH_CK=1 ;;
		--verify-only) VERIFY_ONLY=1 ;;
		--dry-run)     DRY_RUN=1 ;;
		--no-launcher)   NO_LAUNCHER=1 ;;
		--launcher-only) LAUNCHER_ONLY=1 ;;
		--uninstall)     UNINSTALL=1 ;;
		--prefix)      shift; [ $# -gt 0 ] || die "--prefix needs a directory"
		               PREFIX=$1 ;;
		--prefix=*)    PREFIX=${1#--prefix=} ;;
		-h|--help)     usage 0 ;;
		*) echo "install-unix: unknown option: $1" >&2; usage 1 ;;
	esac
	shift
done

# This checkout — the launcher points into it, so rio keeps running from here.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RIO_GUI="$SCRIPT_DIR/rio-gui/rio-gui.tcl"
ICON_DIR="$SCRIPT_DIR/rio-gui/icons"

BINDIR="$PREFIX/bin"
APPDIR="$PREFIX/share/applications"
ICONROOT="$PREFIX/share/icons/hicolor"
ICON_SIZES="16 24 32 48 64 128 256"

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

# Like run(), but never privileged. Homebrew refuses to run under sudo, and the
# launcher half writes into the user's own ~/.local.
run_user() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] %s\n' "$*"
	else
		"$@"
	fi
}

# --- package manager detection ----------------------------------------------
#
# Per-manager package name lists. The verify step below is what actually
# decides success, so if a name is wrong on your distro, fix it here and the
# verifier will confirm.

detect_pm() {
	# Darwin first and explicitly: a Mac has none of the others, and reaching
	# "no supported package manager" there would be a worse answer than naming
	# the one thing it does need.
	# --launcher-only skips the package half entirely, so not recognising this
	# system is not an error there — it is the reason someone passes the flag.
	if [ "$(uname -s)" = "Darwin" ] && have brew; then
		PM=brew
	elif [ "$(uname -s)" = "Darwin" ] && [ "$LAUNCHER_ONLY" = 0 ]; then
		die "macOS needs Homebrew for this — install it from https://brew.sh and re-run, or install Tcl/Tk and tcllib by hand and use --launcher-only"
	elif have apt-get; then PM=apt
	elif have apk;     then PM=apk
	elif have pkg_add; then PM=pkg_add   # OpenBSD
	elif [ "$LAUNCHER_ONLY" = 1 ]; then PM=""
	else die "no supported package manager found (need apt-get, apk, pkg_add, or brew). If you have Tcl/Tk and tcllib already, use --launcher-only"
	fi
	if [ -n "${PM:-}" ]; then log "package manager: $PM"; fi
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
			# OpenBSD package stems; pkg_add resolves the 8.6 flavors. The TLS
			# extension is "tcltls" on OpenBSD (one word), unlike apt/apk's tcl-tls.
			run pkg_add -I tcl%8.6 tk%8.6 tcltls tcllib git
			;;
		brew)
			# macOS is UNVERIFIED: nobody has run rio there yet, so these formula
			# names are the best guess and the verify step below is the arbiter —
			# exactly how this script already treats an unfamiliar distro. Not run
			# through run(): Homebrew refuses to operate under sudo.
			warn "macOS is not verified yet — the verify step below is the real answer."
			warn "Please report what happens: https://github.com/jlsksr/rio/issues"
			run_user brew install tcl-tk
			# tcllib may not be a formula on every tap. A missing one must not abort
			# the run: verify reports `json MISSING` and the hint below says what to do.
			if [ "$DRY_RUN" = 1 ]; then
				printf '  [dry-run] brew install tcllib\n'
			elif ! brew install tcllib; then
				warn "no 'tcllib' formula here — if the json check below fails, install tcllib by hand: https://core.tcl-lang.org/tcllib"
			fi
			;;
	esac
}

# Homebrew's tcl-tk is keg-only, so its tclsh/wish are NOT on PATH — and the tclsh
# that IS on a Mac's PATH is Apple's deprecated 8.5, without Tk or tcllib. Put
# Homebrew's ahead of it, or we would verify the wrong interpreter.
brew_path() {
	if [ "${PM:-}" = brew ] && have brew; then
		p=$(brew --prefix tcl-tk 2>/dev/null || true)
		if [ -n "$p" ] && [ -d "$p/bin" ]; then
			PATH="$p/bin:$PATH"
			export PATH
		fi
	fi
}

# --- optional: build Ck (curses Tk) from source -----------------------------

CK_REPO="https://github.com/vzvca/ck8.6.git"
CK_SRC="${TMPDIR:-/tmp}/rio-ck-build"

install_ck_deps() {
	case "$PM" in
		apt)     run apt-get install -y build-essential tcl-dev libncurses-dev ;;
		apk)     run apk add --no-interactive build-base tcl-dev ncurses-dev ;;
		pkg_add) warn "OpenBSD: install C toolchain + ncurses headers yourself if missing" ;;
		brew)    warn "macOS: Ck is untried here; install ncurses yourself if the build complains" ;;
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

# --- the launcher: a `rio` command and a menu entry -------------------------
#
# What makes this feel installed rather than checked out. Everything here lands
# under $PREFIX (default ~/.local), so it needs no root and removes cleanly.

# Where the user's wish lives. Distributions version the binary name, and on macOS
# Homebrew's is keg-only and therefore off PATH entirely.
find_wish() {
	for c in wish wish8.6 wish8.7 wish9.0 wish86 wish90; do
		if have "$c"; then command -v "$c"; return 0; fi
	done
	if have brew; then
		p=$(brew --prefix tcl-tk 2>/dev/null || true)
		if [ -n "$p" ] && [ -x "$p/bin/wish" ]; then
			printf '%s\n' "$p/bin/wish"
			return 0
		fi
	fi
	return 1
}

# sudo only when $PREFIX is somewhere this account cannot write — so the default
# ~/.local never prompts, and --prefix /usr/local still works.
PSUDO=""
pick_prefix_sudo() {
	d=$PREFIX
	while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -d "$d" ]; do d=$(dirname "$d"); done
	if [ ! -w "$d" ]; then PSUDO="$SUDO"; fi
}

prun() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] %s\n' "$*"
	else
		# shellcheck disable=SC2086
		$PSUDO "$@"
	fi
}

# Write $2 (a here-doc'd file, already in a temp file) to $1, through prun so a
# privileged prefix works. Kept separate because you cannot pipe into sudo with
# the helpers above.
place() {
	prun mkdir -p "$(dirname "$1")"
	prun cp "$2" "$1"
	prun chmod "$3" "$1"
}

install_launcher() {
	pick_prefix_sudo

	wish=$(find_wish || true)
	if [ -z "$wish" ]; then
		warn "no wish found — skipping the launcher. The toolchain is installed; run rio with:"
		warn "    wish $RIO_GUI"
		return 0
	fi
	if [ ! -f "$RIO_GUI" ]; then
		warn "$RIO_GUI not found — skipping the launcher (is this a complete checkout?)"
		return 0
	fi

	# Note what `rio` means on this machine BEFORE we install ours: there is a
	# well-known terminal emulator by the same name, and silently shadowing it
	# would be rude.
	prior=$(command -v rio 2>/dev/null || true)

	# The wrapper. NOT a symlink, deliberately: rio finds its own modules relative
	# to [info script], and Tcl does not resolve symlinks — so a link here would
	# make rio look for its core next to the link and fail to start.
	tmp=$(mktmp) || die "cannot create a temporary file"
	cat > "$tmp" <<EOF
#!/bin/sh
# rio — generated by install-unix.sh. Re-run it to regenerate this file.
#
# A wrapper rather than a symlink: rio resolves its own modules relative to
# [info script], and Tcl does not resolve symlinks, so a link would send it
# looking for its core in the wrong directory.
exec "$wish" "$RIO_GUI" "\$@"
EOF
	place "$BINDIR/rio" "$tmp" 0755
	rm -f "$tmp"
	log "launcher: $BINDIR/rio  ->  $wish $RIO_GUI"

	# The icon, at every size we ship, into the standard hicolor theme so the
	# desktop picks whichever it needs. (The window's own icon is set by rio
	# itself; this one is for the menu and the taskbar's launcher.)
	icons=0
	for n in $ICON_SIZES; do
		if [ -f "$ICON_DIR/rio-$n.png" ]; then
			place "$ICONROOT/${n}x${n}/apps/rio.png" "$ICON_DIR/rio-$n.png" 0644
			icons=$((icons + 1))
		fi
	done
	if [ "$icons" -gt 0 ]; then log "icons: $icons sizes into $ICONROOT"; fi

	# The menu entry. %F, not %f: rio opens several files at once. StartupWMClass is
	# the running window's WM_CLASS — Tk derives it from the script's name, so it is
	# "rio-gui.tcl" rather than "wish" (measured with xprop, not assumed). Without it
	# the taskbar shows an open rio as a stray window instead of grouping it under
	# this launcher.
	tmp=$(mktmp) || die "cannot create a temporary file"
	cat > "$tmp" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=rio
GenericName=Text Editor
Comment=A small IDE with first-class git and AI-agent integration
Exec=$BINDIR/rio %F
TryExec=$BINDIR/rio
Icon=rio
Terminal=false
Categories=Development;TextEditor;
Keywords=editor;text;code;ide;
StartupWMClass=rio-gui.tcl
EOF
	place "$APPDIR/rio.desktop" "$tmp" 0644
	rm -f "$tmp"
	log "menu entry: $APPDIR/rio.desktop"

	refresh_caches

	# Two things that are nobody's fault but will look like rio's if unsaid.
	case ":${PATH}:" in
		*":$BINDIR:"*) ;;
		*) warn "$BINDIR is not on your PATH, so \`rio\` won't be found yet. Add this to your shell's rc file:"
		   warn "    export PATH=\"$BINDIR:\$PATH\"" ;;
	esac
	if [ -n "$prior" ] && [ "$prior" != "$BINDIR/rio" ]; then
		warn "there was already a \`rio\` at $prior (the terminal emulator, perhaps?) — whichever comes first on PATH wins"
	fi
}

# Best effort, and genuinely optional: a desktop that has no such tool reads the
# directories directly. Never fail the install over a cache.
refresh_caches() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] refresh desktop/icon caches (if the tools exist)\n'
		return 0
	fi
	have update-desktop-database && update-desktop-database "$APPDIR" >/dev/null 2>&1 || true
	have gtk-update-icon-cache   && gtk-update-icon-cache -f -t "$ICONROOT" >/dev/null 2>&1 || true
	return 0
}

uninstall_launcher() {
	pick_prefix_sudo
	log "removing the launcher under $PREFIX"
	prun rm -f "$BINDIR/rio"
	prun rm -f "$APPDIR/rio.desktop"
	for n in $ICON_SIZES; do
		prun rm -f "$ICONROOT/${n}x${n}/apps/rio.png"
	done
	refresh_caches
	log "done. Your packages are untouched — other things on this machine need Tcl."
	log "The checkout itself is still here: $SCRIPT_DIR"
}

# --- main -------------------------------------------------------------------

pick_sudo

if [ "$UNINSTALL" = 1 ]; then
	uninstall_launcher
	exit 0
fi

if [ "$NO_LAUNCHER" = 1 ] && [ "$LAUNCHER_ONLY" = 1 ]; then
	die "--no-launcher and --launcher-only ask for opposite halves; pick one"
fi

detect_pm
brew_path

if [ "$VERIFY_ONLY" = 1 ]; then
	verify
	exit 0
fi

if [ "$LAUNCHER_ONLY" = 0 ]; then
	install_base
	[ "$WITH_CK" = 1 ] && build_ck
fi
verify

if [ "$NO_LAUNCHER" = 0 ]; then
	install_launcher
fi

log "done."
if [ "$NO_LAUNCHER" = 0 ] && [ "$DRY_RUN" = 0 ] && [ -x "$BINDIR/rio" ]; then
	log "Start rio from your application menu, or:"
	printf '    rio [file-or-folder ...]\n'
else
	log "Start rio with:"
	printf '    wish %s [file-or-folder ...]\n' "$RIO_GUI"
fi
[ "$WITH_CK" = 1 ] || log "TUI/Ck skipped — re-run with --with-ck if you mean to work on the terminal frontend."
