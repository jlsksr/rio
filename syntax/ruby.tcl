# rio — a Ruby syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `=begin … =end` block comment and a multi-line
# string each colour as one unit.
#
# It colours: `#` line comments and `=begin … =end` block comments (both at column 0) as
# `comment`; `'…'`, `"…"` (interpolation left inside the string), and `` `…` `` command
# strings as `string`; `:name` symbols as `constant`; `@ivar` / `@@cvar` / `$global` as
# `variable`; numbers as `number`; declaration/control words as `keyword`; `nil`/`true`/
# `false` as `constant`; common core methods (`puts`, `require`, `attr_accessor`, …) and a
# called/defined name as `function`; a `def` method name as `function`; and Capitalised
# names (classes, modules, constants) as `type`.
#
# Deliberately NOT handled (honest gaps, so nothing is mis-coloured): here-docs
# (`<<~SQL`), bare `/regex/` (the `/` is indistinguishable from division without a real
# parser), and the `%w[]` / `%r{}` percent-literals. Pure: no Tk here — tests headless.

namespace eval rio::syntax::ruby {}

# Declarations, control flow, and word operators → `keyword`.
set rio::syntax::ruby::keywords {
	def end if elsif else unless while until for in do
	begin rescue ensure retry raise
	return yield next break redo then
	case when class module self super
	and or not defined? alias undef
	__method__ __FILE__ __LINE__ BEGIN END
}
set rio::syntax::ruby::constants {nil true false}
# Common core / Kernel methods and declaration helpers → `function` (a distinct hue
# from the control keywords). Bare identifiers not on this list stay plain.
set rio::syntax::ruby::builtins {
	require require_relative load autoload
	attr_accessor attr_reader attr_writer
	include extend prepend using refine
	puts print p pp gets sprintf format
	fail throw catch loop lambda proc
	public private protected module_function
	freeze new
}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code |
# bcomment (inside a =begin/=end block) | str (a '…'/"…"/`…` that spilled past the line;
# `param` holds its quote char). The START state "" falls through to the code arm.
proc rio::syntax::ruby::scan {line state param} {
	variable keywords
	variable constants
	variable builtins
	set spans {}
	set n [string length $line]
	set i 0

	# --- whole-line =begin/=end block comment (both must sit at column 0) --------
	if {$state eq "bcomment"} {
		if {$n > 0} { lappend spans 0 $n comment }
		if {[string match "=end*" $line]} { return [list $spans code ""] }
		return [list $spans bcomment ""]
	}
	if {($state eq "" || $state eq "code") && [regexp {^=begin(\s|$)} $line]} {
		lappend spans 0 $n comment
		return [list $spans bcomment ""]
	}
	if {$state eq ""} { set state code }

	set pend ""   ;# after `def`/`class`/`module`, the next NAME gets function/type
	while {$i < $n} {
		switch -- $state {
			str {
				set q [dict get $param q]
				set j [_strend $line $q $i]
				if {$j < 0} { lappend spans $i $n string ; set i $n } \
				else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] ; set state code }
			}
			default {  ;# code
				set ch [string index $line $i]
				set sub [string range $line $i end]
				if {$ch eq "#"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$ch eq "\"" || $ch eq "'" || $ch eq "`"} {
					set pend ""
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n
						set state str ; set param [dict create q $ch]
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {$ch eq "@" && [regexp -indices {^@@?[[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] variable ; incr i $len
				} elseif {$ch eq "\$" && [regexp -indices {^\$[[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] variable ; incr i $len
				} elseif {$ch eq ":" && [_symbolhere $line $i]} {
					regexp -indices {^:[[:alpha:]_][[:alnum:]_]*[?!]?} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] constant ; incr i $len
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][-+]?[0-9_]+)?|\.[0-9_]+(?:[eE][-+]?[0-9_]+)?)} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*[?!]?} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					if {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {$word eq "def"} { set pend function }
						if {$word eq "class" || $word eq "module"} { set pend type }
					} elseif {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] $pend ; set pend ""
					} elseif {[string match {[A-Z]*} $word]} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {[lsearch -exact $builtins $word] >= 0} {
						lappend spans $i [expr {$i + $len}] function
					} elseif {$after eq "("} {
						lappend spans $i [expr {$i + $len}] function
					}
					incr i $len
				} else {
					incr i
				}
			}
		}
	}
	return [list $spans $state $param]
}

# Is the `:` at column `i` the start of a `:name` SYMBOL (not a `::` scope operator, a
# ternary `? :`, or a `key:` label)? True when the next char begins an identifier and the
# previous char is not itself part of a name or a second colon.
proc rio::syntax::ruby::_symbolhere {line i} {
	set nx [string index $line [expr {$i + 1}]]
	if {![regexp {[[:alpha:]_]} $nx]} { return 0 }
	set prev [string index $line [expr {$i - 1}]]
	if {$prev eq ":"} { return 0 }
	return [expr {![regexp {[[:alnum:]_]} $prev]}]
}

# The end index (of the closing quote) of a '…'/"…"/`…` string beginning at column `i`,
# honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::ruby::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Ruby {rb rake gemspec ru} rio::syntax::ruby::scan
