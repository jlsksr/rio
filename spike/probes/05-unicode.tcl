# O1 probe #5 — Unicode rendering (AGENTS.md O1 criterion 5).
#
# cwsh is built with ncursesw + _XOPEN_SOURCE_EXTENDED, so BMP should render.
# This lays out progressively harder rows; capture the screen and catalogue what
# survives: Latin-1, box-drawing (used by rio's pane borders), arrows, CJK
# (wide/double-width), astral/emoji (likely lost), and combining marks. Record
# the findings in VERDICT.md — "BMP renders; note wide/combining" is the bar.

message .m -justify center -width 500 -text "CK-SPIKE-05  Unicode; q to quit"
pack .m -side top -fill x
text .t -wrap none
pack .t -fill both -expand yes

.t insert end "ascii  : the quick brown fox\n"
.t insert end "latin1 : àéîõü ñ ç ©®°\n"
.t insert end "box    : +-- ┌─┬─┐ │ ├─┼─┤ └─┴─┘\n"
.t insert end "arrows : <- ← ↑ → ↓ ↔ ⇨\n"
.t insert end "cjkwide: 日本語 中文 한국어\n"
.t insert end "astral : emoji 😀 rocket 🚀\n"
.t insert end "combine: é(e+acute) à ñ\n"
.t insert end "CK-SPIKE-05 END\n"

bind . <Key-q> {exit 0}
focus .t
