@ECHO OFF
REM ==========================================================================
REM DEMOB.CMD - self test for the batch interpreter.
REM Prints [OK] name for each passing test and [FAIL] name for each failure.
REM Run it as a file (TEST or DEMOB.CMD) so that %0 can be used to call itself.
REM
REM Assumptions about the rest of the system (not defined in batch.zig):
REM   ECHO, MD, RD, DEL, CHOICE, PATH exist; > and >> redirection works.
REM Do not press keys while it runs (one CHOICE test waits about a second).
REM Do not use parentheses inside test names: they end blocks early.
REM ==========================================================================

REM ---- Child mode: this file calls itself with --child to test arguments,
REM ---- SHIFT, EXIT codes and variable scopes. Its exit code is its failures.
IF "%1" == "--child" (
    SET -a FAILS=0

    IF "%2" == "args" (
        IF "%4" == "5" (ECHO [OK] child: quoted argument counts as one) ELSE (
            ECHO [FAIL] child: quoted argument counts as one
            SET -a FAILS+=1
        )
        IF "%5" == "" (ECHO [OK] child: missing argument is empty) ELSE (
            ECHO [FAIL] child: missing argument is empty
            SET -a FAILS+=1
        )
        IF NOT "%0" == "" (ECHO [OK] child: %%0 is not empty) ELSE (
            ECHO [FAIL] child: %%0 is not empty
            SET -a FAILS+=1
        )
        SET -a R=%4*2
        IF "%R%" == "10" (ECHO [OK] child: arithmetic with %%4) ELSE (
            ECHO [FAIL] child: arithmetic with %%4
            SET -a FAILS+=1
        )
        SET -a R=%4%%3
        IF "%R%" == "2" (ECHO [OK] child: remainder after %%4) ELSE (
            ECHO [FAIL] child: remainder after %%4
            SET -a FAILS+=1
        )
        EXIT %FAILS%
    )

    IF "%2" == "shift" (
        IF "%*" == "--child shift x y" (ECHO [OK] child: all arguments before SHIFT) ELSE (
            ECHO [FAIL] child: all arguments before SHIFT
            SET -a FAILS+=1
        )
        SHIFT
        IF "%1" == "shift" (ECHO [OK] SHIFT moves %%2 to %%1) ELSE (
            ECHO [FAIL] SHIFT moves %%2 to %%1
            SET -a FAILS+=1
        )
        IF "%2" == "x" (ECHO [OK] SHIFT moves %%3 to %%2) ELSE (
            ECHO [FAIL] SHIFT moves %%3 to %%2
            SET -a FAILS+=1
        )
        IF "%0" == "--child" (ECHO [OK] SHIFT moves %%1 to %%0) ELSE (
            ECHO [FAIL] SHIFT moves %%1 to %%0
            SET -a FAILS+=1
        )
        EXIT %FAILS%
    )

    IF "%2" == "exit7" EXIT 7

    IF "%2" == "scope" (
        IF NOT DEFINED PARENTVAR EXIT 1
        SET CHILDVAR=1
        SET PARENTVAR=changed
        EXIT 0
    )
    EXIT 99
)

SET -a FAILS=0

ECHO ** Variables **

SET NAME=value
IF "%NAME%" == "value" (ECHO [OK] SET and expand a variable) ELSE (
    ECHO [FAIL] SET and expand a variable
    SET -a FAILS+=1
)

SET "Q=quoted"
IF "%Q%" == "quoted" (ECHO [OK] SET with quotes around NAME=value) ELSE (
    ECHO [FAIL] SET with quotes around NAME=value
    SET -a FAILS+=1
)

SET SP=a b
IF "%SP%" == "a b" (ECHO [OK] value with a space) ELSE (
    ECHO [FAIL] value with a space
    SET -a FAILS+=1
)

IF "%NOSUCHVAR%" == "" (ECHO [OK] unknown variable is empty) ELSE (
    ECHO [FAIL] unknown variable is empty
    SET -a FAILS+=1
)

IF DEFINED NAME (ECHO [OK] IF DEFINED on a set variable) ELSE (
    ECHO [FAIL] IF DEFINED on a set variable
    SET -a FAILS+=1
)

IF NOT DEFINED NOSUCHVAR (ECHO [OK] IF NOT DEFINED on an unknown variable) ELSE (
    ECHO [FAIL] IF NOT DEFINED on an unknown variable
    SET -a FAILS+=1
)

SET GONE=x
SET GONE=
IF NOT DEFINED GONE (ECHO [OK] SET NAME= removes the variable) ELSE (
    ECHO [FAIL] SET NAME= removes the variable
    SET -a FAILS+=1
)

SET P=100%%
IF "%P%" == "100%%" (ECHO [OK] doubled percent is one percent) ELSE (
    ECHO [FAIL] doubled percent is one percent
    SET -a FAILS+=1
)

SET A1=x
SET B1=y
IF "%A1%%B1%" == "xy" (ECHO [OK] two variables side by side) ELSE (
    ECHO [FAIL] two variables side by side
    SET -a FAILS+=1
)

REM SET BAD1=1
# SET BAD2=1
IF NOT DEFINED BAD1 IF NOT DEFINED BAD2 SET COMMENTS=ok
IF "%COMMENTS%" == "ok" (ECHO [OK] REM and # lines do nothing) ELSE (
    ECHO [FAIL] REM and # lines do nothing
    SET -a FAILS+=1
)

SET OLDPATH=%PATH%
PATH C:\TESTA;C:\DEMOB
IF "%PATH%" == "C:\TESTA;C:\DEMOB" (ECHO [OK] PATH sets the search path) ELSE (
    ECHO [FAIL] PATH sets the search path
    SET -a FAILS+=1
)
PATH %OLDPATH%

SET V=old
IF 1 EQU 1 (
    SET V=new
    SET W=%V%
)
IF "%W%" == "new" (ECHO [OK] variables are expanded when the command runs) ELSE (
    ECHO [FAIL] variables are expanded when the command runs
    SET -a FAILS+=1
)

ECHO ** IF **

IF abc == abc (ECHO [OK] IF text equal) ELSE (
    ECHO [FAIL] IF text equal
    SET -a FAILS+=1
)

IF NOT abc == abd (ECHO [OK] IF NOT text equal) ELSE (
    ECHO [FAIL] IF NOT text equal
    SET -a FAILS+=1
)

IF NOT "ABC" == "abc" (ECHO [OK] text comparison is case sensitive) ELSE (
    ECHO [FAIL] text comparison is case sensitive
    SET -a FAILS+=1
)

IF -i "ABC" == "abc" (ECHO [OK] IF -i ignores case) ELSE (
    ECHO [FAIL] IF -i ignores case
    SET -a FAILS+=1
)

IF "a" != "b" (ECHO [OK] IF not equal symbol) ELSE (
    ECHO [FAIL] IF not equal symbol
    SET -a FAILS+=1
)

IF 5 EQU 5 (ECHO [OK] EQU) ELSE (
    ECHO [FAIL] EQU
    SET -a FAILS+=1
)

IF 5 NEQ 6 (ECHO [OK] NEQ) ELSE (
    ECHO [FAIL] NEQ
    SET -a FAILS+=1
)

IF 9 LSS 10 (ECHO [OK] LSS compares numbers not text) ELSE (
    ECHO [FAIL] LSS compares numbers not text
    SET -a FAILS+=1
)

IF 10 GTR 9 (ECHO [OK] GTR compares numbers) ELSE (
    ECHO [FAIL] GTR compares numbers
    SET -a FAILS+=1
)

IF 10 LEQ 10 (ECHO [OK] LEQ) ELSE (
    ECHO [FAIL] LEQ
    SET -a FAILS+=1
)

IF 10 GEQ 10 (ECHO [OK] GEQ) ELSE (
    ECHO [FAIL] GEQ
    SET -a FAILS+=1
)

IF -3 LSS 2 (ECHO [OK] negative numbers compare) ELSE (
    ECHO [FAIL] negative numbers compare
    SET -a FAILS+=1
)

IF 3 < 10 (ECHO [OK] symbol less than) ELSE (
    ECHO [FAIL] symbol less than
    SET -a FAILS+=1
)

IF 10 >= 10 (ECHO [OK] symbol greater or equal) ELSE (
    ECHO [FAIL] symbol greater or equal
    SET -a FAILS+=1
)

IF abc LSS abd (ECHO [OK] text less than) ELSE (
    ECHO [FAIL] text less than
    SET -a FAILS+=1
)

IF a==a (ECHO [OK] operator without blanks) ELSE (
    ECHO [FAIL] operator without blanks
    SET -a FAILS+=1
)

IF Hello!==Hello! (ECHO [OK] operand containing an exclamation mark) ELSE (
    ECHO [FAIL] operand containing an exclamation mark
    SET -a FAILS+=1
)

SET R=
IF 1 EQU 2 SET R=a ELSE SET R=b
IF "%R%" == "b" (ECHO [OK] one line IF ELSE) ELSE (
    ECHO [FAIL] one line IF ELSE
    SET -a FAILS+=1
)

SET R=
IF 1 EQU 1 (SET R=x) ELSE (SET R=y)
IF "%R%" == "x" (ECHO [OK] one line IF with parentheses) ELSE (
    ECHO [FAIL] one line IF with parentheses
    SET -a FAILS+=1
)

SET -a N=15
SET R=
IF %N% LSS 10 (
    SET R=small
) ELSE IF %N% LSS 20 (
    SET R=medium
) ELSE (
    SET R=large
)
IF "%R%" == "medium" (ECHO [OK] ELSE IF chain) ELSE (
    ECHO [FAIL] ELSE IF chain
    SET -a FAILS+=1
)

SET R=
IF 1 EQU 1 (
    IF 2 EQU 3 (
        SET R=wrong
    ) ELSE (
        SET R=inner
    )
)
IF "%R%" == "inner" (ECHO [OK] nested IF blocks) ELSE (
    ECHO [FAIL] nested IF blocks
    SET -a FAILS+=1
)

SET R=
IF 1 EQU 1 IF 2 EQU 2 SET R=both
IF "%R%" == "both" (ECHO [OK] IF directly inside IF) ELSE (
    ECHO [FAIL] IF directly inside IF
    SET -a FAILS+=1
)

ECHO ** Arithmetic **

SET -a R=2+3*4
IF "%R%" == "14" (ECHO [OK] precedence) ELSE (
    ECHO [FAIL] precedence
    SET -a FAILS+=1
)

SET -a R=(2+3)*4
IF "%R%" == "20" (ECHO [OK] parentheses) ELSE (
    ECHO [FAIL] parentheses
    SET -a FAILS+=1
)

SET -a R=10/3
IF "%R%" == "3" (ECHO [OK] division) ELSE (
    ECHO [FAIL] division
    SET -a FAILS+=1
)

SET -a R=-10/3
IF "%R%" == "-3" (ECHO [OK] division truncates toward zero) ELSE (
    ECHO [FAIL] division truncates toward zero
    SET -a FAILS+=1
)

SET -a R=10%3
IF "%R%" == "1" (ECHO [OK] remainder with one percent) ELSE (
    ECHO [FAIL] remainder with one percent
    SET -a FAILS+=1
)

SET -a R=10%%3
IF "%R%" == "1" (ECHO [OK] remainder with doubled percent) ELSE (
    ECHO [FAIL] remainder with doubled percent
    SET -a FAILS+=1
)

SET -a R=-7%3
IF "%R%" == "-1" (ECHO [OK] remainder takes the sign of the left side) ELSE (
    ECHO [FAIL] remainder takes the sign of the left side
    SET -a FAILS+=1
)

SET -a R=-5+2
IF "%R%" == "-3" (ECHO [OK] unary minus) ELSE (
    ECHO [FAIL] unary minus
    SET -a FAILS+=1
)

SET -a R=-(2+3)
IF "%R%" == "-5" (ECHO [OK] unary minus on parentheses) ELSE (
    ECHO [FAIL] unary minus on parentheses
    SET -a FAILS+=1
)

SET -a R=+4
IF "%R%" == "4" (ECHO [OK] unary plus) ELSE (
    ECHO [FAIL] unary plus
    SET -a FAILS+=1
)

SET -a N=5
SET -a N+=2
IF "%N%" == "7" (ECHO [OK] += ) ELSE (
    ECHO [FAIL] +=
    SET -a FAILS+=1
)
SET -a N-=3
IF "%N%" == "4" (ECHO [OK] -= ) ELSE (
    ECHO [FAIL] -=
    SET -a FAILS+=1
)
SET -a N*=3
IF "%N%" == "12" (ECHO [OK] *= ) ELSE (
    ECHO [FAIL] *=
    SET -a FAILS+=1
)
SET -a N/=4
IF "%N%" == "3" (ECHO [OK] /= ) ELSE (
    ECHO [FAIL] /=
    SET -a FAILS+=1
)
SET -a N%=2
IF "%N%" == "1" (ECHO [OK] %%= ) ELSE (
    ECHO [FAIL] %%=
    SET -a FAILS+=1
)

SET -a A=1, B=A*2, C=A+B
IF "%C%" == "3" (ECHO [OK] comma separated assignments see earlier ones) ELSE (
    ECHO [FAIL] comma separated assignments see earlier ones
    SET -a FAILS+=1
)

SET X=7
SET -a R=%X%+1
IF "%R%" == "8" (ECHO [OK] %%NAME%% inside an expression) ELSE (
    ECHO [FAIL] %%NAME%% inside an expression
    SET -a FAILS+=1
)

SET T=abc
SET -a R=T+1
IF "%R%" == "1" (ECHO [OK] non numeric variable counts as zero) ELSE (
    ECHO [FAIL] non numeric variable counts as zero
    SET -a FAILS+=1
)

SET -a R=NOSUCHVAR+1
IF "%R%" == "1" (ECHO [OK] unset variable counts as zero) ELSE (
    ECHO [FAIL] unset variable counts as zero
    SET -a FAILS+=1
)

SET -a R=9223372036854775807
IF "%R%" == "9223372036854775807" (ECHO [OK] largest 64 bit number) ELSE (
    ECHO [FAIL] largest 64 bit number
    SET -a FAILS+=1
)

SET -a R=-9223372036854775808
IF "%R%" == "-9223372036854775808" (ECHO [OK] smallest 64 bit number) ELSE (
    ECHO [FAIL] smallest 64 bit number
    SET -a FAILS+=1
)

ECHO (two error messages follow, they are expected)
SET -a Z=1
SET -a Z=1/0
IF "%Z%" == "1" (ECHO [OK] division by zero leaves the variable alone) ELSE (
    ECHO [FAIL] division by zero leaves the variable alone
    SET -a FAILS+=1
)
SET -a Z=9223372036854775807+1
IF "%Z%" == "1" (ECHO [OK] overflow leaves the variable alone) ELSE (
    ECHO [FAIL] overflow leaves the variable alone
    SET -a FAILS+=1
)

ECHO ** FOR **

SET S=
FOR %%i IN (a b c) DO SET S=%S%%%i
IF "%S%" == "abc" (ECHO [OK] FOR over a list) ELSE (
    ECHO [FAIL] FOR over a list
    SET -a FAILS+=1
)

SET S=
FOR %%i IN (a,b;c) DO SET S=%S%%%i
IF "%S%" == "abc" (ECHO [OK] FOR list separators) ELSE (
    ECHO [FAIL] FOR list separators
    SET -a FAILS+=1
)

SET -a N=0
FOR %%i IN ("a b" c) DO SET -a N+=1
IF "%N%" == "2" (ECHO [OK] quoted FOR item stays whole) ELSE (
    ECHO [FAIL] quoted FOR item stays whole
    SET -a FAILS+=1
)

SET S=
FOR %%i IN (1 2 3 4) DO IF %%i GTR 2 SET S=%S%%%i
IF "%S%" == "34" (ECHO [OK] FOR variable inside IF) ELSE (
    ECHO [FAIL] FOR variable inside IF
    SET -a FAILS+=1
)

SET S=
FOR %%a IN (1 2) DO FOR %%b IN (x y) DO SET S=%S%%%a%%b
IF "%S%" == "1x1y2x2y" (ECHO [OK] nested FOR) ELSE (
    ECHO [FAIL] nested FOR
    SET -a FAILS+=1
)

SET S=
FOR %%i IN (a b) DO (
    SET S=%S%%%i
    SET S=%S%-
)
IF "%S%" == "a-b-" (ECHO [OK] FOR with a block body) ELSE (
    ECHO [FAIL] FOR with a block body
    SET -a FAILS+=1
)

SET S=
FOR -L %%i IN (1,1,5) DO SET S=%S%%%i
IF "%S%" == "12345" (ECHO [OK] FOR -L counting up) ELSE (
    ECHO [FAIL] FOR -L counting up
    SET -a FAILS+=1
)

SET S=
FOR -L %%i IN (10,-5,0) DO SET S=%S%%%i
IF "%S%" == "1050" (ECHO [OK] FOR -L counting down) ELSE (
    ECHO [FAIL] FOR -L counting down
    SET -a FAILS+=1
)

SET -a N=0
FOR -L %%i IN (5,1,1) DO SET -a N+=1
IF "%N%" == "0" (ECHO [OK] FOR -L with nothing to do) ELSE (
    ECHO [FAIL] FOR -L with nothing to do
    SET -a FAILS+=1
)

SET -a N=0
FOR -L %%i IN (7,0,7) DO (
    SET -a N+=1
    IF %N% GEQ 3 BREAK
)
IF "%N%" == "3" (ECHO [OK] FOR -L with step 0 runs until BREAK) ELSE (
    ECHO [FAIL] FOR -L with step 0 runs until BREAK
    SET -a FAILS+=1
)

SET -a SUM=0
FOR -L %%i IN (1,1,10) DO SET -a SUM+=%%i
IF "%SUM%" == "55" (ECHO [OK] FOR variable as %%i in SET -a) ELSE (
    ECHO [FAIL] FOR variable as %%i in SET -a
    SET -a FAILS+=1
)

SET -a SUM=0
FOR -L %%i IN (1,1,10) DO SET -a SUM+=i
IF "%SUM%" == "55" (ECHO [OK] FOR variable by bare name in SET -a) ELSE (
    ECHO [FAIL] FOR variable by bare name in SET -a
    SET -a FAILS+=1
)

SET -a SUM=0
FOR -L %%i IN (1,1,6) DO SET -a SUM+=%%i%%2
IF "%SUM%" == "3" (ECHO [OK] remainder after a FOR variable) ELSE (
    ECHO [FAIL] remainder after a FOR variable
    SET -a FAILS+=1
)

SET -a N=0
FOR DO (
    SET -a N+=1
    IF %N% GEQ 5 BREAK
)
IF "%N%" == "5" (ECHO [OK] endless FOR with BREAK) ELSE (
    ECHO [FAIL] endless FOR with BREAK
    SET -a FAILS+=1
)

SET -a N=0
FOR %%a IN (1 2 3) DO (
    FOR DO (
        SET -a N+=1
        BREAK
    )
)
IF "%N%" == "3" (ECHO [OK] BREAK leaves only the inner FOR) ELSE (
    ECHO [FAIL] BREAK leaves only the inner FOR
    SET -a FAILS+=1
)

SET S=
FOR -f %%L IN ("some text") DO SET S=%%L
IF "%S%" == "some text" (ECHO [OK] FOR -f with text keeps spaces) ELSE (
    ECHO [FAIL] FOR -f with text keeps spaces
    SET -a FAILS+=1
)

SET S=
FOR -f %%L IN ('ECHO hello') DO SET S=%%L
IF "%S%" == "hello" (ECHO [OK] FOR -f over command output) ELSE (
    ECHO [FAIL] FOR -f over command output
    SET -a FAILS+=1
)

ECHO ** Files **

MD TESTTMP
MD TESTTMP\SUB.TXT
ECHO alpha > TESTTMP\A.TXT
ECHO beta > TESTTMP\B.TXT
ECHO one > TESTTMP\L.DAT
ECHO two >> TESTTMP\L.DAT
ECHO three >> TESTTMP\L.DAT

IF EXIST TESTTMP\A.TXT (ECHO [OK] IF EXIST on a file) ELSE (
    ECHO [FAIL] IF EXIST on a file
    SET -a FAILS+=1
)

IF EXIST TESTTMP (ECHO [OK] IF EXIST on a folder) ELSE (
    ECHO [FAIL] IF EXIST on a folder
    SET -a FAILS+=1
)

IF EXIST TESTTMP\*.TXT (ECHO [OK] IF EXIST with a wildcard) ELSE (
    ECHO [FAIL] IF EXIST with a wildcard
    SET -a FAILS+=1
)

IF NOT EXIST TESTTMP\NOPE.TXT (ECHO [OK] IF NOT EXIST) ELSE (
    ECHO [FAIL] IF NOT EXIST
    SET -a FAILS+=1
)

IF NOT EXIST TESTTMP\*.ZZZ (ECHO [OK] wildcard with no match) ELSE (
    ECHO [FAIL] wildcard with no match
    SET -a FAILS+=1
)

SET -a N=0
FOR %%f IN (TESTTMP\*.TXT) DO SET -a N+=1
IF "%N%" == "2" (ECHO [OK] FOR over files skips folders) ELSE (
    ECHO [FAIL] FOR over files skips folders
    SET -a FAILS+=1
)

SET -a N=0
FOR %%f IN (TESTTMP\*.ZZZ) DO SET -a N+=1
IF "%N%" == "0" (ECHO [OK] FOR wildcard with no match runs zero times) ELSE (
    ECHO [FAIL] FOR wildcard with no match runs zero times
    SET -a FAILS+=1
)

SET S=
FOR %%f IN (TESTTMP\A.TXT) DO SET S=%%f
IF "%S%" == "TESTTMP\A.TXT" (ECHO [OK] FOR over files keeps the folder part) ELSE (
    ECHO [FAIL] FOR over files keeps the folder part
    SET -a FAILS+=1
)

SET S=
FOR -f %%L IN (TESTTMP\L.DAT) DO SET S=%S%%%L
IF "%S%" == "onetwothree" (ECHO [OK] FOR -f over the lines of a file) ELSE (
    ECHO [FAIL] FOR -f over the lines of a file
    SET -a FAILS+=1
)

SET -a N=0
FOR -f %%L IN (TESTTMP\A.TXT TESTTMP\L.DAT) DO SET -a N+=1
IF "%N%" == "4" (ECHO [OK] FOR -f over two files) ELSE (
    ECHO [FAIL] FOR -f over two files
    SET -a FAILS+=1
)

REM -q / -y: DEL and RD ask otherwise
DEL -q TESTTMP\A.TXT
DEL -q TESTTMP\B.TXT
DEL -q TESTTMP\L.DAT
RD -y TESTTMP\SUB.TXT
RD -y TESTTMP
IF NOT EXIST TESTTMP (ECHO [OK] test files cleaned up) ELSE (
    ECHO [FAIL] test files cleaned up
    SET -a FAILS+=1
)

ECHO ** Calling batch files **

CALL %0 --child args "a b" 5
IF NOT ERRORLEVEL 1 (ECHO [OK] child with arguments passed all its tests) ELSE (
    ECHO [FAIL] child with arguments passed all its tests
    SET -a FAILS+=1
)

CALL %0 --child shift x y
IF NOT ERRORLEVEL 1 (ECHO [OK] child with SHIFT passed all its tests) ELSE (
    ECHO [FAIL] child with SHIFT passed all its tests
    SET -a FAILS+=1
)

CALL %0 --child exit7
SET R=none
IF ERRORLEVEL 7 SET R=ge7
IF ERRORLEVEL 8 SET R=ge8
IF "%R%" == "ge7" (ECHO [OK] EXIT code and IF ERRORLEVEL) ELSE (
    ECHO [FAIL] EXIT code and IF ERRORLEVEL
    SET -a FAILS+=1
)

SET PARENTVAR=orig
CALL %0 --child scope
IF NOT ERRORLEVEL 1 (ECHO [OK] child sees the variables of its caller) ELSE (
    ECHO [FAIL] child sees the variables of its caller
    SET -a FAILS+=1
)
IF "%PARENTVAR%" == "orig" (ECHO [OK] child cannot change a variable of its caller) ELSE (
    ECHO [FAIL] child cannot change a variable of its caller
    SET -a FAILS+=1
)
IF NOT DEFINED CHILDVAR (ECHO [OK] variables of a child disappear when it ends) ELSE (
    ECHO [FAIL] variables of a child disappear when it ends
    SET -a FAILS+=1
)

ECHO ** CHOICE **

CHOICE -c YN -t:Y,1 Waiting one second
SET R=none
IF ERRORLEVEL 1 SET R=ge1
IF ERRORLEVEL 2 SET R=ge2
IF "%R%" == "ge1" (ECHO [OK] CHOICE takes the default key after the timeout) ELSE (
    ECHO [FAIL] CHOICE takes the default key after the timeout
    SET -a FAILS+=1
)

ECHO.
IF "%FAILS%" == "0" (
    ECHO All tests passed
) ELSE (
    ECHO %FAILS% tests FAILED
)
EXIT %FAILS%
