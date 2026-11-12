@ECHO OFF
REM COMMAND.APP's startup script: the first COMMAND.APP (started by ZDOS) runs
REM SCRIPTS\AUTOEXEC.CMD beside its folder: C:\SCRIPTS for C:\APPS\COMMAND.APP.
REM Variables set here are global.
REM ZDOS has already set PATH (\APPS on the boot drive),
REM PLATFORM and the settings of \CONF\SYSTEM.CFG.

REM Games (\GAMES on C:) to run from anywhere
PATH %PATH%;C:\GAMES
