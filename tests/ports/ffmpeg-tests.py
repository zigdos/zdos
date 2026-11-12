#!/usr/bin/env python3
# FFmpeg in QEMU (metal-x86_64, KVM): FFMPEG9.ZDL, the tools, SDL2.ZDL
# and media files this computer's ffmpeg makes, on a FAT D:. Results in
# build/ffmpeg-tests/CASE (FFMPEG_TESTS_OUT=...).
#   ffmpeg-tests.py              the suite, unattended (exit code:
#                                failures); results in .../suite
#   ffmpeg-tests.py CASE STEP... by hand:
# Steps: cmd:TEXT text:TEXT key:K[:ms] wait:S until:FILE[:S] shot:NAME
# file:NAME:LINE;;LINE... (put onto D: first) burst:S (a screendump
# every 40 ms with the recording's size, for A/V sync);
# FFMPEG_TESTS_EXTRA=FILE:FILE... more files for D:
# The suite: decoding frame for frame as this computer's ffmpeg,
# encoders, filters, FFPROBE, FFPLAY's picture and sound; x264, LAME and
# WebP when the build has them (ports/media/ffmpeg264), else refused.
# Needs an ffmpeg with libx264, libx265, libvpx, lame, vorbis, opus.
import json, os, shutil, subprocess, sys, time
from array import array
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common
ZB = common.BUILD
OUT = os.path.abspath(os.environ.get("FFMPEG_TESTS_OUT", os.path.join(ZB, "ffmpeg-tests")))
FF = os.path.join(ZB, "ffmpeg", "x86_64")
LAVFI = ["-f", "lavfi", "-i"]
MEDIA = {  # name: ffmpeg arguments
    "H264.MP4": LAVFI + ["testsrc2=size=320x240:rate=25:duration=5"] + LAVFI + ["sine=frequency=440:duration=5"]
    + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"],
    "HEVC.MKV": LAVFI + ["testsrc2=size=640x360:rate=25:duration=5"] + LAVFI + ["sine=frequency=330:duration=5:sample_rate=48000"]
    + ["-c:v", "libx265", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-shortest"],
    "VP9.MKV": LAVFI + ["testsrc2=size=320x240:rate=25:duration=5"] + LAVFI + ["sine=frequency=550:duration=5"]
    + ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libvorbis", "-shortest"],
    "MPEG4.AVI": LAVFI + ["testsrc2=size=320x240:rate=25:duration=5"] + LAVFI + ["sine=duration=5"]
    + ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-shortest"],
    "SINE.MP3": LAVFI + ["sine=frequency=440:duration=10"] + ["-ac", "2", "-c:a", "libmp3lame"],
    "SINE.FLA": LAVFI + ["sine=frequency=440:duration=10"] + ["-c:a", "flac", "-f", "flac"],
    "SINE.OGG": LAVFI + ["sine=frequency=440:duration=10"] + ["-c:a", "libvorbis"],
    "BIG.MP4": LAVFI + ["testsrc2=size=1280x720:rate=30:duration=10"] + LAVFI + ["sine=frequency=440:duration=10:sample_rate=48000"]
    + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-b:v", "2M", "-c:a", "aac", "-shortest"],
    # A/V sync: a white flash and a 1 kHz beep, 0.12 s at every x.5 s:
    "SYNC.MP4": LAVFI + ["color=black:size=320x240:rate=25:duration=8,format=yuv420p,"
                         "geq=lum='if(between(mod(T,1),0.5,0.62),235,16)':cb=128:cr=128"]
    + LAVFI + ["aevalsrc='if(between(mod(t,1),0.5,0.62),0.5*sin(2*PI*1000*t),0)':s=48000:d=8"]
    + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-shortest"],
    # 1920x818 H.264 High, AC-3 5.1, SubRip subtitles, in MKV:
    "AC3SUB.MKV": LAVFI + ["testsrc2=size=1920x818:rate=24:duration=10"]
    + LAVFI + ["sine=frequency=440:duration=10:sample_rate=48000"] + ["-i", "{cache}/SUBS.SRT"]
    + ["-filter_complex", "[1:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0[a]", "-map", "0:v", "-map", "[a]", "-map", "2"]
    + ["-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-b:v", "1500k",
       "-c:a", "ac3", "-b:a", "448k", "-c:s", "srt"],
    # Inputs for the decoders the others leave out:
    "VP8.WEB": LAVFI + ["testsrc2=size=320x240:rate=25:duration=3"] + ["-c:v", "libvpx", "-b:v", "500k", "-f", "webm"],
    "MPEG2.TS": LAVFI + ["testsrc2=size=320x240:rate=25:duration=3"] + LAVFI + ["sine=duration=3"]
    + ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2", "-f", "mpegts"],
    "PRORES.MOV": LAVFI + ["testsrc2=size=320x240:rate=25:duration=2"] + ["-c:v", "prores_ks", "-pix_fmt", "yuv422p10le"],
    "FFV1.MKV": LAVFI + ["testsrc2=size=320x240:rate=25:duration=2"] + ["-c:v", "ffv1", "-pix_fmt", "yuv420p"],
    "TEST.PNG": LAVFI + ["testsrc2=size=320x240"] + ["-frames:v", "1", "-update", "1"],
    "TEST.GIF": LAVFI + ["testsrc2=size=160x120:rate=10:duration=1"] + ["-f", "gif"],
}
SRT = "1\n00:00:01,000 --> 00:00:04,000\nFirst subtitle line\n\n2\n00:00:05,000 --> 00:00:09,000\nSecond subtitle line\n"


def media(fdir):
    cache = os.path.join(OUT, "media")
    os.makedirs(cache, exist_ok=True)
    open(os.path.join(cache, "SUBS.SRT"), "w").write(SRT)
    for name, args in MEDIA.items():
        p = os.path.join(cache, name)
        if not os.path.exists(p):
            args = [a.replace("{cache}", cache) for a in args]
            subprocess.check_call(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + args + [p])
        shutil.copyfile(p, os.path.join(fdir, name))


def case_dir(name):
    # The port's files and the media in d/files:
    d = os.path.join(OUT, name)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    fdir = os.path.join(d, "files"); os.makedirs(fdir)
    for f in ("FFMPEG9.ZDL", "FFPROBE.APP", "FFMPEG.APP", "FFPLAY.APP"):
        p = os.path.join(FF, f)
        if os.path.exists(p):
            shutil.copyfile(p, os.path.join(fdir, f))
    sdl = os.path.join(ZB, "SDL", "x86_64", "SDL2.ZDL")
    if os.path.exists(sdl):
        shutil.copyfile(sdl, os.path.join(fdir, "SDL2.ZDL"))
    media(fdir)
    for extra in os.environ.get("FFMPEG_TESTS_EXTRA", "").split(os.pathsep):  # more files for D:
        if extra:
            shutil.copyfile(extra, os.path.join(fdir, os.path.basename(extra)))
    return d, fdir


def d_disk(d, fdir):
    ddisk = os.path.join(d, "d.img")
    subprocess.check_call(["mkfs.fat", "-F", "32", "-n", "FFT", "-C", ddisk, str(256 * 1024)], stdout=subprocess.DEVNULL)
    for f in sorted(os.listdir(fdir)):
        subprocess.check_call(["mcopy", "-i", ddisk, os.path.join(fdir, f), "::" + f])
    return ddisk


def start(d, ddisk):
    # QEMU with the system image's copy; (process, monitor, wav)
    img = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(ZB, "metal-x86_64", "system.img"), img)
    code, vars_ = common.ovmf()
    own = os.path.join(d, "VARS.fd"); shutil.copyfile(vars_, own)
    sock = os.path.join(d, "m.sock"); wav = os.path.join(d, "out.wav")
    args = ["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "4", "-m", "1G", "-vga", "std",
            "-drive", f"if=pflash,format=raw,readonly=on,file={code}", "-drive", f"if=pflash,format=raw,file={own}",
            "-drive", f"file={img},if=none,id=nvme0,format=raw", "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
            "-drive", f"file={ddisk},if=none,id=nvme1,format=raw", "-device", "nvme,serial=ZDOS0002,drive=nvme1",
            "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-mouse", "-nic", "none",
            "-display", "none", "-monitor", f"unix:{sock},server,nowait",
            "-audiodev", f"wav,id=snd,path={wav}", "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd"]
    proc = subprocess.Popen(args, cwd=d, stdout=subprocess.DEVNULL, stderr=open(os.path.join(d, "qemu.err"), "w"))
    return proc, common.Monitor(sock), wav


def has_file(ddisk, f):
    return subprocess.run(["mdir", "-b", "-i", ddisk, "::" + f], capture_output=True).returncode == 0


def driver():
    name = sys.argv[1]
    d, fdir = case_dir(name)
    for st in sys.argv[2:]:
        if st.startswith("file:"):
            f, _, text = st[5:].partition(":")
            open(os.path.join(fdir, f), "w").write("\r\n".join(text.split(";;")) + "\r\n")
    ddisk = d_disk(d, fdir)
    log = open(os.path.join(d, "steps.log"), "w")
    proc, mon, wav = start(d, ddisk)
    try:
        time.sleep(35)
        t0 = time.time()
        for st in sys.argv[2:]:
            k, _, v = st.partition(":")
            if k in ("cmd", "text"):
                for ch in v:
                    mon.cmd("sendkey " + common.key_name(ch)); time.sleep(0.05)
                if k == "cmd":
                    mon.cmd("sendkey ret"); time.sleep(2)
            elif k == "key":
                key, _, ms = v.partition(":")
                mon.cmd(f"sendkey {key} {ms or 100}")
                time.sleep(0.3)
            elif k == "wait":
                time.sleep(float(v))
            elif k == "file":
                pass
            elif k == "burst":
                bd = os.path.join(d, "burst"); os.makedirs(bd, exist_ok=True)
                t1, i, lines = time.time(), 0, []
                while time.time() - t1 < float(v):
                    size = os.path.getsize(wav) if os.path.exists(wav) else 0
                    mon.sock.sendall(f"screendump {bd}/{i:04d}.ppm\n".encode())
                    mon.drain()
                    lines.append(f"{i} {time.time() - t1:.3f} {size}")
                    i += 1
                    time.sleep(max(0.0, t1 + 0.04 * i - time.time()))
                open(os.path.join(d, "burst.txt"), "w").write("\n".join(lines) + "\n")
                print(f"burst: {i} screendumps", flush=True)
            elif k == "until":
                f, _, s = v.partition(":")
                t1 = time.time()
                while time.time() - t1 < float(s or 120):
                    if has_file(ddisk, f):
                        break
                    time.sleep(1)
                msg = f"until {f}: {time.time() - t1:.1f} s"
                print(msg, flush=True); log.write(msg + "\n")
            elif k == "shot":
                common.shot(mon, d, v); print(f"{time.time() - t0:6.1f} s shot {v}", flush=True)
        mon.cmd("quit")
    finally:
        time.sleep(2)
        if proc.poll() is None: proc.kill()
        proc.wait()
    listing = subprocess.run(["mdir", "-b", "-i", ddisk, "::"], capture_output=True, text=True).stdout.split()
    for f in listing:
        f = f.lstrip(":/")
        if f.upper().endswith(".TXT"):
            r = subprocess.run(["mtype", "-i", ddisk, "::" + f], capture_output=True, text=True, errors="replace")
            open(os.path.join(d, f), "w").write(r.stdout)
            print(f"--- {f}"); print("\n".join(r.stdout.splitlines()[:60]))
    if os.path.exists(wav):
        print("wav bytes", os.path.getsize(wav))
    print("done", name)


# THE SUITE: one boot runs D:\RUN.CMD, which writes every result onto
# D: (NAME.ERR when a command fails); the host checks them after.

FFM = "D:\\FFMPEG.APP -nostdin -hide_banner -v error -y"
EXACT = "-flags +bitexact -idct simple"  # MPEG-style IDCTs the same
# Decoding, video frame for frame: (case, file, input options)
VIDEO = [("h264", "H264.MP4", ""), ("hevc", "HEVC.MKV", ""), ("vp9", "VP9.MKV", ""), ("vp8", "VP8.WEB", ""),
         ("mpeg4", "MPEG4.AVI", EXACT), ("mpeg2", "MPEG2.TS", EXACT), ("prores", "PRORES.MOV", EXACT),
         ("ffv1", "FFV1.MKV", ""), ("h264-720p", "BIG.MP4", ""), ("h264-high", "AC3SUB.MKV", ""),
         ("png", "TEST.PNG", ""), ("gif", "TEST.GIF", "")]
# Audio: lossless ones exactly, the others within LOSSY
AUDIO = [("flac", "SINE.FLA", True), ("mp3", "SINE.MP3", False), ("vorbis", "SINE.OGG", False),
         ("aac", "H264.MP4", False), ("opus", "HEVC.MKV", False), ("ac3-5.1", "AC3SUB.MKV", False)]
LOSSY = 8  # 16-bit steps: float decoders' rounding, not damage
SHIFT = 2048  # per channel: a version's other start (decoder delay)
# Encoders: (case, guest arguments, output, expected stream, ...)
ENCODE = [
    ("enc-mpeg4", "-i D:\\H264.MP4 -c:v mpeg4 -q:v 5 -c:a mp2", "E_MPEG4.AVI", ("video", "mpeg4", 320, 240), ("audio", "mp2")),
    ("enc-mpeg2", "-i D:\\H264.MP4 -c:v mpeg2video -q:v 5 -c:a mp2 -f mpegts", "E_MPEG2.TS", ("video", "mpeg2video", 320, 240)),
    ("enc-mjpeg", "-i D:\\H264.MP4 -an -c:v mjpeg -q:v 5", "E_MJPEG.AVI", ("video", "mjpeg", 320, 240)),
    ("enc-prores", "-i D:\\H264.MP4 -an -c:v prores", "E_PRORES.MOV", ("video", "prores", 320, 240)),
    ("enc-ffv1", "-i D:\\H264.MP4 -an -c:v ffv1", "E_FFV1.MKV", ("video", "ffv1", 320, 240)),
    ("enc-aac", "-i D:\\SINE.FLA -c:a aac -b:a 128k -f mp4", "E_AAC.M4A", ("audio", "aac")),
    ("enc-flac", "-i D:\\SINE.MP3 -c:a flac -f flac", "E_FLAC.FLA", ("audio", "flac")),
    ("enc-opus", "-i D:\\SINE.FLA -c:a opus -strict -2 -f ogg", "E_OPUS.OGG", ("audio", "opus")),
    ("enc-vorbis", "-i D:\\SINE.FLA -ac 2 -c:a vorbis -strict -2 -f ogg", "E_VORB.OGG", ("audio", "vorbis")),
    ("enc-ac3", "-i D:\\SINE.FLA -c:a ac3 -f ac3", "E_AC3.AC3", ("audio", "ac3")),
    ("enc-png", "-i D:\\H264.MP4 -frames:v 1 -update 1", "E_PNG.PNG", ("video", "png", 320, 240)),
    ("enc-gif", "-i D:\\H264.MP4 -t 1 -vf fps=10", "E_GIF.GIF", ("video", "gif", 320, 240)),
    ("filters-video", "-i D:\\H264.MP4 -an -vf scale=160:120,hflip,fade=in:0:10 -c:v ffv1", "E_SCALE.MKV",
     ("video", "ffv1", 160, 120)),
    ("filters-audio", "-i D:\\SINE.FLA -af volume=0.5,atempo=2.0 -c:a flac -f flac", "E_TEMPO.FLA", ("audio", "flac")),
    ("remux-annexb", "-i D:\\H264.MP4 -c copy -f mpegts", "E_COPY.TS", ("video", "h264", 320, 240)),
    ("subtitles-srt", "-i D:\\AC3SUB.MKV -map 0:s -c:s srt -f srt", "E_SUBS.SRT", None),
]
# ffmpeg264's: here if the library has them, else refused
GPL = [
    ("x264", "libx264", "-i D:\\H264.MP4 -an -c:v libx264 -preset veryfast", "E_X264.MP4", ("video", "h264", 320, 240)),
    ("lame", "libmp3lame", "-i D:\\SINE.FLA -c:a libmp3lame -b:a 128k -f mp3", "E_LAME.MP3", ("audio", "mp3")),
    ("webp", "libwebp", "-i D:\\H264.MP4 -frames:v 1 -c:v libwebp -f webp", "E_WEBP.WEB", ("video", "webp", 320, 240)),
]
PROBED = ["HEVC.MKV", "AC3SUB.MKV", "MPEG4.AVI"]
PROBE = "-show_entries stream=codec_type,codec_name,width,height,channels -of csv=p=0"


def library_has(name):
    # The encoder's name in FFMPEG9.ZDL's codec tables:
    with open(os.path.join(FF, "FFMPEG9.ZDL"), "rb") as f:
        return b"\0" + name.encode() + b"\0" in f.read()


def batch(gpl):
    lines = ["@ECHO OFF", "D:\\FFMPEG.APP -hide_banner -encoders > D:\\ENC.TXT"]

    def cmd(case, text):  # its error output: CASE.LOG
        lines.append(f"{text} 2> D:\\{case}.LOG")
        lines.append(f"IF ERRORLEVEL 1 (ECHO failed > D:\\{case[:8].upper()}.ERR)")
    for i, (case, f, opts) in enumerate(VIDEO):
        cmd(f"V{i}", f"{FFM} {opts} -i D:\\{f} -an -sn -f framemd5 D:\\V{i}.MD5")
    for i, (case, f, exact) in enumerate(AUDIO):
        cmd(f"A{i}", f"{FFM} -i D:\\{f} -vn -sn -c:a pcm_s16le -f wav D:\\A{i}.WAV")
    for i, (case, args, out, *_) in enumerate(ENCODE + [(c, a, o, x) for c, _, a, o, x in GPL]):
        cmd(f"E{i}", f"{FFM} {args} D:\\{out}")
    for i, f in enumerate(PROBED):
        cmd(f"P{i}", f"D:\\FFPROBE.APP -v error {PROBE} D:\\{f} > D:\\P{i}.TXT")
    lines += ["ECHO playing > D:\\PLAY.TXT",
              "D:\\FFPLAY.APP -autoexit -nostats -loglevel error D:\\H264.MP4",
              "ECHO done > D:\\DONE.TXT"]
    return "\r\n".join(lines) + "\r\n"


def host(*args):
    return subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-v", "error", *args],
                          capture_output=True).stdout


def hashes(text):
    # framemd5's lines: the last field of each that isn't a comment
    return [ln.rsplit(",", 1)[-1].strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]


def aligned(mine, theirs, channels):
    # The shift (whole frames, up to SHIFT) where they match best:
    # (shift, largest difference)
    def worst(off, n):
        a, b = (off, 0) if off >= 0 else (0, -off)
        n = min(n, len(mine) - a, len(theirs) - b)
        return max((abs(mine[a + k] - theirs[b + k]) for k in range(n)), default=0)
    if worst(0, 4096) > LOSSY:
        offs = range(-SHIFT * channels, SHIFT * channels + 1, channels)
        off = min(offs, key=lambda o: worst(o, 2048))
    else:
        off = 0
    return off, worst(off, len(theirs))


def samples(data):
    a = array("h")
    a.frombytes(data[:len(data) // 2 * 2])
    return a


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
                       capture_output=True, text=True)
    return json.loads(r.stdout or "{}")


def check_output(path, expect):
    # Host's ffprobe: the stream expected; and it decodes cleanly
    if not os.path.exists(path):
        return False, "no output"
    streams = probe(path).get("streams", [])
    kind, codec, *size = expect
    s = next((x for x in streams if x.get("codec_type") == kind), None)
    if s is None or s.get("codec_name") != codec:
        return False, f"streams: {[(x.get('codec_type'), x.get('codec_name')) for x in streams]}"
    if size and (s.get("width"), s.get("height")) != tuple(size):
        return False, f"{s.get('width')}x{s.get('height')}"
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-f", "null", "-"], capture_output=True, text=True)
    if r.returncode or r.stderr.strip():
        return False, "host decoding: " + (r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[0]
    return True, f"{codec}" + (f" {size[0]}x{size[1]}" if size else "")


def duration(path):
    return float(probe(path).get("format", {}).get("duration", 0))


def suite():
    common.only("metal-x86_64")
    if not os.path.exists(os.path.join(FF, "FFMPEG9.ZDL")):
        print(f"{FF}: no FFmpeg build (ports/media/ffmpeg/build.sh): skipped")
        print("0 passed, 0 failed, 0 to review by screenshot")
        return 0
    gpl = {name: library_has(lib) for name, lib, *_ in GPL}
    port = "ffmpeg264 (x264, LAME, WebP)" if all(gpl.values()) else "ffmpeg (LGPL)" if not any(gpl.values()) else "mixed"
    print(f"port: {port}", flush=True)
    d, fdir = case_dir("suite")
    with open(os.path.join(fdir, "RUN.CMD"), "w", newline="") as f:
        f.write(batch(gpl))
    ddisk = d_disk(d, fdir)
    proc, mon, wav = start(d, ddisk)
    shots = []
    try:
        time.sleep(common.BOOT_WAIT + 10)
        for ch in "D:\\RUN.CMD":
            mon.cmd("sendkey " + common.key_name(ch)); time.sleep(0.05)
        mon.cmd("sendkey ret")
        t0 = time.time()
        while time.time() - t0 < 900 and not has_file(ddisk, "PLAY.TXT"):
            time.sleep(2)
        time.sleep(3)
        common.shot(mon, d, "ffplay")
        shots.append("ffplay")
        while time.time() - t0 < 960 and not has_file(ddisk, "DONE.TXT"):
            time.sleep(2)
        time.sleep(3)
        mon.cmd("quit")
    finally:
        time.sleep(2)
        if proc.poll() is None:
            proc.kill()
        proc.wait()
    got = os.path.join(d, "got")
    os.makedirs(got)
    subprocess.run(["mcopy", "-s", "-n", "-i", ddisk, "::*", got], capture_output=True)
    cache = os.path.join(OUT, "media")

    def guest(name):
        p = os.path.join(got, name)
        return open(p, "rb").read() if os.path.exists(p) else None

    def err(case):
        return os.path.exists(os.path.join(got, case[:8].upper() + ".ERR"))

    def why(case):
        # FFmpeg's first error line, from CASE.LOG:
        text = (guest(case.upper() + ".LOG") or b"").decode(errors="replace").strip()
        return (": " + text.splitlines()[0][:120]) if text else ""

    def wav_samples(name):
        # (samples, channels)
        import wave
        p = os.path.join(got, name)
        try:
            with wave.open(p) as w:
                return samples(w.readframes(w.getnframes())), w.getnchannels()
        except (OSError, wave.Error, EOFError):
            return samples(b""), 1

    results = []

    def result(name, ok, detail=""):
        results.append((name, ok, "", detail, []))
        print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f": {detail}" if detail else ""), flush=True)

    result("the batch file ran to its end", guest("DONE.TXT") is not None)
    enc = (guest("ENC.TXT") or b"").decode(errors="replace")
    for name, lib, *_ in GPL:
        listed = f" {lib} " in enc
        result(f"FFMPEG -encoders: {lib} " + ("listed" if gpl[name] else "not listed"), listed == gpl[name])
    for i, (case, f, opts) in enumerate(VIDEO):
        mine = hashes((guest(f"V{i}.MD5") or b"").decode(errors="replace"))
        theirs = hashes(host(*opts.split(), "-i", os.path.join(cache, f), "-an", "-sn", "-f", "framemd5", "-").decode())
        same = bool(theirs) and mine == theirs
        detail = f"{len(theirs)} frames" if same else f"{len(mine)} frames, {len(theirs)} on the host" + (
            f", first different: {next((k for k, (a, b) in enumerate(zip(mine, theirs)) if a != b), min(len(mine), len(theirs)))}"
            if mine else "") + (" (failed" + why(f"V{i}") + ")" if err(f"V{i}") else "")
        result(f"decode {case}: frames as the host's", same, detail)
    for i, (case, f, exact) in enumerate(AUDIO):
        (mine, channels), theirs = wav_samples(f"A{i}.WAV"), samples(
            host("-i", os.path.join(cache, f), "-vn", "-sn", "-f", "s16le", "-"))
        if not theirs or abs(len(mine) - len(theirs)) > max(len(theirs) // 100, SHIFT * channels):
            result(f"decode {case}", False, f"{len(mine)} samples, {len(theirs)} on the host" + why(f"A{i}"))
            continue
        if exact:
            worst = max((abs(a - b) for a, b in zip(mine, theirs)), default=0)
            result(f"decode {case}: samples the same", worst == 0 and len(mine) == len(theirs),
                   f"{len(mine)} samples, largest difference {worst}")
        else:
            off, worst = aligned(mine, theirs, channels)
            result(f"decode {case}: samples within {LOSSY}", worst <= LOSSY,
                   f"{len(mine)} samples, largest difference {worst}" + (f", {off // channels:+d} per channel" if off else ""))
    for i, (case, args, out, *expect) in enumerate(ENCODE):
        path = os.path.join(got, out)
        if expect[0] is None:  # the subtitles: SRT's text
            text = (guest(out) or b"").decode(errors="replace")
            ok = "First subtitle line" in text and "Second subtitle line" in text
            result(f"{case}: both lines", ok, "" if ok else ("failed" if err(f"E{i}") else text[:80]))
            continue
        ok, detail = check_output(path, expect[0])
        if not ok:
            detail += why(f"E{i}")
        if ok and case == "enc-ffv1":  # lossless: H.264's frames
            ok = hashes(host("-i", path, "-f", "framemd5", "-").decode()) == hashes(
                host("-i", os.path.join(cache, "H264.MP4"), "-an", "-f", "framemd5", "-").decode())
            detail += ", frames as H.264's" if ok else ", frames not H.264's"
        if ok and case == "filters-audio":  # atempo=2: 10 s in 5
            t = duration(path)
            ok, detail = 4.8 < t < 5.2, f"{t:.2f} s"
        result(case, ok, detail)
    for k, (name, lib, args, out, expect) in enumerate(GPL):
        i = len(ENCODE) + k
        path = os.path.join(got, out)
        if gpl[name]:
            ok, detail = check_output(path, expect)
            result(f"{name}: {lib} encodes", ok, detail)
        else:
            refused = err(f"E{i}") and not (os.path.exists(path) and os.path.getsize(path) > 0)
            result(f"{name}: {lib} refused (not in this build)", refused)
    for i, f in enumerate(PROBED):
        mine = (guest(f"P{i}.TXT") or b"").decode(errors="replace").split()
        r = subprocess.run(["ffprobe", "-v", "error", *PROBE.split(), os.path.join(cache, f)], capture_output=True, text=True)
        result(f"FFPROBE {f}: streams as the host's", bool(mine) and mine == r.stdout.split(), " ".join(mine))
    # FFPLAY: testsrc2's colours on the screen, and a sound
    from PIL import Image
    colors = len(set(Image.open(os.path.join(d, "ffplay.png")).convert("RGB").getdata())) if os.path.exists(
        os.path.join(d, "ffplay.png")) else 0
    result("FFPLAY: the picture (screenshot)", colors > 50, f"{colors} colours")
    peak = 0
    if os.path.exists(wav):
        import wave
        try:
            with wave.open(wav) as w:
                peak = max((abs(v) for v in samples(w.readframes(w.getnframes()))), default=0)
        except (wave.Error, EOFError):
            pass
    result("FFPLAY: its sound (recorded)", peak > 1000, f"peak {peak}")
    common.write_results(os.path.join(d, "RESULTS.md"), f"FFmpeg on ZDOS: {port}", results)
    return common.summary(results)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        driver()
    else:
        sys.exit(1 if suite() else 0)
