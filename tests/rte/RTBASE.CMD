@ECHO OFF
REM RTLAT baselines: alone, disk copies, DEMO graphics, HTTPZ traffic, all.
REM   X:\RTBASE.CMD X THREADS rgb|gfx LOOPS   (X: the NETLOG drive)
REM DEMO is ended by the host's key on GFX*.STOP; HTTPZ runs to the end.
%1:
CD \
ECHO threads %2 gfx %3 loops %4 drive %1 > RTBASE.LOG
IF NOT EXIST C:\RTCOPY MD C:\RTCOPY
IF EXIST STOPDISK DEL -q STOPDISK

ECHO idle >> RTBASE.LOG
RTLAT -t %2 -a 0 -i 1000 -l %4 -h 100 -q > RT-IDLE.TXT
ECHO idle %ERRORLEVEL% >> RTBASE.LOG

ASH -c "while [ ! -f /%1:/STOPDISK ]; do cp /%1:/BIG.BIN /C:/RTCOPY/A.BIN; cp /C:/RTCOPY/A.BIN /C:/RTCOPY/B.BIN; rm -f /C:/RTCOPY/A.BIN; echo x >> /%1:/COPIES1.TXT; done" > DISKERR1.TXT &
ASH -c "sleep 2"
RTLAT -t %2 -a 0 -i 1000 -l %4 -h 100 -q > RT-DISK.TXT
ECHO disk %ERRORLEVEL% >> RTBASE.LOG
ECHO stop > STOPDISK
WAIT
DEL -q STOPDISK

IF "%3" == "rgb" (
    DEMO rgb 1 &
) ELSE (
    DEMO gfx &
)
ASH -c "sleep 2"
RTLAT -t %2 -a 0 -i 1000 -l %4 -h 100 -q > RT-GFX.TXT
ECHO gfx %ERRORLEVEL% >> RTBASE.LOG
ECHO stop > GFX1.STOP
WAIT
ASH -c "sleep 1"

HTTPZ > HTTPZOUT.TXT &
ECHO go > H1.GO
REM The host asks for /loadstart once its clients run
ASH -c "i=0; until grep -q loadstart /C:/DATA/LOGS/httpz.log || [ $i -ge 90 ]; do sleep 1; i=$((i + 1)); done; echo http waited $i >> /%1:/RTBASE.LOG"
ASH -c "sleep 3"
RTLAT -t %2 -a 0 -i 1000 -l %4 -h 100 -q > RT-HTTP.TXT
ECHO http %ERRORLEVEL% >> RTBASE.LOG
ECHO end > H1.END
ASH -c "sleep 2"

ASH -c "while [ ! -f /%1:/STOPDISK ]; do cp /%1:/BIG.BIN /C:/RTCOPY/A.BIN; cp /C:/RTCOPY/A.BIN /C:/RTCOPY/B.BIN; rm -f /C:/RTCOPY/A.BIN; echo x >> /%1:/COPIES2.TXT; done" > DISKERR2.TXT &
IF "%3" == "rgb" (
    DEMO rgb 1 &
) ELSE (
    DEMO gfx &
)
ECHO go > H2.GO
ASH -c "sleep 8"
RTLAT -t %2 -a 0 -i 1000 -l %4 -h 100 -q > RT-ALL.TXT
ECHO all %ERRORLEVEL% >> RTBASE.LOG
ECHO end > H2.END
ECHO stop > STOPDISK
ECHO stop > GFX2.STOP
ASH -c "sleep 3"
PS > PS.TXT
DEL -q C:\RTCOPY
ECHO done > RTBASE.END
