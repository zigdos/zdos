// QJS C:\SCRIPTS\JSDEMO.JS: checks the QuickJS port on ZDOS.
// Each check prints ok or FAILED; the last line counts them, the exit
// code is 1 if any failed. Its files go into the TEMP folder, made if
// missing (without TEMP the current one), with / between folders.
import * as std from "qjs:std";
import * as os from "qjs:os";

let passed = 0, failed = 0;

function check(name, got, want) {
  if (got === want) {
    passed++;
    console.log("ok      " + name);
  } else {
    failed++;
    console.log("FAILED  " + name + ": got " + String(got) + ", want " + String(want));
  }
}

// NUMBERS AND MATH
// (the SDK's libm and zig's runtime)
check("integer sum", 1 + 2 + 3, 6);
check("float sum", 0.1 + 0.2, 0.30000000000000004);
check("power", 2 ** 10, 1024);
check("remainder", -7 % 3, -1);
check("safe integer", Number.MAX_SAFE_INTEGER, 9007199254740991);
check("sqrt", Math.sqrt(16), 4);
check("sin(0)", Math.sin(0), 0);
check("atan2(1,1) is pi/4", Math.abs(Math.atan2(1, 1) - Math.PI / 4) < 1e-12, true);
check("exp and log", Math.abs(Math.log(Math.exp(5)) - 5) < 1e-12, true);
check("toFixed", (1234.5678).toFixed(2), "1234.57");
check("toString(2)", (255).toString(2), "11111111");
check("parseFloat", parseFloat("3.25e2"), 325);
check("BigInt power", (2n ** 100n).toString(), "1267650600228229401496703205376");
check("BigInt division", 10n ** 30n / 7n, 142857142857142857142857142857n);

// STRINGS AND REGULAR EXPRESSIONS
check("template", `${"zd"}${"os"}`, "zdos");
check("padStart", "7".padStart(3, "0"), "007");
check("upper case", "Straße".toUpperCase(), "STRASSE");
check("code points", [..."héllo👍"].length, 6);
check("named groups", "2026-11-14".match(/(?<y>\d+)-(?<m>\d+)/).groups.m, "11");
check("unicode property", "Ünï Ωm".match(/\p{Lu}/gu).join(""), "ÜΩ");
check("replace with a function", "a-b_c".replace(/[-_](.)/g, (_, c) => c.toUpperCase()), "aBC");

// OBJECTS, CLASSES, COLLECTIONS
class Counter { #n = 0; inc() { return ++this.#n; } static of(n) { const c = new Counter(); while (n--) c.inc(); return c; } }
check("class with a private field", Counter.of(3).inc(), 4);
const { a, ...rest } = { a: 1, b: 2, c: 3 };
check("destructuring", a + Object.keys(rest).join(""), "1bc");
check("JSON round trip", JSON.stringify(JSON.parse('{"x":[1,{"y":null}],"s":"q\\""}')), '{"x":[1,{"y":null}],"s":"q\\""}');
check("Map", new Map([[1, "one"], [2, "two"]]).get(2), "two");
check("Set", [...new Set("mississippi")].join(""), "misp");
check("sort numbers", [5, 1, 10, 2].sort((x, y) => x - y).join(), "1,2,5,10");
check("flat", [1, [2, [3]]].flat(Infinity).join(), "1,2,3");
check("optional chaining", ({}).x?.y ?? "none", "none");
check("Proxy", new Proxy({}, { get: (t, k) => k + "!" }).word, "word!");
function* gen() { yield 1; yield 2; return 3; }
check("generator", [...gen()].join(), "1,2");
let caught = "";
try { null.x; } catch (e) { caught = e.constructor.name; }
check("TypeError caught", caught, "TypeError");

// PROMISES, GENERATORS, BIGINT
const order = [];
(async () => { order.push(1); await null; order.push(3); await new Promise((r) => r()); order.push(5); })();
Promise.resolve().then(() => order.push(4));
order.push(2);
await os.sleepAsync(10); // a timer: after every promise's step
check("async ordering", order.join(""), "12345");
function* fib() { let [a, b] = [0n, 1n]; for (;;) { yield a; [a, b] = [b, a + b]; } }
let f100 = 0n, n = 0;
for (const x of fib()) { if (n++ === 99) { f100 = x; break; } }
check("BigInt generator: fib(99)", f100.toString(), "218922995834555169026");
check("BigInt modulo", (2n ** 200n % 1000000007n).toString(), "499445072");
check("BigInt.asUintN", BigInt.asUintN(64, -1n).toString(16), "ffffffffffffffff");

// TYPED ARRAYS
const dv = new DataView(new ArrayBuffer(8));
dv.setUint32(0, 0xdeadbeef);
check("DataView big-endian", dv.getUint8(0), 0xde);
check("Float64Array", new Float64Array([1.5, 2.25]).reduce((x, y) => x + y), 3.75);

// DATE
check("Date.UTC to ISO", new Date(Date.UTC(2026, 10, 14, 12, 30)).toISOString(), "2026-11-14T12:30:00.000Z");
check("this year is recent", new Date().getFullYear() >= 2025, true);

// FILES AND FOLDERS (std, os)
const temp = std.getenv("TEMP") ?? ".";
const dir = temp + "/JSDEMO.TMP";
os.mkdir(temp); // TEMP=\TEMP is on the current drive: maybe not there yet
check("make a folder", os.mkdir(dir), 0);
const name = dir + "/LINES.TXT";
const f = std.open(name, "w");
for (let i = 0; i < 100; i++) f.printf("%d line\n", i);
f.close();
check("loadFile", std.loadFile(name).split("\n").length, 101);
check("stat size", os.stat(name)[0]?.size, 790);
const r = std.open(name, "r");
r.seek(-8, std.SEEK_END);
check("seek from the end", r.getline(), "99 line");
r.close();
std.writeFile(dir + "/BIN.DAT", new Uint8Array([0, 1, 254, 255]));
check("binary file", new Uint8Array(std.loadFile(dir + "/BIN.DAT", { binary: true }))[2], 254);
check("rename", os.rename(name, dir + "/MOVED.TXT"), 0);
check("readdir", os.readdir(dir)[0].filter(n => n[0] != ".").map(n => n.toUpperCase()).sort().join(), "BIN.DAT,MOVED.TXT");
// a module written here, imported
std.writeFile(dir + "/MOD.JS", "export const answer = 6 * 7;");
check("import a module", (await import(dir + "/MOD.JS")).answer, 42);
for (const n of ["MOVED.TXT", "BIN.DAT", "MOD.JS"]) os.remove(dir + "/" + n);
check("remove the folder", os.remove(dir), 0);
check("folder gone", os.stat(dir)[1] != 0, true);

// ENVIRONMENT, TIMERS, PROGRAMS, THREADS
check("getenv of a missing name", std.getenv("ZDOS_NO_SUCH_NAME"), undefined);
const fired = [];
os.setTimeout(() => fired.push("b"), 40);
os.setTimeout(() => fired.push("a"), 0);
await os.sleepAsync(100);
check("timers in order", fired.join(""), "ab");
// another program (this one, found by PATH): its exit code
check("os.exec's exit code", os.exec(["qjs", "--std", "-e", "std.exit(5)"]), 5);
// another program's output and errors into files (-e, an uncaught error)
const outName = temp + "/JSOUT.TXT", errName = temp + "/JSERR.TXT";
let fd = os.open(outName, os.O_WRONLY | os.O_CREAT | os.O_TRUNC);
check("a child's output redirected", os.exec(["qjs", "-e", "console.log('from child', 6 * 7)"], { stdout: fd }), 0);
os.close(fd);
check("what the child wrote", std.loadFile(outName).trim(), "from child 42");
fd = os.open(errName, os.O_WRONLY | os.O_CREAT | os.O_TRUNC);
check("an uncaught error: exit code not 0", os.exec(["qjs", "-e", "throw new RangeError('boom ' + 42)"], { stderr: fd }) !== 0, true);
os.close(fd);
check("the uncaught error on standard error", std.loadFile(errName).includes("RangeError: boom 42"), true);
os.remove(outName);
os.remove(errName);
// a worker thread, from a file written here
const workerFile = temp + "/JSWORKER.JS";
std.writeFile(workerFile, `import * as os from "qjs:os";
const p = os.Worker.parent;
p.onmessage = (e) => { let s = 0; for (let i = 1; i <= e.data; i++) s += i; p.postMessage(s); };`);
const sum = await new Promise((resolve) => {
  const w = new os.Worker(workerFile);
  w.onmessage = (e) => { w.onmessage = null; resolve(e.data); };
  w.postMessage(1000);
});
os.remove(workerFile);
check("worker thread", sum, 500500);

console.log("");
console.log(`${passed} passed, ${failed} failed`);
std.exit(failed == 0 ? 0 : 1);
