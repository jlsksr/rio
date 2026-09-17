#!/bin/sh
# Re-cut rio's window/taskbar icon (AGENTS.md D117).
#
# NOT a build step: the PNGs this produces are committed, and rio never runs this at
# start-up or install time. It exists so trying a different icon -- or going back to
# one -- is a single command.
#
#   ./rio-gui/icons/make-icons.sh                  re-cut the ACTIVE artwork
#   ./rio-gui/icons/make-icons.sh redeemer-blue    switch to sources/redeemer-blue.png
#   ./rio-gui/icons/make-icons.sh ~/new-icon.png   adopt a new file (kept in sources/)
#   ./rio-gui/icons/make-icons.sh --list           show what is available, and which is on
#
# CANDIDATES ARE KEPT, not overwritten: every artwork rio has worn lives on under
# sources/, and `active` (one line, committed) records which one the cut PNGs came from.
# Switching back is therefore the same command with the other name, and the diff says
# plainly which icon a commit changed rio to.
#
# Needs ImageMagick (`convert`), a developer tool only. rio's own dependency bar is
# untouched: Tk 8.6 reads PNG natively, so the GUI needs nothing extra to show these.
#
# What it does, and why:
#   * TRIMS the source's transparent margin and re-pads it square. Artwork usually
#     ships with slack around it; at 16x16 that slack is whole pixels of the subject.
#   * Lanczos, and NO sharpening. Unsharp looks right at 48px and rings at 16 --
#     a dark halo along the strongest edge.
#   * Writes a Windows .ico too (16/32/48/256 in one file). `wm iconphoto` works on
#     Windows, but the taskbar and alt-tab look better given a real .ico.
set -e

dir=$(dirname "$0")
srcdir=$dir/sources
mkdir -p "$srcdir"

if [ "$1" = "--list" ]; then
	cur=$(cat "$dir/active" 2>/dev/null || echo "?")
	for f in "$srcdir"/*.png; do
		[ -f "$f" ] || continue
		n=$(basename "$f" .png)
		if [ "$n" = "$cur" ]; then echo "* $n   (active)"; else echo "  $n"; fi
	done
	exit 0
fi

arg=$1
if [ -z "$arg" ]; then
	name=$(cat "$dir/active" 2>/dev/null) || { echo "no active icon recorded; pass a name or a file" >&2; exit 1; }
	src=$srcdir/$name.png
elif [ -f "$srcdir/$arg.png" ]; then          # a name already in sources/
	name=$arg
	src=$srcdir/$name.png
elif [ -f "$arg" ]; then                       # a new file: adopt it under its own name
	name=$(basename "$arg" .png)
	src=$srcdir/$name.png
	[ "$arg" = "$src" ] || cp "$arg" "$src"
else
	echo "no such icon or file: $arg   (try --list)" >&2; exit 1
fi
command -v convert >/dev/null || { echo "ImageMagick (convert) is not installed" >&2; exit 1; }

# Square the trimmed content: the longer side wins, so nothing is cropped.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
convert "$src" -trim +repage "$tmp/t.png"
w=$(identify -format %w "$tmp/t.png"); h=$(identify -format %h "$tmp/t.png")
side=$(( w > h ? w : h ))
convert "$tmp/t.png" -background none -gravity center -extent ${side}x${side} "$tmp/sq.png"

echo "cutting from $name:"
for n in 16 24 32 48 64 128 256; do
	convert "$tmp/sq.png" -filter Lanczos -resize ${n}x${n} -strip "$dir/rio-$n.png"
	echo "  rio-$n.png"
done
convert "$dir/rio-16.png" "$dir/rio-32.png" "$dir/rio-48.png" "$dir/rio-256.png" "$dir/rio.ico"
echo "  rio.ico (16/32/48/256, for Windows)"
echo "$name" > "$dir/active"
echo "active icon is now: $name"
