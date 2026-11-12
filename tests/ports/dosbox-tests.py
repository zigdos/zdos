#!/usr/bin/env python3
# DOSBOX.APP in QEMU (metal-x86_64, KVM), with a copy of
# DOSBOX_DISK (games and DOSBOX.CONF) as D:.
#   dosbox-tests.py CASE STEP...
# Steps: cmd:TEXT text:TEXT key:K[:ms] wait:S shot:NAME mouse:DX:DY
# click:L|R ls:PATH
import array, os, shutil, subprocess, sys, time, wave
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import common
ZB = common.BUILD
D = os.path.join(ZB, "dosbox-tests")
DISK = os.environ.get("DOSBOX_DISK") or sys.exit("DOSBOX_DISK: the FAT image to use as D: (copied)")

def mouse_move(mon, dx, dy):
    # QEMU clamps one move's size: in steps:
    while dx or dy:
        sx, sy = max(-40, min(40, dx)), max(-40, min(40, dy))
        mon.cmd(f"mouse_move {sx} {sy}")
        dx, dy = dx - sx, dy - sy

def wav_level(path, log):
    # Peak and RMS of each 5 s of the recording: silence or sound:
    try:
        w = wave.open(path)
    except (wave.Error, EOFError) as e:
        log.write(f"wav: {e}\n"); print(f"wav: {e}"); return
    rate, ch = w.getframerate(), w.getnchannels()
    data = array.array("h", w.readframes(w.getnframes()))
    step = rate * ch * 5
    for i in range(0, len(data), step):
        part = data[i:i + step]
        if not part: break
        peak = max(abs(v) for v in part)
        rms = (sum(v * v for v in part) / len(part)) ** 0.5
        line = f"wav {i // (rate * ch):4d} s: peak {peak:5d} rms {rms:7.1f}"
        log.write(line + "\n"); print(line)

def main():
    name = sys.argv[1]
    d = os.path.join(D, name)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    ddisk = os.path.join(d, "d.img")
    shutil.copyfile(DISK, ddisk)
    app = os.environ.get("APP", os.path.join(ZB, "dosbox", "x86_64", "dosbox.app"))
    subprocess.check_call(["mcopy", "-o", "-i", ddisk, app, "::DOSBOX.APP"])
    img = os.path.join(d, "system.img")
    shutil.copyfile(os.path.join(ZB, "metal-x86_64", "system.img"), img)
    code, vars_ = common.ovmf()
    own = os.path.join(d, "VARS.fd"); shutil.copyfile(vars_, own)
    sock = os.path.join(d, "m.sock"); wav = os.path.join(d, "out.wav")
    args = ["qemu-system-x86_64", *common.x86_accel(), "-machine", "q35", "-smp", "4", "-m", "1G", "-vga", "std",
            "-drive", f"if=pflash,format=raw,readonly=on,file={code}", "-drive", f"if=pflash,format=raw,file={own}",
            "-drive", f"file={img},if=none,id=nvme0,format=raw", "-device", "nvme,serial=ZDOS0001,drive=nvme0,bootindex=0",
            "-drive", f"file={ddisk},if=none,id=nvme1,format=raw", "-device", "nvme,serial=ZDOS0002,drive=nvme1",
            "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-mouse",
            "-display", "none", "-monitor", f"unix:{sock},server,nowait",
            "-audiodev", f"wav,id=snd,path={wav}", "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd"]
    log = open(os.path.join(d, "steps.log"), "w")
    proc = subprocess.Popen(args, cwd=d, stdout=subprocess.DEVNULL, stderr=open(os.path.join(d, "qemu.err"), "w"))
    listing = []
    try:
        mon = common.Monitor(sock)
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
            elif k == "shot":
                common.shot(mon, d, v); print(f"{time.time() - t0:6.1f} s shot {v}", flush=True)
            elif k == "mouse":
                dx, _, dy = v.partition(":")
                mouse_move(mon, int(dx), int(dy)); time.sleep(0.3)
            elif k == "click":
                mon.cmd(f"mouse_button {2 if v == 'R' else 1}"); time.sleep(0.15)
                mon.cmd("mouse_button 0"); time.sleep(0.3)
            elif k == "ls":
                listing.append(v)
            log.write(f"{time.time() - t0:6.1f} s {st}\n")
        mon.cmd("quit")
    finally:
        time.sleep(2)
        if proc.poll() is None: proc.kill()
        proc.wait()
    for path in listing:
        r = subprocess.run(["mdir", "-i", ddisk, "::" + path], capture_output=True, text=True, errors="replace")
        print(r.stdout); log.write(r.stdout)
    if os.path.exists(wav):
        print("wav bytes", os.path.getsize(wav))
        wav_level(wav, log)
    print("done", name)

main()
