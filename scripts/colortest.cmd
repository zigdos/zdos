@ECHO OFF
REM ANSI color test: ESC [ ... m sequences in ECHO and TYPE.
REM The ESC characters in this file are real ESC bytes (0x1B).
ECHO Foreground colors 30-37:
ECHO [30;47mblack[0m [31mred[0m [32mgreen[0m [33myellow[0m [34mblue[0m [35mmagenta[0m [36mcyan[0m [37mwhite[0m
ECHO Bright foreground colors 90-97:
ECHO [90mblack[0m [91mred[0m [92mgreen[0m [93myellow[0m [94mblue[0m [95mmagenta[0m [96mcyan[0m [97mwhite[0m
ECHO Bold (1) makes 30-37 bright:
ECHO [1;30mblack[0m [1;31mred[0m [1;32mgreen[0m [1;33myellow[0m [1;34mblue[0m [1;35mmagenta[0m [1;36mcyan[0m [1;37mwhite[0m
ECHO Backgrounds 40-47:
ECHO [40m black [0m [41m red [0m [42m green [0m [43m yellow [0m [44m blue [0m [45m magenta [0m [46m cyan [0m [30;47m white [0m
ECHO Bright backgrounds 100-107 (shown as 40-47):
ECHO [100m black [0m [101m red [0m [102m green [0m [103m yellow [0m [104m blue [0m [105m magenta [0m [106m cyan [0m [30;107m white [0m
ECHO Reverse (7): [31;7m red reversed [27m back to red[0m
ECHO Defaults (39, 49): [33;44m yellow on blue [39m default text [49m default background[0m
ECHO 256 colors (38;5 / 48;5): [38;5;196mred [38;5;46mgreen [38;5;21mblue [38;5;226myellow [38;5;244mgray [30;48;5;51m cyan background [0m
ECHO RGB (38;2): [38;2;255;128;0morange [38;2;128;0;255mpurple [38;2;255;255;255mwhite[0m
ECHO Other sequences are dropped: [[2K[?25h(B] (nothing between the brackets)
ECHO In a file the codes are kept; TYPE shows the colors again:
ECHO [92mThis line went through a file.[0m > COLORTST.TXT
TYPE COLORTST.TXT
DEL COLORTST.TXT
ECHO [0mColors reset. End of the color test.
