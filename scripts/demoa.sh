#!/C:/APPS/ASH.APP
# demoa.sh: tests of ash module by module; exit code 1 if any failed.
# Works in ash_demo_tmp in the current folder and removes it.

PASSED=0
FAILED=0
MODULE=
MODULE_FAILED=0
MODULE_PASSED=0

# check NAME EXPECTED ACTUAL
check() {
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1))
        MODULE_PASSED=$((MODULE_PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        MODULE_FAILED=$((MODULE_FAILED + 1))
        echo "  [Fail] $1"
        echo "    expected: [$2]"
        echo "    got:      [$3]"
    fi
}

# status NAME EXPECTED_STATUS COMMAND...
status() {
    name=$1
    want=$2
    shift 2
    "$@" > /dev/null 2>&1
    check "$name" "$want" "$?"
}

module() {
    finish
    MODULE=$1
    MODULE_PASSED=0
    MODULE_FAILED=0
}

finish() {
    if [ -n "$MODULE" ]; then
        if [ "$MODULE_FAILED" -eq 0 ]; then
            echo "[OK]   $MODULE ($MODULE_PASSED tests)"
        else
            echo "[Fail] $MODULE ($MODULE_FAILED of $((MODULE_PASSED + MODULE_FAILED)) failed)"
        fi
    fi
}

T=ash_demo_tmp
if [ -e "$T" ]; then
    echo "$T exists already: remove it first"
    exit 1
fi
mkdir "$T" || exit 1
cd "$T" || exit 1

module "grammar: lists, pipelines, compound commands"

out=$(echo a; echo b)
check "commands in order" "a
b" "$out"
check "&& runs on success" "yes" "$(true && echo yes)"
check "&& skips on failure" "" "$(false && echo yes)"
check "|| runs on failure" "no" "$(false || echo no)"
check "&& || chain" "c" "$(false && echo a || echo c)"
check "pipeline" "HELLO" "$(echo hello | awk '{ print toupper($0) }')"
check "three-stage pipeline" "2" "$(printf 'b\na\nb\n' | sort | uniq | wc -l | awk '{ print $1 }')"
! false
check "! negates" "0" "$?"
! true
check "! negates success" "1" "$?"
check "pipeline over lines" "x" "$(echo x |
    cat |
    cat)"
check "subshell keeps variables" "outer" "$(v=outer; (v=inner); echo $v)"
check "group shares variables" "inner" "$(v=outer; { v=inner; }; echo $v)"
check "subshell exit" "3" "$( (exit 3); echo $? )"
tr_join() { awk '{ s = s $0 } END { print s }'; }
check "group into pipe" "12" "$({ echo 1; echo 2; } | tr_join)"

x=5
if [ $x -gt 10 ]; then r=big; elif [ $x -gt 3 ]; then r=middle; else r=small; fi
check "if elif else" "middle" "$r"
if false; then r=a
else
    r=b
fi
check "if over lines" "b" "$r"
if false; then :; fi
check "if without match is 0" "0" "$?"

i=0
while [ $i -lt 5 ]; do i=$((i + 1)); done
check "while" "5" "$i"
i=0
until [ $i -ge 3 ]
do
    i=$((i + 1))
done
check "until" "3" "$i"
s=
for w in a b c; do s="$s$w"; done
check "for in" "abc" "$s"
set -- x y
s=
for w; do s="$s$w"; done
check "for without in: the arguments" "xy" "$s"
s=
for w in 1 2 3 4 5; do
    [ $w = 2 ] && continue
    [ $w = 4 ] && break
    s="$s$w"
done
check "break and continue" "13" "$s"
s=
for a in 1 2; do for b in x y; do [ $b = y ] && continue 2; s="$s$a$b"; done; done
check "continue 2" "1x2x" "$s"
s=
for a in 1 2; do for b in x y; do s="$s$a$b"; break 2; done; done
check "break 2" "1x" "$s"
s=
while true; do while true; do break 2; done; s=wrong; done
check "break 2 from while" "" "$s"

for v in apple b.c x7 Zed ''; do
    case $v in
        a*) r=a ;;
        *.c|*.h) r=source ;;
        x[0-9]) r=digit ;;
        [[:upper:]]*|[A-Z]*) r=upper ;;
        "") r=empty ;;
        *) r=other ;;
    esac
    s="$s$r,"
done
check "case patterns" "a,source,digit,upper,empty," "$s"
case "a*b" in "a*b") r=literal ;; *) r=glob ;; esac
check "quoted case pattern is literal" "literal" "$r"
case x in (x) r=paren ;; esac
check "case with (pattern)" "paren" "$r"
case y in x) r=1 ;; esac
check "case without match is 0" "0" "$?"

# comment at the start of a line
check "comments" "a" "$(echo a # not printed
)"
check "line continuation" "ab" "$(echo a\
b)"
check "multi-line quotes" "1
2" "$(echo "1
2")"
check "semicolon after then" "ok" "$(if true; then echo ok; fi)"

module "functions"

f1() { echo "f1 $1 $#"; }
check "function call" "f1 a 2" "$(f1 a b)"
function f2 { echo f2; }
check "function keyword" "f2" "$(f2)"
function f3() { return 4; }
f3
check "return status" "4" "$?"
f4() {
    echo before
    return
    echo after
}
check "return stops" "before" "$(f4)"
g=global
f5() { g=changed; }
f5
check "functions share variables" "changed" "$g"
f6() { local g=local; echo $g; }
g=global
check "local inside" "local" "$(f6)"
f6 > /dev/null
check "local restored" "global" "$g"
fact() { if [ $1 -le 1 ]; then echo 1; else echo $(( $1 * $(fact $(( $1 - 1 ))) )); fi; }
check "recursion" "120" "$(fact 5)"
outer() { inner() { echo inner; }; inner; }
check "function defining function" "inner" "$(outer)"
args() { echo "$#:$1:$2"; }
set -- p q r
check "function args don't touch the script's" "2:a b:c" "$(args "a b" c)"
check "script args after the call" "3" "$#"
f7() { set -- 1 2 3 4; echo $#; }
f7 > /dev/null
check "set -- in a function is local" "3" "$#"
counter() { n=$((n + 1)); }
n=0; counter; counter
check "function in a loop" "2" "$n"
redir() { echo inside; } > fn_out.txt
redir
check "function redirection" "inside" "$(cat fn_out.txt)"
unset -f redir
check "unset -f" "127" "$(redir 2>/dev/null; echo $?)"

module "quoting and parameters"

v="a  b"
check "single quotes" '$v' '$v'
check "double quotes keep spaces" "a  b" "$v"
check "unquoted splits" "a b" "$(echo $v)"
check "backslash" '$v' "\$v"
check "backslash in double quotes" 'a"b\c$' "a\"b\\c\$"
check "backslash before other char stays" '\n' "\n"
check "adjacent quotes" "abcd" 'a'"b"c\d
check "\$'...' escapes" "a	b'c" $'a\tb\'c'
check "\$'...' octal and hex" "AB" $'\101\x42'
check "braces" "a  bx" "${v}x"
check "empty string argument" "1" "$(set -- ""; echo $#)"
set -- one "two three" four
check "\$#" "3" "$#"
check "\$1 \$2" "one/two three" "$1/$2"
check "\"\$@\" keeps arguments" "3" "$(args() { echo $#; }; args "$@")"
check "\$* joins" "one two three four" "$*"
check "\"\$@\" empty" "0" "$(set --; args() { echo $#; }; args "$@")"
check "\${10}" "j" "$(set -- a b c d e f g h i j; echo ${10})"
shift
check "shift" "two three" "$1"
shift 2
check "shift 2" "0" "$#"
check "\$0 is set" "1" "$( [ -n "$0" ] && echo 1)"
false
check "\$?" "1" "$?"
unset u
check ":-" "def" "${u:-def}"
check "- with unset" "def" "${u-def}"
e=
check "- with empty" "" "${e-def}"
check ":- with empty" "def" "${e:-def}"
check ":=" "set" "${u:=set}$( : )"
check ":= assigns" "set" "$u"
check ":+" "alt" "${u:+alt}"
check ":+ unset" "" "${nothing:+alt}"
check ":? set" "set" "${u:?msg}"
check ":? unset fails" "1" "$( (: ${nothing:?missing}) 2>/dev/null; echo $?)"
p=dir/sub/file.tar.gz
check "#" "sub/file.tar.gz" "${p#*/}"
check "##" "file.tar.gz" "${p##*/}"
check "%" "dir/sub/file.tar" "${p%.*}"
check "%%" "dir/sub/file" "${p%%.*}"
check "#var" "19" "${#p}"
check "/" "dir-sub/file.tar.gz" "${p/\//-}"
check "//" "dir-sub-file.tar.gz" "${p//\//-}"
check "/#" "Xir/sub/file.tar.gz" "${p/#d/X}"
check "/%" "dir/sub/file.tar.bz2" "${p/%gz/bz2}"
check "substring" "sub" "${p:4:3}"
check "substring to end" "gz" "${p:17}"
check "negative offset" "gz" "${p: -2}"
check "pattern from variable" "tar.gz" "$(x='*.'; echo ${p#$x})"
check "quoted pattern is literal" "dir/sub/file.tar.gz" "${p#'*'/}"
check "~ is HOME" "/home" "$(HOME=/home; echo ~)"
check "\$- has letters" "0" "$(case $- in *u*) echo 1 ;; *) echo 0 ;; esac)"

module "command substitution and arithmetic"

check "\$( )" "hi" "$(echo hi)"
check "nested \$( )" "a b c" "$(echo a $(echo b $(echo c)))"
check "backquotes" "bq" "`echo bq`"
check "trailing newlines go" "x" "$(printf 'x\n\n\n')"
check "inner newlines stay" "2" "$(v=$(printf 'a\nb'); echo "$v" | wc -l | awk '{print $1}')"
check "\$( ) with quotes inside" "a b" "$(echo "a b")"
check "\$( ) with case inside" "yes" "$(case a in a) echo yes ;; esac)"
check "status of \$( )" "1" "$(x=$(false); echo $?)"
check "+ - * / %" "17 3 2" "$((2 + 3 * 5)) $((7 / 2)) $((17 % 5))"
check "parentheses" "25" "$(( (2 + 3) * 5 ))"
check "variables in \$(( ))" "12" "$(a=4; b=3; echo $((a * b)))"
check "\$var in \$(( ))" "7" "$(a=4; echo $(($a + 3)))"
check "comparisons" "1 0 1 1" "$((3 > 2)) $((3 < 2)) $((2 == 2)) $((2 != 3))"
check "logic" "1 0 1" "$((1 && 2)) $((0 || 0)) $((!0))"
check "ternary" "yes" "$( [ $((5 > 3 ? 1 : 0)) = 1 ] && echo yes)"
check "bits" "6 7 1 8 2" "$((6 & 7)) $((6 | 1)) $((6 ^ 7)) $((1 << 3)) $((8 >> 2))"
check "negative" "-3 -1" "$((-3)) $((-7 / 7))"
check "hex and octal" "255 8" "$((0xff)) $((010))"
check "assignment" "5 5" "$(echo $((z = 5)) $z)"
check "+=" "7" "$(z=5; : $((z += 2)); echo $z)"
check "++ and --" "6 6 5" "$(z=5; echo $((++z)) $z $((z - 1)))"
check "division by zero fails" "1" "$( (echo $((1 / 0))) 2>/dev/null; echo $?)"
check "unset counts as 0" "1" "$((nothing + 1))"

module "field splitting and file names"

v="a:b::c"
check "IFS split" "a b  c" "$(IFS=:; set -- $v; echo "$1 $2 $3 $4")"
check "IFS count" "4" "$(IFS=:; set -- $v; echo $#)"
check "white IFS collapses" "2" "$(set -- $(echo '  x   y  '); echo $#)"
check "empty unquoted vanishes" "0" "$(e=; set -- $e; echo $#)"
check "quoted empty stays" "1" "$(e=; set -- "$e"; echo $#)"
mkdir globs
touch globs/a1.txt globs/a2.txt globs/b1.txt globs/c.log
check "*" "globs/a1.txt globs/a2.txt globs/b1.txt" "$(echo globs/*.txt)"
check "?" "globs/a1.txt globs/a2.txt" "$(echo globs/a?.txt)"
check "[ ]" "globs/a1.txt globs/b1.txt" "$(echo globs/[ab]1.txt)"
check "[! ]" "globs/b1.txt" "$(echo globs/[!a]*.txt)"
check "no match stays" "globs/*.none" "$(echo globs/*.none)"
check "quoted * stays" "globs/*.txt" "$(echo "globs/*.txt")"
check "escaped * stays" "globs/*.txt" "$(echo globs/\*.txt)"
mkdir globs/sub
touch globs/sub/x.txt
check "*/ over folders" "globs/sub/x.txt" "$(echo globs/*/*.txt)"
check "glob from a variable" "globs/c.log" "$(p='globs/*.log'; echo $p)"
check "set -f stops patterns" "globs/*.log" "$(set -f; echo globs/*.log)"
check "for over files" "4" "$(n=0; for f in globs/*.*; do n=$((n + 1)); done; echo $n)"

module "arrays"

arr=(one "two words" three)
check "elements" "3" "${#arr[@]}"
check "index" "two words" "${arr[1]}"
check "\$arr is element 0" "one" "$arr"
check "\"\${arr[@]}\" keeps elements" "3" "$(args() { echo $#; }; args "${arr[@]}")"
check "\${arr[*]} joins" "one two words three" "${arr[*]}"
arr+=(four)
check "+=" "four" "${arr[3]}"
arr[4]=five
check "arr[i]=" "5 five" "${#arr[@]} ${arr[4]}"
i=1
check "index expression" "three" "${arr[i+1]}"
empty=()
check "empty array" "0" "${#empty[@]}"
check "\"\${empty[@]}\" is nothing" "0" "$(args() { echo $#; }; args "${empty[@]}")"
list=(
    a b   # comments inside
    c
)
check "array over lines" "a b c" "${list[*]}"
s=
for x in "${arr[@]}"; do s="$s[$x]"; done
check "for over array" "[one][two words][three][four][five]" "$s"
check "length of element" "9" "${#arr[1]}"

module "redirections"

echo one > r.txt
echo two >> r.txt
check "> and >>" "one
two" "$(cat r.txt)"
check "<" "one" "$(head -n 1 < r.txt)"
echo three > r.txt
check "> empties" "three" "$(cat r.txt)"
check "> /dev/null" "" "$(echo gone > /dev/null)"
check "> NUL" "" "$(echo gone > NUL)"
check "NUL makes no file" "1" "$( [ ! -e NUL ] && echo 1)"
check "< /dev/null" "0" "$(wc -l < /dev/null | awk '{ print $1 }')"
check "2> /dev/null hides errors" "" "$(cat no_such_file 2>/dev/null)"
check "errors don't go into pipes" "0" "$(cat no_such_file 2>/dev/null | wc -l | awk '{ print $1 }')"
check "2>&1 sends errors along" "1" "$(cat no_such_file 2>&1 | grep -c no_such_file)"
cat no_such_file 2> err.txt
check "2> file" "1" "$(grep -c no_such_file err.txt)"
check ">&2 goes to the error output" "" "$(echo to-errors 2>/dev/null >&2)"
hv=5
cat <<EOF > h.txt
line $hv
  indented
EOF
check "here-document" "line 5
  indented" "$(cat h.txt)"
check "quoted here-document" 'no $hv' "$(cat <<'END'
no $hv
END
)"
check "<<- strips tabs" "tabbed" "$(cat <<-END
	tabbed
	END
)"
check "<<< here-string" "word 2" "$(cat <<< "word $((1 + 1))")"
check "read <<<" "b" "$(read x y <<< 'a b'; echo $y)"
printf 'a\nb\nc\n' > lines.txt
n=0
while read -r l; do n=$((n + 1)); done < lines.txt
check "while read < file" "3" "$n"
{ echo x; echo y; } > grp.txt
check "group > file" "x
y" "$(cat grp.txt)"
for i in 1 2; do echo $i; done > loop.txt
check "loop > file" "1
2" "$(cat loop.txt)"
exec 3> /dev/null
check "exec with redirections" "0" "$?"

module "variables, set, export"

VALUE=hello
check "assignment" "hello" "$VALUE"
lower=1
LOWER=2
check "names are case-sensitive" "1 2" "$lower $LOWER"
VALUE=x true
check "NAME=v cmd is temporary" "hello" "$VALUE"
f() { echo $TMPV; }
check "NAME=v for a function" "tmp" "$(TMPV=tmp f)"
export ASH_DEMO_EXPORTED=visible
check "export reaches env" "1" "$(env | grep -c ASH_DEMO_EXPORTED=visible)"
check "env NAME=v cmd" "1" "$(env ASH_DEMO_ONE=1 env | grep -c ASH_DEMO_ONE=1)"
unset ASH_DEMO_EXPORTED
check "unset" "" "$ASH_DEMO_EXPORTED"
check "unset leaves env" "0" "$(env | grep -c ASH_DEMO_EXPORTED)"
readonly RO=ro
check "readonly assigns" "ro" "$RO"
check "set lists variables" "1" "$(set | grep -c "^VALUE='hello'")"
check "set -e stops" "a" "$( (set -e; echo a; false; echo b) )"
check "set -e not in if" "ab" "$( (set -e; if false; then :; fi; echo a; false || echo b) | tr_join)"
check "set -e not in &&" "a" "$( (set -e; false && echo x; echo a) )"
check "set -u stops" "1" "$( (set -u; echo $nothing_here) 2>/dev/null; echo $?)"
check "set -u allows defaults" "d" "$( (set -u; echo ${nothing_here:-d}) )"
check "set -o pipefail" "1 0" "$( (false | true; a=$?; set -o pipefail; false | true; echo $? $a) )"
check "set -x traces to errors" "x" "$( (set -x; echo x) 2>/dev/null)"
check "set +e" "ab" "$( (set -e; set +e; false; echo a; echo b) | tr_join)"
check "set -euo pipefail" "ok" "$( (set -euo pipefail; echo ok) )"

module "read, echo, printf"

check "read words" "a|b c" "$(echo 'a b c' | { read x y; echo "$x|$y"; })"
check "read REPLY" "line" "$(echo line | { read; echo $REPLY; })"
check "read -r keeps \\" 'a\b' "$(echo 'a\b' | { read -r x; echo "$x"; })"
check "read without -r" 'ab' "$(echo 'a\b' | { read x; echo "$x"; })"
check "read IFS" "a|b" "$(echo 'a,b' | { IFS=, read x y; echo "$x|$y"; })"
check "read at end fails" "1" "$(printf '' | { read x; echo $?; })"
check "read last line without newline" "end 1" "$(printf 'end' | { read x; echo $x $?; })"
check "echo -n" "ab" "$(echo -n a; echo b)"
check "echo -e" "a	b" "$(echo -e 'a\tb')"
check "echo plain backslash" 'a\tb' "$(echo 'a\tb')"
check "printf %s %d" "x 42" "$(printf '%s %d' x 42)"
check "printf widths" "  ab|7    |007" "$(printf '%4s|%-5d|%03d' ab 7 7)"
check "printf repeats" "a,b,c," "$(printf '%s,' a b c)"
check "printf %x %o %c" "ff 10 A" "$(printf '%x %o %c' 255 8 ABC)"
check "printf %f %e" "3.14 1.500000e+00" "$(printf '%.2f %e' 3.14159 1.5)"
check "printf %b" "a
b" "$(printf '%b' 'a\nb')"
check "printf \\n" "1
2" "$(printf '1\n2')"
check "printf 'c" "65" "$(printf '%d' "'A")"
check "printf %%" "100%" "$(printf '100%%')"

module "test and ["

status "string =" 0 [ abc = abc ]
status "string !=" 0 [ abc != abd ]
status "-z" 0 [ -z "" ]
status "-n" 0 [ -n x ]
status "one argument" 1 [ "" ]
status "-eq" 0 [ 5 -eq 5 ]
status "-ne" 0 test 5 -ne 6
status "-lt -le" 0 [ 2 -lt 3 -a 3 -le 3 ]
status "-gt -ge" 0 [ 4 -gt 3 -a 3 -ge 3 ]
status "!" 0 [ ! 1 -eq 2 ]
status "-o" 0 [ 1 -eq 2 -o 2 -eq 2 ]
status "( )" 1 [ \( 1 -eq 2 -o 2 -eq 2 \) -a 1 -eq 2 ]
status "< >" 0 [ abc \< abd ]
status "-e file" 0 [ -e r.txt ]
status "-f file" 0 [ -f r.txt ]
status "-d folder" 0 [ -d globs ]
status "-f folder" 1 [ -f globs ]
status "-s non-empty" 0 [ -s r.txt ]
touch empty.txt
status "-s empty" 1 [ -s empty.txt ]
status "missing ]" 2 [ 1 -eq 1
status "not a number" 2 [ x -eq 1 ]

module "cd, pwd, eval, source, trap, command"

here=$(pwd)
mkdir -p d1/d2
cd d1/d2
check "cd and pwd" "$here/d1/d2" "$(pwd)"
cd ../..
check "cd .." "$here" "$(pwd)"
cd d1
cd -  > /dev/null
check "cd -" "$here" "$(pwd)"
check "OLDPWD" "$here/d1" "$OLDPWD"
check "subshell cd stays inside" "$here" "$( (cd d1); pwd)"
eval 'ev=$((1 + 2))'
check "eval" "3" "$ev"
cmd='echo evaluated'
check "eval of a variable" "evaluated" "$(eval $cmd)"
echo 'SOURCED=yes; set -- s1 s2' > inc.sh
. ./inc.sh
check ". runs in this shell" "yes" "$SOURCED"
echo 'return 5; echo no' > ret.sh
. ./ret.sh
check "return in a sourced file" "5" "$?"
tr_join2() { awk '{ s = s (NR > 1 ? " " : "") $0 } END { print s }'; }
check "trap EXIT" "body bye" "$( (trap 'echo bye' EXIT; echo body) | tr_join2)"
check "command -v builtin" "echo" "$(command -v echo)"
myfunc() { :; }
check "command -v function" "myfunc" "$(command -v myfunc)"
check "command skips functions" "real" "$(echo() { printf 'function\n'; }; command echo real)"
check "type builtin" "cd is a shell builtin" "$(type cd)"
status "unknown command" 127 no_such_command_here
check "which builtin" "echo: shell built-in" "$(which echo)"

module "cat, head, tail, wc"

printf '1\n2\n3\n4\n5\n' > n.txt
check "cat" "1
2" "$(cat n.txt | head -n 2)"
check "cat -n" "     1	1" "$(cat -n n.txt | head -n 1)"
check "cat files" "3" "$(cat r.txt r.txt err.txt | wc -l | awk '{ print $1 }')"
check "cat -" "x" "$(echo x | cat -)"
check "head -n" "1 2" "$(head -n 2 n.txt | tr_join2)"
check "head -N" "1 2 3" "$(head -3 n.txt | tr_join2)"
check "head -c" "1" "$(head -c 1 n.txt)"
check "head of pipe" "1" "$(cat n.txt | head -n 1)"
check "tail -n" "4 5" "$(tail -n 2 n.txt | tr_join2)"
check "tail -N" "5" "$(tail -1 n.txt)"
check "tail +N" "4 5" "$(tail -n +4 n.txt | tr_join2)"
check "tail of pipe" "5" "$(cat n.txt | tail -n 1)"
check "wc -l" "5" "$(wc -l < n.txt | awk '{ print $1 }')"
check "wc -w" "3" "$(echo 'a b  c' | wc -w | awk '{ print $1 }')"
check "wc -c" "4" "$(printf 'abc\n' | wc -c | awk '{ print $1 }')"
check "wc file name" "n.txt" "$(wc -l n.txt | awk '{ print $2 }')"

module "grep"

printf 'apple pie\nbanana\nApple tart\ncherry\npineapple\n' > g.txt
check "plain" "2" "$(grep -c apple g.txt)"
check "-i" "3" "$(grep -ci apple g.txt)"
check "-v" "banana cherry" "$(grep -vi apple g.txt | tr_join2)"
check "-n" "2:banana" "$(grep -n banana g.txt)"
check "^ anchor" "apple pie" "$(grep '^apple' g.txt)"
check "\$ anchor" "pineapple" "$(grep 'apple$' g.txt)"
check "\$ alone" "5" "$(grep -c '$' g.txt)"
check ". and *" "banana" "$(grep 'b.n.*a$' g.txt)"
check "[ ]" "cherry" "$(grep '^[c-d]' g.txt)"
check "BRE \\( \\) \\{ \\}" "banana" "$(grep 'b\(an\)\{2\}' g.txt)"
check "-E" "banana cherry" "$(grep -E '^(ba|ch)' g.txt | tr_join2)"
check "-E +" "banana" "$(grep -E '(an)+a$' g.txt)"
check "-F" "0" "$(grep -cF 'a.p' g.txt)"
check "-w" "apple pie" "$(grep -w apple g.txt)"
check "-x" "banana" "$(grep -x 'banana' g.txt)"
check "-o" "an an" "$(grep -o an g.txt | head -n 2 | tr_join2)"
check "-e twice" "2" "$(grep -c -e banana -e cherry g.txt)"
check "-l" "g.txt" "$(grep -l cherry g.txt n.txt)"
check "names with more files" "g.txt:cherry" "$(grep cherry g.txt n.txt)"
check "-h" "cherry" "$(grep -h cherry g.txt n.txt)"
status "-q found" 0 grep -q cherry g.txt
status "not found" 1 grep -q durian g.txt
status "missing file" 2 grep -q x no_such_file
mkdir -p gr/sub
echo needle > gr/sub/deep.txt
check "-r" "gr/sub/deep.txt:needle" "$(grep -r needle gr)"
check "stdin" "x" "$(echo x | grep x)"

module "sort, uniq, cut"

printf 'b 2\na 10\nc 1\na 10\n' > s.txt
check "sort" "a 10,a 10,b 2,c 1," "$(sort s.txt | awk '{ printf "%s,", $0 }')"
check "sort -r" "c 1" "$(sort -r s.txt | head -n 1)"
check "sort -u" "3" "$(sort -u s.txt | wc -l | awk '{ print $1 }')"
check "sort -n" "1 2 10" "$(printf '10\n2\n1\n' | sort -n | tr_join2)"
check "sort -k2n" "c 1,b 2,a 10,a 10," "$(sort -k2n s.txt | awk '{ printf "%s,", $0 }')"
check "sort -k2,2nr" "a 10" "$(sort -k2,2nr s.txt | head -n 1)"
check "sort -t -k" "x:1 y:2" "$(printf 'y:2\nx:1\n' | sort -t: -k2 | tr_join2)"
check "sort -f" "a B c" "$(printf 'c\nB\na\n' | sort -f | tr_join2)"
check "uniq" "a b a" "$(printf 'a\na\nb\na\n' | uniq | tr_join2)"
check "uniq -c" "2 a" "$(printf 'a\na\nb\n' | uniq -c | head -n 1 | awk '{ print $1, $2 }')"
check "uniq -d" "a" "$(printf 'a\na\nb\n' | uniq -d)"
check "uniq -u" "b" "$(printf 'a\na\nb\n' | uniq -u)"
check "uniq -i" "1" "$(printf 'a\nA\n' | uniq -i | wc -l | awk '{ print $1 }')"
check "cut -c" "bc" "$(echo abcde | cut -c 2-3)"
check "cut -c list" "ace" "$(echo abcde | cut -c 1,3,5)"
check "cut -f -d" "two" "$(echo one,two,three | cut -d , -f 2)"
check "cut -f range" "two,three" "$(echo one,two,three | cut -d, -f 2-)"
check "cut tab" "b" "$(printf 'a\tb\n' | cut -f 2)"
check "cut -s" "1" "$(printf 'plain\na,b\n' | cut -s -d , -f 2 | wc -l | awk '{ print $1 }')"
check "cut without -s" "plain" "$(echo plain | cut -d , -f 2)"

module "files: ls, cp, mv, rm, mkdir, rmdir, touch"

mkdir f
touch f/b.txt f/a.txt f/C.txt
check "ls sorted" "a.txt b.txt C.txt" "$(ls f | tr_join2)"
touch f/.hidden
check "ls hides dot files" "3" "$(ls f | wc -l | awk '{ print $1 }')"
check "ls -a" "4" "$(ls -a f | grep -cv '/$')"
check "ls -d" "f/" "$(ls -d f)"
check "ls file" "f/a.txt" "$(ls f/a.txt)"
echo data > f/a.txt
cp f/a.txt f/copy.txt
check "cp" "data" "$(cat f/copy.txt)"
mkdir f/dest
cp f/a.txt f/b.txt f/dest
check "cp to a folder" "a.txt b.txt" "$(ls f/dest | tr_join2)"
status "cp folder needs -r" 1 cp f/dest f/dest2
cp -r f/dest f/dest2
check "cp -r" "a.txt b.txt" "$(ls f/dest2 | tr_join2)"
mv f/copy.txt f/moved.txt
check "mv renames" "1 data" "$( [ ! -e f/copy.txt ] && echo 1) $(cat f/moved.txt)"
mv f/moved.txt f/C.txt f/dest
check "mv to a folder" "a.txt b.txt C.txt moved.txt" "$(ls f/dest | tr_join2)"
rm f/dest/C.txt
check "rm" "1" "$( [ ! -e f/dest/C.txt ] && echo 1)"
status "rm folder needs -r" 1 rm f/dest2
rm -r f/dest2
check "rm -r" "1" "$( [ ! -e f/dest2 ] && echo 1)"
status "rm -f missing" 0 rm -f f/none
status "rm missing" 1 rm f/none
mkdir -p f/p/q/r
check "mkdir -p" "1" "$( [ -d f/p/q/r ] && echo 1)"
status "rmdir non-empty" 1 rmdir f/p
rmdir f/p/q/r
check "rmdir" "1" "$( [ ! -e f/p/q/r ] && echo 1)"
touch f/new.txt
check "touch creates" "1" "$( [ -f f/new.txt ] && echo 1)"
status "touch -c" 0 touch -c f/nothing.txt
check "touch -c creates nothing" "1" "$( [ ! -e f/nothing.txt ] && echo 1)"

module "permissions: chmod, chown, ls -l, df -T"

# FAT: only the write bits count (the read-only attribute), no owners;
# ext2 keeps all of them:
FSTYPE=$(df -T . | tail -n 1 | awk '{ print $2 }')
check "df -T names the file system" "1" "$(case $FSTYPE in FAT*|ext*|minix|ZFS) echo 1 ;; esac)"
mode_of() { ls -ld "$1" | awk '{ print $1 }'; }
owner_of() { ls -ld "$1" | awk '{ print $2, $3 }'; }
echo perm > p.txt
echo new > y.txt
mkdir pd
echo a > pd/a.txt
if [ "${FSTYPE#FAT}" != "$FSTYPE" ]; then
    # Only the write bit is kept (the read-only attribute); the rest
    # is made up and differs by drive: the type and the owner's w
    w_of() { ls -ld "$1" | awk '{ print substr($1, 1, 1) substr($1, 3, 1) }'; }
    check "FAT: ls -l mode (writable)" "-w" "$(w_of p.txt)"
    # Owners are made up: where the test can write, the asking user's
    ME=$(id | sed 's/^uid=\([0-9]*\).* gid=\([0-9]*\).*/\1 \2/')
    check "FAT: ls -l shows the asking user as owner" "$ME" "$(owner_of p.txt)"
    chmod 444 p.txt
    check "FAT: chmod 444 makes it read only" "--" "$(w_of p.txt)"
    status "FAT: writing a read-only file refused" 1 cp y.txt p.txt
    check "FAT: its content kept" "perm" "$(cat p.txt)"
    chmod u+w p.txt
    check "FAT: chmod u+w makes it writable" "-w" "$(w_of p.txt)"
    status "FAT: writing it again" 0 cp y.txt p.txt
    chmod a-w p.txt
    check "FAT: chmod a-w" "--" "$(w_of p.txt)"
    chmod 600 p.txt
    check "FAT: chmod 600 (a write bit: writable)" "-w" "$(w_of p.txt)"
    chmod -R 444 pd
    check "FAT: chmod -R" "--" "$(w_of pd/a.txt)"
    chmod -R 755 pd
    check "FAT: chmod -R back" "-w" "$(w_of pd/a.txt)"
    check "FAT: folders" "dw" "$(w_of pd)"
    status "FAT: chown refused (no owners)" 1 chown 1000 p.txt
else
    chmod 600 p.txt
    check "chmod 600" "-rw-------" "$(mode_of p.txt)"
    chmod 644 p.txt
    chmod u+x,go-r p.txt
    check "chmod u+x,go-r" "-rwx------" "$(mode_of p.txt)"
    chmod a=r p.txt
    check "chmod a=r" "-r--r--r--" "$(mode_of p.txt)"
    status "writing a file without write bits refused" 1 cp y.txt p.txt
    chmod 4755 p.txt
    check "chmod 4755 (setuid)" "-rwsr-xr-x" "$(mode_of p.txt)"
    chmod 1777 pd
    check "chmod 1777 on a folder (sticky)" "drwxrwxrwt" "$(mode_of pd)"
    chmod -R 750 pd
    check "chmod -R 750" "drwxr-x--- -rwxr-x---" "$(mode_of pd) $(mode_of pd/a.txt)"
    status "chmod 9999 refused" 1 chmod 9999 p.txt
    status "chmod with a bad symbol refused" 1 chmod u+q p.txt
    chown 1000:100 p.txt
    check "chown 1000:100" "1000 100" "$(owner_of p.txt)"
    chown :200 p.txt
    check "chown :200 (group only)" "1000 200" "$(owner_of p.txt)"
    # Minix keeps 16-bit owners; ext2 32-bit:
    if [ "${FSTYPE#ext}" != "$FSTYPE" ]; then
        chown 70000 p.txt
        check "chown above 65535" "70000 200" "$(owner_of p.txt)"
    else
        status "chown above 65535 refused (16-bit owners)" 1 chown 70000 p.txt
    fi
    chown -R 5:6 pd
    check "chown -R" "5 6 5 6" "$(owner_of pd) $(owner_of pd/a.txt)"
    chown 0:0 p.txt
    chmod 644 p.txt
    chmod -R 755 pd
fi
status "chmod of a missing file" 1 chmod 644 none.txt
status "chown of a missing file" 1 chown 0 none.txt

module "find, xargs"

mkdir -p fx/a/b fx/skip
touch fx/one.c fx/a/two.c fx/a/b/three.h fx/skip/four.c fx/A.C
check "find -name" "fx/a/two.c fx/one.c fx/skip/four.c" "$(find fx -name '*.c' | sort | tr_join2)"
check "find -iname" "4" "$(find fx -iname '*.c' | wc -l | awk '{ print $1 }')"
check "find -type d" "fx fx/a fx/a/b fx/skip" "$(find fx -type d | sort | tr_join2)"
check "find -prune -o" "fx/A.C fx/a/two.c fx/one.c" "$(find fx -name skip -prune -o -type f -iname '*.c' -print | sort | tr_join2)"
check "find ( -o ) and !" "fx/a/b/three.h" "$(find fx \( -name '*.c' -o -name '*.C' \) -o -type f -print)"
check "find ! -name" "fx/a/b/three.h" "$(find fx -type f ! -iname '*.c')"
check "find -maxdepth" "fx/A.C fx/one.c" "$(find fx -maxdepth 1 -type f | sort | tr_join2)"
check "find -exec" "fx/a/b/three.h" "$(find fx -name '*.h' -exec echo {} \;)"
check "find -exec +" "2" "$(find fx -maxdepth 1 -type f -exec echo {} + | wc -w | awk '{ print $1 }')"
check "find -print0 | xargs -0" "fx/a/b/three.h" "$(find fx -name '*.h' -print0 | xargs -0 echo)"
check "xargs" "a b c" "$(printf 'a\nb c\n' | xargs echo)"
check "xargs -n" "a,b,c," "$(printf 'a b c' | xargs -n 1 printf '%s,')"
check "xargs -I" "<a> <b>" "$(printf 'a\nb\n' | xargs -I % echo '<%>' | tr_join2)"
check "xargs quotes" "2" "$(echo "'a b' c" | xargs -n 1 echo | wc -l | awk '{ print $1 }')"
check "xargs -r on nothing" "" "$(printf '' | xargs -r echo ran)"
check "xargs runs awk" "3" "$(find fx -iname '*.c' -print0 | xargs -0 awk 'END { print NR + 3 }')"

module "basename, dirname, xxd, date, sleep, df"

check "basename" "file.txt" "$(basename /a/b/file.txt)"
check "basename suffix" "file" "$(basename /a/b/file.txt .txt)"
check "basename /" "/" "$(basename /)"
check "dirname" "/a/b" "$(dirname /a/b/file.txt)"
check "dirname plain" "." "$(dirname file.txt)"
printf 'ABCD' > hex.bin
check "xxd" "00000000: 4142 4344                                ABCD" "$(xxd hex.bin)"
check "xxd -g 1" "00000000: 41 42 43 44" "$(xxd -g 1 hex.bin | cut -c 1-21)"
check "xxd -s -l" "00000002: 43" "$(xxd -g 1 -s 2 -l 1 hex.bin | cut -c 1-12)"
check "xxd of a pipe" "41" "$(printf 'A' | xxd | cut -c 11-12)"
check "date +%Y" "4" "$(date +%Y | awk '{ print length }')"
status "date" 0 date
status "sleep 0" 0 sleep 0
status "df" 0 df

module "awk"

printf 'alice 30 london\nbob 25 paris\ncarol 35 london\n' > people.txt
check "fields" "alice 30" "$(awk '{ print $1, $2 }' people.txt | head -n 1)"
check "pattern" "carol" "$(awk '$2 > 30 { print $1 }' people.txt)"
check "regex pattern" "bob" "$(awk '/paris/ { print $1 }' people.txt)"
check "BEGIN END NR" "3" "$(awk 'END { print NR }' people.txt)"
check "sum" "90" "$(awk '{ s += $2 } END { print s }' people.txt)"
check "arrays and for in" "2 1" "$(awk '{ n[$3]++ } END { print n["london"], n["paris"] }' people.txt)"
check "-F" "b" "$(echo a:b:c | awk -F: '{ print $2 }')"
check "-v" "6" "$(awk -v x=3 'BEGIN { print x * 2 }')"
check "NF \$NF" "3 london" "$(awk 'NR == 1 { print NF, $NF }' people.txt)"
check "printf" "  3|abc  |07" "$(awk 'BEGIN { printf "%3d|%-5s|%02d\n", 3, "abc", 7 }')"
check "string functions" "5 ell 2 HI" "$(awk 'BEGIN { s = "hello"; print length(s), substr(s, 2, 3), index(s, "e"), toupper("hi") }')"
check "split" "3 b" "$(awk 'BEGIN { n = split("a,b,c", p, ","); print n, p[2] }')"
check "sub gsub" "heLl0 w0rld 2" "$(awk 'BEGIN { s = "hello world"; sub(/l/, "L", s); n = gsub(/o/, "0", s); print s, n }')"
check "match" "3 2" "$(awk 'BEGIN { match("aabba", /bb/); print RSTART, RLENGTH }')"
check "functions" "8" "$(awk 'function pow2(n) { return n == 0 ? 1 : 2 * pow2(n - 1) } BEGIN { print pow2(3) }')"
check "array argument" "3" "$(awk 'function fill(a) { a[1]; a[2]; a[3] } BEGIN { fill(x); print length(x) }')"
check "if while for" "6 3" "$(awk 'BEGIN { for (i = 1; i <= 3; i++) s += i; while (j < 3) j++; if (s > 5) print s, j }')"
check "range" "bob carol" "$(awk '/bob/,/carol/ { print $1 }' people.txt | tr_join2)"
check "next" "bob" "$(awk 'NR == 1 { next } { print $1; exit }' people.txt)"
check "exit code" "3" "$(awk 'BEGIN { exit 3 }'; echo $?)"
check "assign field" "alice X london" "$(awk 'NR == 1 { $2 = "X"; print }' people.txt)"
check "OFS" "a-b" "$(echo 'a b' | awk 'BEGIN { OFS = "-" } { $1 = $1; print }')"
check "getline from command" "hi" "$(awk 'BEGIN { "echo hi" | getline x; print x }')"
check "getline from file" "alice 30 london" "$(awk 'BEGIN { getline l < "people.txt"; print l }')"
check "print to command" "a b" "$(awk 'BEGIN { print "b" | "sort"; print "a" | "sort"; close("sort") }' | tr_join2)"
check "print to file" "x" "$(awk 'BEGIN { print "x" > "aw.txt" }'; cat aw.txt)"
check "system" "sys 0" "$(awk 'BEGIN { r = system("echo sys"); print r }' | tr_join2)"
check "ENVIRON" "env" "$(export AWK_DEMO=env; awk 'BEGIN { print ENVIRON["AWK_DEMO"] }')"
check "ARGV" "2 people.txt" "$(awk 'BEGIN { print ARGC, ARGV[1] }' people.txt)"
check "NAME=value operand" "v1" "$(echo x | awk '{ print v }' v=v1)"
check "comparison numbers vs strings" "1 0" "$(echo '10 9' | awk '{ print ($1 > $2), ("10" > "9") }')"
check "number output" "0.333333 1000000 3 1e+20" "$(awk 'BEGIN { print 1/3, 1000000 * 1, 3.0, 1e20 }')"
check "-f program file" "ok" "$(echo 'BEGIN { print "ok" }' > p.awk; awk -f p.awk)"
check "uninitialized" "0 []" "$(awk 'BEGIN { print x + 0, "[" x "]" }')"
check "regex dynamic" "1" "$(awk 'BEGIN { r = "^a.c$"; print ("abc" ~ r) }')"
check "in" "1 0" "$(awk 'BEGIN { a["k"]; print ("k" in a), ("z" in a) }')"
check "delete" "0" "$(awk 'BEGIN { a[1]; a[2]; delete a; print length(a) }')"
check "RS paragraph" "2" "$(printf 'a\nb\n\nc\n' | awk 'BEGIN { RS = "" } END { print NR }')"
check "syntax error is 2" "2" "$(awk 'BEGIN { print ( }' 2>/dev/null; echo $?)"

module "sed"

printf 'one\ntwo\nthree\nfour\nfive\n' > s.txt
printf 'name=Alice\nage=30\n' > kv.txt
check "s" "One" "$(sed -n '1s/o/O/p' s.txt)"
check "s///g" "a-b-c" "$(echo 'a b c' | sed 's/ /-/g')"
check "s///2" "aXa" "$(echo aaa | sed 's/a/X/2' | sed 's/a$/a/')"
check "& in replacement" "[two]" "$(sed -n '2s/.*/[&]/p' s.txt)"
check "BRE groups" "Alice=name" "$(sed -n '1s/\(.*\)=\(.*\)/\2=\1/p' kv.txt)"
check "-E groups" "30:age" "$(sed -nE '2s/(.*)=(.*)/\2:\1/p' kv.txt)"
check "s///I" "xAx" "$(echo aAa | sed 's/A/x/I' | sed 's/a$/x/')"
check "empty match, g" "-a-b-" "$(echo ab | sed 's/x*/-/g')"
check "\$ alone" "one," "$(sed -n '1s/$/,/p' s.txt)"
check "\\n in replacement" "2" "$(echo a,b | sed 's/,/\n/' | wc -l | awk '{ print $1 }')"
check "-n and p" "three" "$(sed -n 3p s.txt)"
check "\$ address" "five" "$(sed -n '$p' s.txt)"
check "range" "two three four" "$(sed -n '2,4p' s.txt | tr_join2)"
check "regex range" "two three" "$(sed -n '/tw/,/th/p' s.txt | tr_join2)"
check "first~step" "one three five" "$(sed -n '1~2p' s.txt | tr_join2)"
check "addr,+N" "two three" "$(sed -n '/two/,+1p' s.txt | tr_join2)"
check "! negates" "two four" "$(sed '1~2d' s.txt | tr_join2)"
check "d" "two four" "$(sed '/e$/d' s.txt | tr_join2)"
check "q" "one two" "$(sed 2q s.txt | tr_join2)"
status "q exit code" 5 sed q5 s.txt
check "{ } block" "TWO" "$(sed -n '/two/{s/two/TWO/;p}' s.txt)"
check "y" "ONE" "$(sed -n '1y/one/ONE/;1p' s.txt)"
check "a i c" "> one < X" "$(printf 'one\ntwo\n' | sed '1i >' | sed '2a <' | sed '$c X' | tr_join2)"
check "=" "5" "$(sed -n '$=' s.txt)"
check "N and P;D" "one+two" "$(sed -n '1{N;s/\n/+/;p}' s.txt)"
check "hold space: reverse" "five four three two one" "$(sed '1!G;h;$!d' s.txt | tr_join2)"
check "join all lines" "one,two,three,four,five" "$(sed ':a;N;$!ba;s/\n/,/g' s.txt)"
check "t loop" "a-b-c-d" "$(echo abcd | sed -E ':x;s/([a-z])([a-z])($|[^-])/\1-\2\3/;tx')"
check "-e twice" "2" "$(printf '1\n2\n3\n' | sed -e 1d -e 3d)"
echo 's/one/ONE/' > edit.sed
check "-f" "ONE" "$(sed -n -f edit.sed -e 1p s.txt)"
cp s.txt e.txt
sed -i 's/two/2/' e.txt
check "-i" "2" "$(sed -n 2p e.txt)"
sed -i.bak 's/three/3/' e.txt
check "-i.bak keeps the original" "three 3" "$(sed -n 3p e.txt.bak) $(sed -n 3p e.txt)"
check "w file" "two" "$(sed -n '/two/w w.txt' s.txt; cat w.txt)"
check "\\s and \\w" "a_b-c" "$(echo 'a b-c' | sed 's/\s/_/')"
status "back-reference in a pattern is refused" 1 sed 's/\(a\)\1/x/' s.txt
status "unknown command" 1 sed k s.txt

module "scripts"

printf 'echo "args $# $1"\nexit 4\n' > s1.sh
chmod +x s1.sh
check "run a script by path" "args 1 x" "$(./s1.sh x)"
./s1.sh > /dev/null
check "script exit code" "4" "$?"
printf '#!/C:/APPS/ASH.APP\necho shebang\n' > s2.sh
chmod +x s2.sh
check "ash shebang" "shebang" "$(./s2.sh)"
printf '#!/usr/bin/env bash\necho bash script\n' > s3.sh
chmod +x s3.sh
check "bash shebang runs in ash" "bash script" "$(./s3.sh)"
printf 'INNER=set\nexport INNER_EXPORT=x\n' > s4.sh
chmod +x s4.sh
./s4.sh
check "script variables stay inside" "" "$INNER$INNER_EXPORT"
export OUTER_FOR_SCRIPT=seen
printf 'echo $OUTER_FOR_SCRIPT $NOT_EXPORTED\n' > s5.sh
chmod +x s5.sh
NOT_EXPORTED=no
check "scripts see exported variables" "seen" "$(./s5.sh)"
printf 'f() { echo in-f; }\n' > s6.sh
check "script by name without .sh" "args 0 " "$(./s1 2>/dev/null)"
printf 'echo "$0"\n' > s7.sh
chmod +x s7.sh
check "\$0 of a script" "./s7.sh" "$(./s7.sh)"
printf 'if true\nthen echo ok\n' > bad.sh
chmod +x bad.sh
check "syntax error ends a script" "2" "$(./bad.sh 2>/dev/null; echo $?)"

finish
cd ..
rm -r "$T"
if [ -e "$T" ]; then
    echo "[Fail] cleanup: $T is still there"
    FAILED=$((FAILED + 1))
fi
echo
if [ "$FAILED" -eq 0 ]; then
    echo "All $PASSED tests passed"
    exit 0
fi
echo "$PASSED passed, $FAILED failed"
exit 1
