# rio — a SQL syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `/* … */` block comment and a multi-line string
# each colour as one unit.
#
# It colours: `--` line comments and `/* … */` block comments as `comment`; `'…'` string
# literals as `string` (SQL's escape is a DOUBLED quote `''`, not a backslash — so
# `'it''s'` is one string); `"…"` and `` `…` `` delimited IDENTIFIERS as `variable`
# (same doubling rule); numbers as `number`; the reserved words as `keyword` and the
# built-in data types as `type` (both matched CASE-INSENSITIVELY — SQL keywords are);
# `null`/`true`/`false`/`unknown` as `constant`; a called/defined name (`name(`) as
# `function`; and bind parameters `@name` / `:name` / `$1` as `variable`. Plain
# identifiers stay plain.
#
# Scoped: SQL is a family of dialects — this lights the ANSI core plus the most common
# Postgres/MySQL/SQLite words; a `"…"` is read as a delimited identifier (the standard),
# not a string (as some dialects treat it). Pure: no Tk here — tests headless under tclsh.

namespace eval rio::syntax::sql {}

# Reserved words (stored lowercase; the scanner lowercases each word before matching, so
# SELECT / select / Select all light). Multi-word forms like `GROUP BY` or `PRIMARY KEY`
# are covered by listing each component word — every part lights on its own.
set rio::syntax::sql::keywords {
	select from where insert into values update set delete merge upsert
	create alter drop truncate table view index database schema sequence
	trigger procedure function returns language
	join inner outer left right full cross natural on using
	union intersect except all any some
	distinct as group by order having limit offset fetch first next rows only top
	and or not is in like ilike similar between escape
	case when then else end
	with recursive
	primary key foreign references default unique check constraint collate
	cascade restrict deferrable initially
	begin commit rollback transaction start savepoint release work
	grant revoke to
	asc desc nulls
	returning
	if add column rename replace
	declare open close cursor for loop while
	over partition window range unbounded preceding following current row
	exists case
	values
}
# Built-in data types (also matched case-insensitively).
set rio::syntax::sql::types {
	int integer smallint bigint tinyint mediumint int2 int4 int8
	decimal numeric float real double precision money
	char varchar character nchar nvarchar text string
	date time timestamp timestamptz datetime interval year
	boolean bool bit binary varbinary blob clob bytea
	serial bigserial smallserial uuid json jsonb xml array enum
}
set rio::syntax::sql::constants {null true false unknown}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code |
# comment (block /* */) | str (a '…'/"…"/`…` that spilled past the line; `param` holds
# its quote char). The START state "" falls through to the code arm.
proc rio::syntax::sql::scan {line state param} {
	variable keywords
	variable types
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	if {$state eq ""} { set state code }
	while {$i < $n} {
		switch -- $state {
			comment {
				set k [string first "*/" $line $i]
				if {$k < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] ; set state code }
			}
			str {
				set q [dict get $param q]
				set j [_strend $line $q $i]
				if {$j < 0} { lappend spans $i $n [_strtype $q] ; set i $n } \
				else {
					lappend spans $i [expr {$j + 1}] [_strtype $q] ; set i [expr {$j + 1}]
					set state code
				}
			}
			default {  ;# code
				set ch [string index $line $i]
				set two [string range $line $i [expr {$i + 1}]]
				set sub [string range $line $i end]
				if {$two eq "--"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$two eq "/*"} {
					set k [string first "*/" $line [expr {$i + 2}]]
					if {$k < 0} { lappend spans $i $n comment ; set i $n ; set state comment } \
					else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] }
				} elseif {$ch eq "'" || $ch eq "\"" || $ch eq "`"} {
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n [_strtype $ch] ; set i $n
						set state str ; set param [dict create q $ch]
					} else {
						lappend spans $i [expr {$j + 1}] [_strtype $ch] ; set i [expr {$j + 1}]
					}
				} elseif {($ch eq "@" || $ch eq ":") && [regexp -indices {^[@:][[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] variable ; incr i $len
				} elseif {$ch eq "\$" && [regexp -indices {^\$[0-9]+} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] variable ; incr i $len
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					regexp -indices {^(?:0[xX][[:xdigit:]]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set lw [string tolower $word]
					set after [string index $line [expr {$i + $len}]]
					if {[lsearch -exact $constants $lw] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $keywords $lw] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
					} elseif {[lsearch -exact $types $lw] >= 0} {
						lappend spans $i [expr {$i + $len}] type
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

# The token type for a quoted run by its opening quote: a single quote is a string
# LITERAL; a double-quote or backtick is a delimited IDENTIFIER (coloured `variable`).
proc rio::syntax::sql::_strtype {q} {
	return [expr {$q eq "'" ? "string" : "variable"}]
}

# The end index (of the closing quote) of a quoted run of quote `q` beginning at column
# `i`; -1 if it does not close on this line. SQL escapes an embedded quote by DOUBLING it
# (`''`, `""`, ` `` `), so a doubled quote is literal and scanning continues past it.
proc rio::syntax::sql::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq $q} {
			if {[string index $line [expr {$i + 1}]] eq $q} { incr i 2 ; continue }
			return $i
		}
		incr i
	}
	return -1
}

rio::syntax::register SQL {sql} rio::syntax::sql::scan
