#!/bin/sh
# Re-cut rio's window/taskbar icon from source.png (AGENTS.md D117).
#
# NOT a build step: the PNGs this produces are committed, and rio never runs this at
# start-up or install time. It exists so swapping the artwork is one command --
# replace source.png, run this, look at the result, commit.
#
#   ./rio-gui/icons/make-icons.sh [path/to/new-source.png]
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
src=${1:-$dir/source.png}
[ -f "$src" ] || { echo "no such source: $src" >&2; exit 1; }
command -v convert >/dev/null || { echo "ImageMagick (convert) is not installed" >&2; exit 1; }

# Square the trimmed content: the longer side wins, so nothing is cropped.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
convert "$src" -trim +repage "$tmp/t.png"
w=$(identify -format %w "$tmp/t.png"); h=$(identify -format %h "$tmp/t.png")
side=$(( w > h ? w : h ))
convert "$tmp/t.png" -background none -gravity center -extent ${side}x${side} "$tmp/sq.png"

for n in 16 24 32 48 64 128 256; do
	convert "$tmp/sq.png" -filter Lanczos -resize ${n}x${n} -strip "$dir/rio-$n.png"
	echo "  rio-$n.png"
done
convert "$dir/rio-16.png" "$dir/rio-32.png" "$dir/rio-48.png" "$dir/rio-256.png" "$dir/rio.ico"
echo "  rio.ico (16/32/48/256, for Windows)"

[ "$src" = "$dir/source.png" ] || { cp "$src" "$dir/source.png"; echo "  source.png updated"; }
