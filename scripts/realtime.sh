#!/C:/APPS/ASH.APP
# realtime.sh [THREADS] [SECONDS] [PRIORITY] [FOLDER]: RTLAT alone,
# then under disk copies, DEMO graphics, HTTP over the loopback, and
# all at once. RTLAT thread n runs on core n (FIFO, 1 ms), at
# PRIORITY 0-31 (28; the task IRQ has IRQPRIO=, 30). FOLDER (default
# C:/RTLAT) may have no spaces: the load loops get it in their command.
threads=${1:-2}
seconds=${2:-60}
prio=${3:-28}
[ "$prio" -gt 31 ] && prio=31 # as RTLAT clamps it: the log shows what ran
out=${4:-C:/RTLAT}
loops=$((seconds * 1000))
mkdir -p "$out/copy" || exit 1
rm -f "$out/STOP" "$out"/RT-*.TXT "$out/SUMMARY.TXT"

measure() {
    echo "== $1: RTLAT -t $threads -p $prio, $seconds s"
    RTLAT -t "$threads" -a 0 -i 1000 -l "$loops" -p "$prio" -h 100 -q > "$out/RT-$1.TXT"
    echo "== $1" >> "$out/SUMMARY.TXT"
    grep "T[0-9]*:" "$out/RT-$1.TXT" >> "$out/SUMMARY.TXT"
}

# The disk load's file: 8 MB, made by doubling 1 KB:
s=0123456789abcdef
for i in 1 2 3 4 5 6; do s=$s$s; done
echo "$s" > "$out/big.bin"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
    cat "$out/big.bin" "$out/big.bin" > "$out/big2.bin"
    mv "$out/big2.bin" "$out/big.bin"
done

# Loads are tasks (ash runs only programs in the background), looping
# until FOLDER/STOP exists:
DISK="while [ ! -f $out/STOP ]; do cp $out/big.bin $out/copy/a.bin; cp $out/copy/a.bin $out/copy/b.bin; rm -f $out/copy/a.bin; done"
NET="while [ ! -f $out/STOP ]; do FETCH -o /dev/null http://127.0.0.1/ > /dev/null 2>&1; done"

stop() {
    echo stop > "$out/STOP"
    wait "$@"
    rm -f "$out/STOP"
}

measure IDLE

ASH -c "$DISK" &
disk=$!
sleep 2
measure DISK
stop $disk

DEMO rgb 1 &
demo=$!
sleep 2
measure GFX
KILL $demo
sleep 1

# HTTPZ may already run as a service; started here, it is ended here:
httpz=
if ! PS | grep -qi httpz; then
    HTTPZ > /dev/null 2>&1 &
    httpz=$!
    sleep 3
fi
ASH -c "$NET" &
net=$!
sleep 2
measure HTTP
stop $net

ASH -c "$DISK" &
disk=$!
ASH -c "$NET" &
net=$!
DEMO rgb 1 &
demo=$!
sleep 3
measure ALL
KILL $demo
stop $disk $net
[ -n "$httpz" ] && KILL $httpz

rm -rf "$out/copy" "$out/big.bin"

# A phase per RT-<PHASE>.TXT, and the
# SYSTEM.CFG settings that shape the timings:
cat > "$out/rt.awk" <<'END'
function flush() {
    if (phase == "") return
    if (nphases++) printf ",\n"
    printf "   \"%s\": {\"max_us\": %d, \"avg_us\": %d, \"overruns\": %d, \"wakeups\": %d,\n", phase, max, (n ? int(avgsum / n) : 0), over, count
    printf "    \"threads\": [%s],\n    \"histogram_100us\": {%s}}", threads, hist
}
FNR == 1 {
    flush()
    phase = FILENAME; sub(/.*RT-/, "", phase); sub(/\.TXT$/, "", phase); phase = tolower(phase)
    max = 0; avgsum = 0; n = 0; over = 0; count = 0; threads = ""; hist = ""
}
/^T[0-9]+: C:/ {
    l = $0; gsub(/:/, " ", l); $0 = l   # "C:  1000 Min:  0 ... Overruns:0": the old fields again ($3, $5 ... $13)
    t = sprintf("{\"count\": %d, \"min_us\": %d, \"last_us\": %d, \"avg_us\": %d, \"max_us\": %d, \"overruns\": %d}", $3, $5, $7, $9, $11, $13)
    threads = threads (n ? ", " : "") t
    n++; count += $3; avgsum += $9; over += $13; if ($11 > max) max = $11
}
/^ *(>=)? *[0-9]+-?:/ {
    key = $0; sub(/:.*/, "", key); gsub(/[ -]/, "", key)
    vals = $0; sub(/^[^:]*:/, "", vals); gsub(/^ +| +$/, "", vals); gsub(/ +/, ", ", vals)
    hist = hist (hist == "" ? "" : ", ") "\"" key "\": [" vals "]"
}
END { flush(); printf "\n" }
END
json="$out/realtime-$(date +%Y%m%d-%H%M).json"
{
    echo "{"
    echo " \"what\": \"RTLAT on this machine (scripts/realtime.sh): how late periodic wake-ups run, alone and under load\","
    echo " \"date\": \"$(date +%Y-%m-%d\ %H:%M)\","
    echo " \"rtlat\": \"RTLAT -t $threads -a 0 -i 1000 -l $loops -p $prio -h 100 -q (FIFO, priority $prio, thread n on core n)\","
    echo " \"threads\": $threads, \"seconds_per_phase\": $seconds, \"priority\": $prio,"
    echo " \"loads\": {\"idle\": \"RTLAT alone\", \"disk\": \"8 MB copied in a loop in $out\", \"gfx\": \"DEMO rgb 1\", \"http\": \"HTTPZ and FETCH over 127.0.0.1\", \"all\": \"disk, gfx and http at once\"},"
    printf ' "system_cfg": {'
    grep -iE "^(CORES|ISOLCPUS|NETCORE|NETPRIO|NETCPU|RTHEAP|IRQPRIO|RW_NX)=" C:/CONF/SYSTEM.CFG 2>/dev/null |
        awk -F= '{ gsub(/\r/, ""); printf "%s\"%s\": \"%s\"", (NR > 1 ? ", " : ""), toupper($1), $2 }'
    echo "},"
    echo " \"phases\": {"
    awk -f "$out/rt.awk" "$out/RT-IDLE.TXT" "$out/RT-DISK.TXT" "$out/RT-GFX.TXT" "$out/RT-HTTP.TXT" "$out/RT-ALL.TXT"
    echo " }"
    echo "}"
} > "$json"
rm -f "$out/rt.awk"

echo
cat "$out/SUMMARY.TXT"
echo "Results in $out, all of them in $json"