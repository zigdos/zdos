#!/usr/bin/env python3
# sf2reduce.py IN.SF2 OUT.SF2 [--size MB] [--max MB]: a small
# General MIDI SoundFont from a big one (bank 0's programs 0-127,
# drum kit 128:0). One velocity layer, a few key zones per
# instrument, short attacks and loops (or tails), mono or stereo,
# 22050 or 16000 Hz: the first step of LEVELS that fits --size.
# Needs numpy.
import argparse
import math
import struct
import sys

import numpy as np

# Generous to tight: (zones per instrument, rate, longest attack
# before a loop, longest loop, longest unlooped sample; seconds):
LEVELS = [
    (128, 44100, 60, 60, 8), (16, 32000, 4, 2, 4), (8, 22050, 2, 1, 2),
    (5, 22050, 1.5, 0.5, 1.5), (4, 22050, 1, 0.4, 1), (3, 22050, 0.8, 0.3, 0.8),
    (3, 16000, 0.8, 0.3, 0.8), (3, 16000, 0.6, 0.25, 0.6),
    (3, 16000, 0.45, 0.2, 0.5), (3, 16000, 0.35, 0.15, 0.4),
    (2, 16000, 0.45, 0.2, 0.5), (2, 16000, 0.35, 0.15, 0.4),
    (1, 16000, 0.3, 0.12, 0.35),
]
DRUM_KEYS = range(35, 82)  # GM's percussion keys
VELOCITY = 100  # the layer kept
GUARD = 8  # points after a loop's end
PAD = 46  # zero points after each sample

# SF2 GENERATORS
G_START, G_END, G_LSTART, G_LEND, G_START_C = 0, 1, 2, 3, 4
G_END_C, G_PAN, G_INST, G_KEYS, G_VELS = 12, 17, 41, 43, 44
G_LSTART_C, G_ATTEN, G_LEND_C, G_SAMPLE = 45, 48, 50, 53
G_MODES, G_ROOT = 54, 58
OFFSETS = (G_START, G_END, G_LSTART, G_LEND, G_START_C, G_END_C, G_LSTART_C, G_LEND_C)
NOT_ADDITIVE = set(OFFSETS) | {G_INST, G_KEYS, G_VELS, 46, 47, G_SAMPLE, G_MODES, 57, G_ROOT}
DEFAULTS = {8: 13500, 21: -12000, 23: -12000, 25: -12000, 26: -12000, 27: -12000,
            28: -12000, 30: -12000, 33: -12000, 34: -12000, 35: -12000, 36: -12000,
            38: -12000, 56: 100, G_ROOT: -1, 46: -1, 47: -1}


# READING

def chunks(d, at, end):
    while at + 8 <= end:
        n = struct.unpack_from('<I', d, at + 4)[0]
        yield d[at:at + 4], at + 8, n
        at += 8 + n + (n & 1)


def records(blob, fmt):
    size = struct.calcsize(fmt)
    return [struct.unpack_from(fmt, blob, i) for i in range(0, len(blob) - size + 1, size)]


def read_sf2(path):
    d = open(path, 'rb').read()
    if d[:4] != b'RIFF' or d[8:12] != b'sfbk':
        sys.exit('%s: not a SoundFont 2' % path)
    sub = {}
    for cid, at, n in chunks(d, 12, len(d)):
        if cid == b'LIST':
            for c2, a2, n2 in chunks(d, at + 4, at + n):
                sub[c2.decode('latin-1')] = d[a2:a2 + n2]
    if 'smpl' not in sub:
        sys.exit('%s: no 16-bit samples (SF3 is not read)' % path)
    sf = {
        'phdr': records(sub['phdr'], '<20sHHHIII'),
        'pbag': records(sub['pbag'], '<HH'),
        'pgen': records(sub['pgen'], '<Hh'),
        'inst': records(sub['inst'], '<20sH'),
        'ibag': records(sub['ibag'], '<HH'),
        'igen': records(sub['igen'], '<Hh'),
        'shdr': records(sub['shdr'], '<20sIIIIIBbHH'),
        'smpl': np.frombuffer(sub['smpl'], dtype='<i2'),
        'icop': sub.get('ICOP', b''),
        'inam': sub.get('INAM', b''),
    }
    return sf


def zones(bags, gens, first, last, key_gen):
    # (gens dict) per zone, the global zone merged into each:
    glob, out = {}, []
    for b in range(first, last):
        g = {op: amt for op, amt in gens[bags[b][0]:bags[b + 1][0]]}
        if key_gen in g:
            out.append({**glob, **g})
        elif b == first:
            glob = g
    return out


def rng(v):
    v &= 0xFFFF
    return v & 0xFF, v >> 8


# FLATTENING: a preset's regions (instrument zones with the preset's
# additive generators added, ranges intersected)

def regions_of(sf, p):
    ph = sf['phdr']
    out = []
    for pz in zones(sf['pbag'], sf['pgen'], ph[p][3], ph[p + 1][3], G_INST):
        inst = pz[G_INST]
        pk, pv = rng(pz.get(G_KEYS, 0x7F00)), rng(pz.get(G_VELS, 0x7F00))
        ib = sf['inst']
        for iz in zones(sf['ibag'], sf['igen'], ib[inst][1], ib[inst + 1][1], G_SAMPLE):
            ik, iv = rng(iz.get(G_KEYS, 0x7F00)), rng(iz.get(G_VELS, 0x7F00))
            keys = (max(pk[0], ik[0]), min(pk[1], ik[1]))
            vels = (max(pv[0], iv[0]), min(pv[1], iv[1]))
            if keys[0] > keys[1] or vels[0] > vels[1]:
                continue
            g = {op: v for op, v in iz.items() if op not in (G_KEYS, G_VELS)}
            for op, v in pz.items():
                if op not in NOT_ADDITIVE:
                    g[op] = g.get(op, DEFAULTS.get(op, 0)) + v
            out.append({'g': g, 'keys': keys, 'vels': vels, 's': g.pop(G_SAMPLE)})
    return out


def points(sf, r, sample=None):
    # The region's start, end, loop start and end in smpl:
    s = sf['shdr'][r['s'] if sample is None else sample]
    g = r['g']
    o = lambda f, c: g.get(f, 0) + 32768 * g.get(c, 0)
    n = len(sf['smpl'])
    cl = lambda v: max(0, min(n, v))
    return (cl(s[1] + o(G_START, G_START_C)), cl(s[2] + o(G_END, G_END_C)),
            cl(s[3] + o(G_LSTART, G_LSTART_C)), cl(s[4] + o(G_LEND, G_LEND_C)))


def root_of(sf, r):
    k = r['g'].get(G_ROOT, -1)
    if k < 0:
        k = sf['shdr'][r['s']][6]
    return k if k <= 127 else 60


# SELECTION

def merge_stereo(sf, regs):
    # A left/right pair: one region, both samples (mixed later):
    sh = sf['shdr']
    by = {(r['keys'], r['vels'], r['s']): r for r in regs}
    used, out = set(), []
    for r in regs:
        if id(r) in used:
            continue
        typ = sh[r['s']][9] & 0x7FFF
        if typ in (2, 4):
            other = by.get((r['keys'], r['vels'], sh[r['s']][8]))
            if other is None:
                # A broken link: the other side over the same keys:
                other = next((o for o in regs if o['keys'] == r['keys'] and o['vels'] == r['vels'] and
                              sh[o['s']][9] & 0x7FFF == 6 - typ and id(o) not in used), None)
            if other is not None and id(other) not in used and other is not r:
                used.add(id(other))
                left, right = (r, other) if typ == 4 else (other, r)
                pans = (left['g'].get(G_PAN, -500), right['g'].get(G_PAN, 500))
                r = dict(r, partner=right['s'], pans=pans)
                if typ == 2:
                    r['s'] = other['s']  # the left one leads
            r['g'] = dict(r['g'])
            r['g'].pop(G_PAN, None)
        used.add(id(r))
        out.append(r)
    return out


def slow(r):
    # A layer that takes over half a second to sound:
    t = lambda op: 2 ** (r['g'].get(op, -12000) / 1200.0)
    return t(33) + t(34) > 0.5


def one_layer(regs, keys):
    # Per key the region at VELOCITY (or the nearest one), the quietest
    # of overlapping layers; runs of keys as regions:
    owner = {}
    for k in keys:
        c = [r for r in regs if r['keys'][0] <= k <= r['keys'][1]]
        if not c:
            continue
        dist = lambda r: 0 if r['vels'][0] <= VELOCITY <= r['vels'][1] else min(
            abs(r['vels'][0] - VELOCITY), abs(r['vels'][1] - VELOCITY))
        best = min(dist(r) for r in c)
        c = [r for r in c if dist(r) == best]
        owner[k] = min(c, key=lambda r: (slow(r), r['g'].get(G_ATTEN, 0), -(r['vels'][1] - r['vels'][0])))
    runs = []
    for k in sorted(owner):
        r = owner[k]
        if runs and runs[-1][0] is r and runs[-1][2] == k - 1:
            runs[-1][2] = k
        else:
            runs.append([r, k, k])
    return [dict(r, keys=(lo, hi), vels=(0, 127)) for r, lo, hi in runs]


def few_zones(sf, regs, n):
    # n regions spread over the keys, stretched over 0-127:
    if len(regs) > n:
        pick = sorted({int((j + 0.5) * len(regs) / n) for j in range(n)})
    else:
        pick = list(range(len(regs)))
    out = []
    lo = 0
    for j, i in enumerate(pick):
        a = regs[i]
        if j + 1 == len(pick):
            hi = 127
        else:
            b = regs[pick[j + 1]]
            if pick[j + 1] == i + 1 and a['keys'][1] + 1 == b['keys'][0]:
                hi = a['keys'][1]
            else:
                hi = (root_of(sf, a) + root_of(sf, b)) // 2
                hi = max(a['keys'][0], min(b['keys'][1] - 1, hi))
            hi = max(hi, lo)
        out.append(dict(a, keys=(lo, hi)))
        lo = hi + 1
        if lo > 127:
            break
    return out


def presets(sf):
    want = [(0, p) for p in range(128)] + [(128, 0)]
    found = {(h[2], h[1]): i for i, h in enumerate(sf['phdr'][:-1])}
    missing = [w for w in want if w not in found]
    if missing:
        sys.exit('the SoundFont lacks presets (bank, program): %s' % missing)
    return [(w, found[w]) for w in want]


def select(sf, flat, level):
    # Regions per preset and the samples they need, for one level:
    zones_n = level[0]
    plan, samples = [], {}
    for (bank, prog), regs in flat:
        drums = bank == 128
        regs = one_layer(regs, DRUM_KEYS if drums else range(128))
        if not drums:
            regs = few_zones(sf, regs, zones_n)
        if STEREO:
            regs = split_stereo(regs)
        for r in regs:
            r['key'] = sample_key(sf, r, level)
            samples.setdefault(r['key'], est_len(r['key']))
        plan.append(((bank, prog), regs))
    return plan, samples


# --stereo: a left/right pair as two zones over the same keys,
# each with its own sample and the pan it had, not mixed
STEREO = False


def split_stereo(regs):
    out = []
    for r in regs:
        if 'partner' not in r:
            out.append(r)
            continue
        pl, pr = r['pans']
        left = {k: v for k, v in r.items() if k not in ('partner', 'pans')}
        left['g'] = dict(r['g'])
        left['g'][G_PAN] = pl
        right = dict(left, s=r['partner'])
        right['g'] = dict(r['g'])
        right['g'][G_PAN] = pr
        out += [left, right]
    return out


def sample_key(sf, r, level):
    _, rate, attack, loop, tail = level
    st, en, ls, le = points(sf, r)
    sh = sf['shdr'][r['s']]
    looped = r['g'].get(G_MODES, 0) & 1 and st <= ls < le <= en and le - ls >= 2
    partner = None
    if 'partner' in r:
        ps = points(sf, r, r['partner'])
        if ps[1] - ps[0] == en - st and ps[2] - ps[0] == ls - st and ps[3] - ps[0] == le - st:
            partner = ps[0]
    src = sh[5]
    if looped:
        cut = (int(attack * src), int(loop * src))
        if ls - st <= cut[0] and le - ls <= cut[1]:
            cut = None
        en = le
    else:
        ls = le = 0
        cut = None
        en = min(en, st + int(tail * src))
    pans = r.get('pans') if partner is not None else None
    return (st, en, ls, le, partner, src, min(rate, src), r['s'], cut, root_of(sf, r), pans)


def est_len(key):
    st, en, ls, le, _, src, dst, _, cut, _, _ = key
    n = en - st
    if cut:
        n = min(ls - st, cut[0]) + min(le - ls, cut[1])
    return int(n * dst / src) + GUARD + PAD


# A NEW LOOP: a sample's attack or loop too long for the level gets a
# loop of whole periods near the cut, crossfaded; a decay the sample
# had before its old loop becomes the volume envelope's:

def new_loop(y, ls, le, cut, src, root, cents):
    att = min(ls, cut[0])
    period = src / (440.0 * 2 ** ((root - 69 - cents / 100.0) / 12))
    want = min(le - ls, cut[1], max(period, 0.1 * src))
    n = max(1, round(want / period))
    length = max(2, round(n * period))
    end = att + length
    best = None
    for cand in range(max(2, length - 2), length + 3):
        if end - cand < 64:
            continue
        d = float(np.sum((y[end - cand - 64:end - cand] - y[end - 64:end]) ** 2))
        if best is None or d < best[0]:
            best = (d, cand)
    if best:
        length = best[1]
    nls, nle = end - length, end
    x = min(length // 2, nls)
    if x > 0:
        w = np.linspace(0.0, 1.0, x)
        y[nle - x:nle] = y[nle - x:nle] * (1 - w) + y[nls - x:nls] * w
    # The level the old loop had against the new one's:
    rms = lambda v: math.sqrt(float(np.mean(v * v))) + 1e-9
    drop = 200 * math.log10(rms(y[nls:nle]) / rms(y[ls:le])) if att < ls else 0
    env = None
    if drop > 30:
        env = (att / src, drop, (ls - att) / src)
    return y[:nle].copy(), nls, nle, env


# RESAMPLING (windowed sinc; a loop's length kept whole)

def resample(x, src, dst, st, en, ls, le, looped, fade):
    if src <= dst:
        r = 1.0
    elif looped:
        r = max(1, round((le - ls) * dst / src)) / (le - ls)
    else:
        r = dst / src
    if looped:
        n_att = round((ls - st) * r)
        n_loop = round((le - ls) * r)
        k = np.arange(n_att + n_loop + GUARD, dtype=np.float64)
        pos = ls + (k - n_att) / r
        pos = np.where(pos >= le, pos - (le - ls), pos)
    else:
        k = np.arange(int((en - st) * r), dtype=np.float64)
        pos = st + k / r

    def fetch(i):
        if looped:
            i = np.where(i >= le, ls + (i - ls) % (le - ls), i)
        ok = (i >= st) & (i < en)
        return np.where(ok, x[np.clip(i, 0, len(x) - 1)], 0.0)

    if r == 1.0 and np.all(pos == np.floor(pos)):
        y = fetch(pos.astype(np.int64))
    else:
        fc = min(1.0, r) * 0.94
        hw = int(math.ceil(10 / fc))
        taps = np.arange(-hw + 1, hw + 1)
        y = np.empty(len(pos))
        for a in range(0, len(pos), 16384):
            p = pos[a:a + 16384]
            base = np.floor(p).astype(np.int64)
            idx = base[:, None] + taps[None, :]
            t = p[:, None] - idx
            w = fc * np.sinc(fc * t) * (0.42 + 0.5 * np.cos(np.pi * t / hw) + 0.08 * np.cos(2 * np.pi * t / hw))
            y[a:a + 16384] = (fetch(idx) * w).sum(axis=1)
    if fade and len(y) > 16:
        f = len(y) // 3
        y[-f:] *= np.linspace(1.0, 0.0, f)
    rate = int(round(src * r))
    if looped:
        return y, rate, n_att, n_att + n_loop
    return y, rate, 0, 0


# WRITING

def info_str(tag, s):
    b = s + b'\0'
    if len(b) & 1:
        b += b'\0'
    return tag + struct.pack('<I', len(b)) + b


def riff(tag, body):
    return tag + struct.pack('<I', len(body)) + body + (b'\0' if len(body) & 1 else b'')


def name20(b):
    return b.split(b'\0')[0][:19].ljust(20, b'\0')


def build(sf, plan, samples):
    x = sf['smpl'].astype(np.float64)
    sh = sf['shdr']
    data, shdr, index, gain, envs = [], [], {}, {}, {}
    at = 0
    for key in samples:
        st, en, ls, le, partner, src, dst, s, cut, root, pans = key
        looped = le > ls
        seg = x[st:en].copy()
        if partner is not None:
            # The two ears as the pans made them, summed; as loud
            # in each ear as before, at the middle:
            other = x[partner:partner + len(seg)]
            pl, pr = (p / 1000.0 for p in pans)
            ear = lambda side: (math.sqrt(max(0, 0.5 + side * pl)) * seg +
                                math.sqrt(max(0, 0.5 + side * pr)) * other)
            le_, re_ = ear(-1), ear(1)
            both = le_ + re_
            seg = both * math.sqrt((np.dot(le_, le_) + np.dot(re_, re_)) / (np.dot(both, both) + 1e-9))
        ls, le = ls - st, le - st
        if cut:
            seg, ls, le, envs[key] = new_loop(seg, ls, le, cut, src, root, sh[s][7])
        fade = not looped and en < sh[s][2]
        y, rate, nls, nle = resample(seg, src, dst, 0, len(seg), ls, le, looped, fade)
        peak = float(np.max(np.abs(y))) if len(y) else 0.0
        scale = 32767.0 / peak if peak > 32767 else 1.0
        gain[key] = 200 * math.log10(1 / scale) if scale < 1 else 0
        y = np.clip(np.round(y * scale), -32768, 32767).astype('<i2')
        if looped:
            nend = nle
        else:
            nend = len(y)
            nls, nle = max(0, nend - 9), max(0, nend - 1)
        index[key] = len(shdr)
        shdr.append(struct.pack('<20sIIIIIBbHH', name20(sh[s][0]), at, at + nend,
                                at + nls, at + nle, rate, sh[s][6], sh[s][7], 0, 1))
        data.append(y.tobytes())
        data.append(b'\0' * 2 * PAD)
        at += len(y) + PAD
    shdr.append(struct.pack('<20sIIIIIBbHH', b'EOS'.ljust(20, b'\0'), 0, 0, 0, 0, 0, 0, 0, 0, 0))

    phdr, pbag, pgen, inst, ibag, igen = [], [], [], [], [], []
    for n, ((bank, prog), regs) in enumerate(plan):
        pi = next(i for i, h in enumerate(sf['phdr']) if h[1] == prog and h[2] == bank)
        pname = name20(sf['phdr'][pi][0])
        phdr.append(struct.pack('<20sHHHIII', pname, prog, bank, len(pbag), 0, 0, 0))
        pbag.append(struct.pack('<HH', len(pgen), 0))
        pgen.append(struct.pack('<Hh', G_INST, n))
        inst.append(struct.pack('<20sH', pname, len(ibag)))
        for r in regs:
            ibag.append(struct.pack('<HH', len(igen), 0))
            g = {op: v for op, v in r['g'].items() if op not in OFFSETS and op not in (G_KEYS, G_VELS, G_SAMPLE)}
            looped = r['key'][3] > r['key'][2]
            g[G_MODES] = 1 if looped else 0
            env = envs.get(r['key'])
            if env and env[1] > g.get(37, 0) + 30:
                hold, drop, span = env
                tc = lambda t: int(round(1200 * math.log2(max(t, 0.001))))
                g[35] = max(g.get(35, -12000), tc(hold))
                g[36] = tc(span * 960 / min(drop, 1440))
                g[37] = min(1440, int(drop))
            if gain[r['key']]:
                g[G_ATTEN] = max(0, int(g.get(G_ATTEN, 0) - gain[r['key']]))
            igen.append(struct.pack('<HH', G_KEYS, r['keys'][0] | r['keys'][1] << 8))
            igen.append(struct.pack('<HH', G_VELS, 0 | 127 << 8))
            for op in sorted(g):
                igen.append(struct.pack('<Hh', op, max(-32768, min(32767, g[op]))))
            igen.append(struct.pack('<HH', G_SAMPLE, index[r['key']]))
    phdr.append(struct.pack('<20sHHHIII', b'EOP'.ljust(20, b'\0'), 0, 0, len(pbag), 0, 0, 0))
    pbag.append(struct.pack('<HH', len(pgen), 0))
    pgen.append(struct.pack('<Hh', 0, 0))
    inst.append(struct.pack('<20sH', b'EOI'.ljust(20, b'\0'), len(ibag)))
    ibag.append(struct.pack('<HH', len(igen), 0))
    igen.append(struct.pack('<Hh', 0, 0))
    mod_end = b'\0' * 10

    info = (b'ifil' + struct.pack('<IHH', 4, 2, 1) +
            info_str(b'isng', b'EMU8000') + info_str(b'INAM', b'ZDOS General MIDI') +
            info_str(b'ICMT', b'Reduced from ' + sf['inam'].split(b'\0')[0] + b' by sf2reduce.py'))
    if sf['icop']:
        info += info_str(b'ICOP', sf['icop'].split(b'\0')[0])
    pdta = b''.join([riff(b'phdr', b''.join(phdr)), riff(b'pbag', b''.join(pbag)),
                     riff(b'pmod', mod_end), riff(b'pgen', b''.join(pgen)),
                     riff(b'inst', b''.join(inst)), riff(b'ibag', b''.join(ibag)),
                     riff(b'imod', mod_end), riff(b'igen', b''.join(igen)),
                     riff(b'shdr', b''.join(shdr))])
    body = (b'sfbk' + riff(b'LIST', b'INFO' + info) + riff(b'LIST', b'sdta' + riff(b'smpl', b''.join(data))) +
            riff(b'LIST', b'pdta' + pdta))
    return riff(b'RIFF', body)


def main():
    ap = argparse.ArgumentParser(description='A small GM SoundFont from a big one')
    ap.add_argument('input')
    ap.add_argument('output')
    ap.add_argument('--size', type=float, default=4.0, help='target size in MB (default 4)')
    ap.add_argument('--max', type=float, help='fail above this many MB (default twice --size)')
    ap.add_argument('--stereo', action='store_true', help="keep stereo pairs (more MB)")
    a = ap.parse_args()
    global STEREO
    STEREO = a.stereo
    limit = (a.max or 2 * a.size) * 1e6
    sf = read_sf2(a.input)
    flat = [(w, merge_stereo(sf, regions_of(sf, p))) for w, p in presets(sf)]
    for level in LEVELS:
        plan, samples = select(sf, flat, level)
        est = 2 * sum(samples.values()) + 40000
        if est <= a.size * 1e6:
            break
    out = build(sf, plan, samples)
    if len(out) > limit:
        sys.exit('%s: %.1f MB, above %.1f MB' % (a.output, len(out) / 1e6, limit / 1e6))
    open(a.output, 'wb').write(out)
    print('%s: %.2f MB, %d samples; zones %d, %d Hz, attack %g s, loop %g s, unlooped %g s' %
          ((a.output, len(out) / 1e6, len(samples)) + level))


if __name__ == '__main__':
    main()
