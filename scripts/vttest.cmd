@ECHO OFF
REM VT100 test: cursor movement, erasing, save/restore, cursor on/off.
REM Needs TERM=vt100 in \CONF\SYSTEM.CFG. The ESC characters are real ESC bytes.
ECHO TERM is %TERM%
PAUSE
CLS
ECHO [2;10HRow 2, column 10 (ESC[2;10H)
ECHO [4;1H[33mA box drawn with cursor positioning:[0m
ECHO [5;5H+--------------------+
ECHO [6;5H![6;26H!
ECHO [7;5H![7;26H!
ECHO [8;5H![8;26H!
ECHO [9;5H+--------------------+
ECHO [7;8H[92minside the box[0m
ECHO [11;1HErase to end of line: before XXXXXXXXXX[10D[K(erased)
ECHO Erase to start of line: XXXXXXXXXX[1K[30C(erased up to here)
ECHO [44mWhole line erased in blue[2K[0m (line above is blue)
ECHO Save, move away, restore: [s[20;60H(away)[u(back here)
ECHO Up/down/left/right: [2B[3C(down 2, right 3)[3A[25D(up 3, left 25)
ECHO [18;1HNext line ESC[E / ESC[F and column ESC[40G:[E[40G(column 40)
ECHO.
ECHO Cursor hidden now (ESC[?25l):[?25l
PAUSE
ECHO Cursor shown again (ESC[?25h).[?25h
PAUSE
ECHO [2J[HScreen cleared with ESC[2J, cursor home with ESC[H. End of the VT100 test.
