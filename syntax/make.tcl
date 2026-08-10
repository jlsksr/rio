# rio — a Makefile syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a per-line scanner (see rio::syntax for the contract). Make is
# line-oriented and largely stateless, so this carries no scan state: every line stands
# alone. It is registered both by whole basename (`Makefile`, `GNUmakefile`) and by
# extension (`.mk`, `.make`) — see rio::syntax::register_filename (D46).
#
# It colours: `#` comments as `comment`; the directives (`ifeq`, `include`, `define`, …)
# as `keyword`; the target name(s) of a rule (`foo bar: deps`) as `function`; the name of
# a `VAR = value` / `:=` / `?=` / `+=` assignment as `variable`; and variable / function
# references (`$(CC)`, `${OBJ}`, `$@`, `$<`, `$(patsubst …)`) as `variable`, except that a
# reference whose leading word is a built-in make function (`wildcard`, `shell`, `foreach`,
# …) colours as `function`. A `$$` is left plain (make's escaped dollar).
#
# Recipe lines (tab-indented) get the same reference / comment colouring but no target or
# assignment parsing — they are shell fragments. Honest gap: a `define … endef` block body
# is coloured line-by-line as ordinary make, not as one literal span (rare; noted).

namespace eval rio::syntax::make {}

# Directives → `keyword` (matched at the start of a non-recipe line).
set rio::syntax::make::directives {
	include -include sinclude ifeq ifneq ifdef ifndef else endif
	define endef export unexport override undefine vpath
}
# Built-in functions → `function` when they lead a `$(…)` reference.
set rio::syntax::make::functions {
	subst patsubst strip findstring filter filter-out sort word wordlist
	words firstword lastword dir notdir suffix basename addsuffix addprefix
	join wildcard realpath abspath if or and intcmp let foreach file call value
	eval origin flavor shell error warning info guile
}

# scan ONE line (state unused — Makefiles are line-local). Returns {spans "" ""}.
proc rio::syntax::make::scan {line state param} {
	variable directives
	variable functions
	set spans {}
	set n [string length $line]
	set recipe [expr {[string index $line 0] eq "\t"}]

	# --- leading construct on a non-recipe line ------------------------------------
	if {!$recipe} {
		if {[regexp -indices {^[ \t]*(-?include|sinclude|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|export|unexport|override|undefine|vpath)\y} $line _ d]} {
			lappend spans [lindex $d 0] [expr {[lindex $d 1] + 1}] keyword
		} elseif {[regexp -indices {^[ \t]*([A-Za-z_.][A-Za-z0-9_./-]*)[ \t]*(::=|:=|\?=|\+=|!=|=)} $line _ name]} {
			lappend spans [lindex $name 0] [expr {[lindex $name 1] + 1}] variable
		} elseif {[regexp -indices {^[ \t]*([^\t#=:]+):} $line _ tgt]} {
			lassign $tgt ts te
			set region [string range $line $ts $te]
			foreach m [regexp -all -inline -indices {[^ \t]+} $region] {
				lassign $m a b
				set word [string range $region $a $b]
				if {[string first {$} $word] < 0} {
					lappend spans [expr {$ts + $a}] [expr {$ts + $b + 1}] function
				}
			}
		}
	}

	# --- references and comments, everywhere on the line ---------------------------
	set i 0
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} {
			incr i 2   ;# an escaped char / line-continuation backslash
		} elseif {$ch eq "#"} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "\$"} {
			set nx [string index $line [expr {$i + 1}]]
			if {$nx eq "\$"} {
				incr i 2   ;# $$ — an escaped literal dollar
			} elseif {$nx eq "(" || $nx eq "\{"} {
				set len [_refend $line $i]
				set inner [string range $line [expr {$i + 2}] [expr {$i + $len - 2}]]
				set type variable
				if {[regexp {^[ \t]*([A-Za-z][A-Za-z0-9_-]*)} $inner _ fn] && [lsearch -exact $functions $fn] >= 0} {
					set type function
				}
				lappend spans $i [expr {$i + $len}] $type ; incr i $len
			} elseif {$nx ne ""} {
				lappend spans $i [expr {$i + 2}] variable ; incr i 2   ;# $@ $< $^ $* … / $X
			} else {
				incr i
			}
		} else {
			incr i
		}
	}
	return [list $spans "" ""]
}

# Length of a $(…) / ${…} reference starting at column i (line[i] == '$'), both delimiters
# included; honours nesting. An unterminated reference runs to end of line.
proc rio::syntax::make::_refend {line i} {
	set open [string index $line [expr {$i + 1}]]
	if {$open eq "("} { set close ")" } elseif {$open eq "\{"} { set close "\}" } else { return 0 }
	set n [string length $line]
	set depth 0
	for {set j [expr {$i + 1}]} {$j < $n} {incr j} {
		set c [string index $line $j]
		if {$c eq $open} {
			incr depth
		} elseif {$c eq $close} {
			incr depth -1
			if {$depth == 0} { return [expr {$j - $i + 1}] }
		}
	}
	return [expr {$n - $i}]
}

rio::syntax::register Makefile {mk make mak} rio::syntax::make::scan
rio::syntax::register_filename Makefile {Makefile makefile GNUmakefile BSDmakefile} \
	rio::syntax::make::scan
