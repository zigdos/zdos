# MICROPYTHON C:\SCRIPTS\GCSTRESS.PY [rounds]: MicroPython GC stress.
# Many small objects are built and dropped with the heap nearly full
# (1 KiB blocks of known content leave about 64 KiB free);
# each result is checked.
# A collection freeing an object in use shows as a wrong value,
# an odd exception or a crash. PASS: exit code 0, FAIL: 1.
# A failure on UEFI or ARM64 points at pointers held only in registers.

import gc
import sys

ROUNDS = 500
FREE_TARGET = 64 * 1024
if len(sys.argv) > 1:
    ROUNDS = int(sys.argv[1])

failures = 0
seed = 12345


def rand(n):
    # Deterministic, so every run does the same work:
    global seed
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    return seed % n


def fail(test, rnd, detail):
    global failures
    failures += 1
    print("FAIL round %d, %s: %s" % (rnd, test, detail))


def test_strings(rnd):
    n = 50 + rand(100)
    items = ["item%d-%s" % (i, "x" * (i % 7)) for i in range(n)]
    for i in range(n):
        if items[i] != "item" + str(i) + "-" + "x" * (i % 7):
            fail("strings", rnd, "items[%d] = %r" % (i, items[i]))
            return
    joined = ",".join(items)
    parts = joined.split(",")
    if parts != items:
        fail("strings", rnd, "join/split differs")


def test_dicts(rnd):
    n = 30 + rand(60)
    d = {}
    for i in range(n):
        d["k%d" % i] = (i, str(i * i), [i] * (i % 4))
    for i in range(n):
        v = d.get("k%d" % i)
        if v is None or v[0] != i or v[1] != str(i * i) or v[2] != [i] * (i % 4):
            fail("dicts", rnd, "d['k%d'] = %r" % (i, v))
            return
    if sorted(d.keys(), key=lambda k: int(k[1:])) != ["k%d" % i for i in range(n)]:
        fail("dicts", rnd, "keys differ")


def test_nested(rnd):
    n = 20 + rand(40)
    rows = [[j * i for j in range(i % 9 + 1)] for i in range(n)]
    rows.sort(key=lambda r: (sum(r), len(r)), reverse=True)
    for k in range(1, len(rows)):
        a = (sum(rows[k - 1]), len(rows[k - 1]))
        b = (sum(rows[k]), len(rows[k]))
        if a < b:
            fail("nested", rnd, "order broken at %d: %r < %r" % (k, a, b))
            return
    total = 0
    for i in range(n):
        total += sum(j * i for j in range(i % 9 + 1))
    if sum(sum(r) for r in rows) != total:
        fail("nested", rnd, "sum differs")


def make_counter(start, label):
    data = [start, label + "!"]

    def step():
        data[0] += 1
        return "%s%d" % (data[1], data[0])

    return step


def test_closures(rnd):
    counters = [make_counter(i * 10, "c%d" % i) for i in range(20)]
    for _ in range(5):
        results = [c() for c in counters]
    for i in range(20):
        want = "c%d!%d" % (i, i * 10 + 5)
        if results[i] != want:
            fail("closures", rnd, "%r != %r" % (results[i], want))
            return


def squares(n):
    for i in range(n):
        yield (i, i * i, "s%d" % i)


def test_generators(rnd):
    n = 100 + rand(200)
    got = [t for t in squares(n) if t[0] % 3 == 0]
    want = [(i, i * i, "s%d" % i) for i in range(0, n, 3)]
    if got != want:
        fail("generators", rnd, "lists differ")


class Payload(Exception):
    pass


def test_exceptions(rnd):
    for i in range(30):
        try:
            raise Payload("p%d" % i, [i, i + 1], {"i": i})
        except Payload as e:
            a = e.args
            if a[0] != "p%d" % i or a[1] != [i, i + 1] or a[2] != {"i": i}:
                fail("exceptions", rnd, "args %r" % (a,))
                return


def test_bytes(rnd):
    n = 64 + rand(256)
    buf = bytearray()
    for i in range(n):
        buf += bytes([i & 0xFF, (i * 7) & 0xFF])
    if len(buf) != 2 * n:
        fail("bytes", rnd, "length %d" % len(buf))
        return
    want = sum((i & 0xFF) + ((i * 7) & 0xFF) for i in range(n))
    if sum(buf) != want:
        fail("bytes", rnd, "checksum %d != %d" % (sum(buf), want))


def test_explicit_collect(rnd):
    # Objects in local variables across a collection the script asks for:
    keep = ["held%d" % i for i in range(40)]
    table = {i: keep[i] for i in range(40)}
    gc.collect()
    for i in range(40):
        if table[i] != "held%d" % i or keep[i] is not table[i]:
            fail("explicit collect", rnd, "table[%d] = %r" % (i, table[i]))
            return


TESTS = (test_strings, test_dicts, test_nested, test_closures,
         test_generators, test_exceptions, test_bytes, test_explicit_collect)

def fill_heap():
    # Live blocks every collection has to scan and keep:
    blocks = []
    if not hasattr(gc, "mem_free"):  # CPython has no heap to fill
        return blocks
    gc.collect()
    while gc.mem_free() > FREE_TARGET:
        blocks.append(bytes([len(blocks) & 0xFF]) * 1024)
    return blocks


def check_blocks(blocks):
    for i in range(len(blocks)):
        b = blocks[i]
        if b != bytes([i & 0xFF]) * 1024:
            fail("filled heap", 0, "block %d changed" % i)
            return


blocks = fill_heap()
print("GC stress: %d rounds, %d KiB of the heap filled" % (ROUNDS, len(blocks)))
for rnd in range(1, ROUNDS + 1):
    for t in TESTS:
        t(rnd)
    if rnd % 20 == 0:
        print("round %d done, %d failures" % (rnd, failures))

check_blocks(blocks)
if failures:
    print("FAIL: %d failures" % failures)
    sys.exit(1)
print("PASS")
