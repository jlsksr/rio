# O1 probe #2 — editing surface (AGENTS.md O1 criterion 2).
#
# The make-or-break question: is Ck's `text` widget usable as a code editor?
# Exercises multiline insert, a viewport over a ~5k-line buffer, the insert
# cursor/mark, line navigation, and a tag with -foreground (syntax/diff colour).
# Catalogue in VERDICT.md anything that misbehaves vs Tk's `text`.
#
# Run:  CK_LIBRARY=../ck8.6/library ../ck8.6/cwsh 02-edit.tcl
#   q quits;  Up/Down/PageUp/PageDown/Home/End navigate;  i inserts a marker line.

message .hint -justify center -width 200 \
	-text "CK-SPIKE-02  text widget — q quit, arrows/PgUp/PgDn scroll, i insert"
pack .hint -side top -fill x

text .t -wrap none
scrollbar .sb -command {.t yview}
.t configure -yscrollcommand {.sb set}
pack .sb -side right -fill y
pack .t -side left -fill both -expand yes

# Fill ~5000 lines so scrolling/viewport is exercised on a real-sized buffer.
for {set i 1} {$i <= 5000} {incr i} {
	.t insert end [format "%4d: the quick brown fox jumps over the lazy dog\n" $i]
}

# A colour tag over the first token of line 1 — proves foreground tagging works.
catch {
	.t tag configure kw -foreground green
	.t tag add kw 1.0 1.4
}

.t mark set insert 1.0
.t see 1.0

# Navigation + an insert that mutates the buffer mid-stream.
bind .t <Key-i> {.t insert insert "<<< CK-SPIKE-02 INSERTED >>>\n"}
bind . <Key-q> {exit 0}
focus .t
