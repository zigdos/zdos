// STDTEST [net HOST:PORT] [loopback]: Rust's std on ZDOS, TAP lines.
// As its own child: "child" or "panic".
use std::collections::HashMap;
use std::io::{BufRead, Read, Seek, SeekFrom, Write};
use std::panic;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Barrier, Condvar, Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, fs, thread};

static COUNT: AtomicUsize = AtomicUsize::new(0);
static FAILED: AtomicUsize = AtomicUsize::new(0);

fn check(name: &str, f: impl FnOnce() -> Result<(), String> + panic::UnwindSafe) {
    let n = COUNT.fetch_add(1, Ordering::SeqCst) + 1;
    match panic::catch_unwind(f) {
        Ok(Ok(())) => println!("ok {n} - {name}"),
        Ok(Err(e)) => {
            FAILED.fetch_add(1, Ordering::SeqCst);
            println!("not ok {n} - {name}: {e}");
        }
        Err(p) => {
            FAILED.fetch_add(1, Ordering::SeqCst);
            let msg = p
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default();
            println!("not ok {n} - {name}: panicked: {msg}");
        }
    }
}

fn ensure(cond: bool, what: impl std::fmt::Display) -> Result<(), String> {
    if cond { Ok(()) } else { Err(what.to_string()) }
}

fn e<T: std::fmt::Debug>(r: T) -> String {
    format!("{r:?}")
}

fn child() -> ! {
    println!("child out");
    eprintln!("child err");
    if let Ok(v) = env::var("ZTEST") {
        println!("ZTEST={v}");
    }
    if env::var("PLATFORM").is_ok() {
        println!("has PLATFORM");
    }
    if env::args().any(|a| a == "stdin") {
        let mut s = String::new();
        std::io::stdin().read_to_string(&mut s).unwrap();
        println!("got {}", s.trim().to_uppercase());
    }
    if env::args().any(|a| a == "cwd") {
        println!("cwd {}", env::current_dir().unwrap().display());
    }
    std::process::exit(7);
}

struct Dropper(&'static AtomicUsize);
impl Drop for Dropper {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}
static TLS_DROPS: AtomicUsize = AtomicUsize::new(0);
thread_local! {
    static TLS_VALUE: std::cell::Cell<u32> = const { std::cell::Cell::new(1) };
    static TLS_DROP: Dropper = Dropper(&TLS_DROPS);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("child") => child(),
        Some("panic") => panic!("boom from the child"),
        Some("abort") => std::process::abort(),
        _ => {}
    }
    let start = Instant::now();
    println!("stdtest on {} {}", env::consts::OS, env::consts::ARCH);

    check("args", || {
        ensure(!args.is_empty() && args[0].to_uppercase().contains("STDTEST"), e(&args))
    });
    check("vars", || {
        let vars: HashMap<String, String> = env::vars().collect();
        ensure(!vars.is_empty(), "no variables")?;
        unsafe { env::set_var("RSTEST_X", "hello there") };
        ensure(env::var("RSTEST_X").as_deref() == Ok("hello there"), "set_var")?;
        ensure(env::vars().any(|(k, v)| k.eq_ignore_ascii_case("RSTEST_X") && v == "hello there"), "vars() after set_var")?;
        unsafe { env::remove_var("RSTEST_X") };
        ensure(env::var("RSTEST_X").is_err(), "remove_var")
    });
    check("current_dir, exe, temp_dir", || {
        let cwd = env::current_dir().map_err(e)?;
        ensure(cwd.is_absolute(), format!("cwd {}", cwd.display()))?;
        let exe = env::current_exe().map_err(e)?;
        ensure(exe.exists(), format!("exe {}", exe.display()))?;
        let _ = env::temp_dir();
        Ok(())
    });

    let dir = env::current_dir().unwrap().join("RSTEST.TMP");
    let _ = fs::remove_dir_all(&dir);
    check("fs write, read, append, seek", || {
        fs::create_dir_all(dir.join("SUB/DEEP")).map_err(e)?;
        let p = dir.join("a.txt");
        fs::write(&p, b"hello\n").map_err(e)?;
        let mut f = fs::OpenOptions::new().append(true).open(&p).map_err(e)?;
        f.write_all(b"world\n").map_err(e)?;
        drop(f);
        let s = fs::read_to_string(&p).map_err(e)?;
        ensure(s == "hello\nworld\n", e(&s))?;
        let mut f = fs::File::options().read(true).write(true).open(&p).map_err(e)?;
        f.seek(SeekFrom::Start(6)).map_err(e)?;
        let mut w = [0u8; 5];
        f.read_exact(&mut w).map_err(e)?;
        ensure(&w == b"world", e(w))?;
        f.set_len(5).map_err(e)?;
        drop(f);
        ensure(fs::read(&p).map_err(e)? == b"hello", "set_len")?;
        let lines: Vec<String> = std::io::BufReader::new(fs::File::open(&p).map_err(e)?).lines().map(|l| l.unwrap()).collect();
        ensure(lines == ["hello"], e(lines))
    });
    check("fs metadata, rename, copy, read_dir", || {
        let p = dir.join("a.txt");
        let m = fs::metadata(&p).map_err(e)?;
        ensure(m.is_file() && m.len() == 5, e(&m))?;
        let modified = m.modified().map_err(e)?;
        let age = SystemTime::now().duration_since(modified).unwrap_or_default();
        ensure(age < Duration::from_secs(3600 * 24), format!("modified {age:?} ago"))?;
        ensure(fs::metadata(&dir).map_err(e)?.is_dir(), "dir metadata")?;
        fs::rename(&p, dir.join("b.txt")).map_err(e)?;
        ensure(!p.exists() && dir.join("b.txt").exists(), "rename")?;
        let n = fs::copy(dir.join("b.txt"), dir.join("SUB/c.txt")).map_err(e)?;
        ensure(n == 5, format!("copied {n}"))?;
        let mut names: Vec<String> =
            fs::read_dir(&dir).map_err(e)?.map(|d| d.unwrap().file_name().to_string_lossy().to_uppercase()).collect();
        names.sort();
        ensure(names == ["B.TXT", "SUB"], e(&names))?;
        for d in fs::read_dir(&dir).map_err(e)? {
            let d = d.map_err(e)?;
            let t = d.file_type().map_err(e)?;
            ensure(t.is_dir() == (d.file_name().to_string_lossy().to_uppercase() == "SUB"), "file_type")?;
        }
        let c = fs::canonicalize(dir.join("SUB/../b.txt")).map_err(e)?;
        ensure(c.is_absolute() && c.ends_with("b.txt") || c.to_string_lossy().to_uppercase().ends_with("B.TXT"), e(&c))
    });
    check("fs File::set_times", || {
        let p = dir.join("t.txt");
        let f = fs::File::create(&p).map_err(e)?;
        (&f).write_all(b"t").map_err(e)?;
        let when = UNIX_EPOCH + Duration::from_secs(1_300_000_000); // even: FAT keeps 2 seconds
        f.set_times(fs::FileTimes::new().set_modified(when)).map_err(e)?;
        ensure(f.metadata().map_err(e)?.modified().map_err(e)? == when, "while open")?;
        f.set_modified(when + Duration::from_secs(60)).map_err(e)?;
        drop(f);
        let m = fs::metadata(&p).map_err(e)?.modified().map_err(e)?;
        ensure(m == when + Duration::from_secs(60), format!("after close: {m:?}"))?;
        fs::remove_file(&p).map_err(e)
    });
    check("fs remove", || {
        fs::write(dir.join("SUB/DEEP/x.bin"), vec![7u8; 10000]).map_err(e)?;
        fs::remove_file(dir.join("b.txt")).map_err(e)?;
        ensure(fs::remove_file(dir.join("b.txt")).map_err(|x| x.kind()) == Err(std::io::ErrorKind::NotFound), "NotFound")?;
        fs::remove_dir_all(&dir).map_err(e)?;
        ensure(!dir.exists(), "remove_dir_all")
    });

    check("thread spawn, join", || {
        let h = thread::spawn(|| 6 * 7);
        ensure(h.join().map_err(|_| "join")? == 42, "result")?;
        let hs: Vec<_> = (0..8).map(|i| thread::spawn(move || i * 2)).collect();
        let sum: i32 = hs.into_iter().map(|h| h.join().unwrap()).sum();
        ensure(sum == 56, sum)
    });
    check("Mutex, Arc", || {
        let m = Arc::new(Mutex::new(0u64));
        let hs: Vec<_> = (0..4)
            .map(|_| {
                let m = m.clone();
                thread::spawn(move || {
                    for _ in 0..5000 {
                        *m.lock().unwrap() += 1;
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        let v = *m.lock().unwrap();
        ensure(v == 20000, v)
    });
    check("Condvar", || {
        let pair = Arc::new((Mutex::new(0u32), Condvar::new()));
        let p2 = pair.clone();
        let h = thread::spawn(move || {
            for i in 1..=100 {
                let (m, c) = &*p2;
                let mut g = m.lock().unwrap();
                while *g != 2 * i - 1 {
                    g = c.wait(g).unwrap();
                }
                *g += 1;
                c.notify_all();
            }
        });
        let (m, c) = &*pair;
        for i in 1..=100 {
            let mut g = m.lock().unwrap();
            while *g != 2 * i - 2 {
                g = c.wait(g).unwrap();
            }
            *g += 1;
            c.notify_all();
        }
        h.join().unwrap();
        let g = m.lock().unwrap();
        ensure(*g == 200, *g)?;
        let t = Instant::now();
        let (_g, r) = c.wait_timeout(g, Duration::from_millis(100)).unwrap();
        ensure(r.timed_out() && t.elapsed() >= Duration::from_millis(90), format!("{:?}", t.elapsed()))
    });
    check("mpsc channels", || {
        let (tx, rx) = mpsc::channel();
        for id in 0..4 {
            let tx = tx.clone();
            thread::spawn(move || {
                for j in 0..100 {
                    tx.send(id * 1000 + j).unwrap();
                }
            });
        }
        drop(tx);
        let got: Vec<i32> = rx.iter().collect();
        ensure(got.len() == 400, got.len())?;
        let (stx, srx) = mpsc::sync_channel(0);
        let h = thread::spawn(move || (0..10).map(|_| srx.recv().unwrap()).sum::<i32>());
        for i in 0..10 {
            stx.send(i).unwrap();
        }
        ensure(h.join().unwrap() == 45, "sync_channel")?;
        let (_tx, rx) = mpsc::channel::<i32>();
        ensure(rx.recv_timeout(Duration::from_millis(50)).is_err(), "recv_timeout")
    });
    check("RwLock, Barrier, OnceLock, scope", || {
        let l = Arc::new(RwLock::new(vec![1, 2, 3]));
        let b = Arc::new(Barrier::new(3));
        static ONCE: OnceLock<u32> = OnceLock::new();
        let hs: Vec<_> = (0..3)
            .map(|i| {
                let (l, b) = (l.clone(), b.clone());
                thread::spawn(move || {
                    let _ = ONCE.get_or_init(|| 10 + i);
                    b.wait();
                    l.write().unwrap().push(i);
                    l.read().unwrap().len()
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        ensure(l.read().unwrap().len() == 6 && ONCE.get().is_some(), "rwlock")?;
        let mut data = [1, 2, 3, 4];
        thread::scope(|s| {
            for x in data.iter_mut() {
                s.spawn(move || *x *= 10);
            }
        });
        ensure(data == [10, 20, 30, 40], e(data))
    });
    check("thread_local, park", || {
        TLS_VALUE.with(|v| v.set(5));
        let before = TLS_DROPS.load(Ordering::SeqCst);
        let other = thread::spawn(|| {
            TLS_DROP.with(|_| {});
            TLS_VALUE.with(|v| v.get())
        })
        .join()
        .unwrap();
        ensure(other == 1 && TLS_VALUE.with(|v| v.get()) == 5, "values")?;
        ensure(TLS_DROPS.load(Ordering::SeqCst) == before + 1, "destructor at thread end")?;
        let t = thread::spawn(|| {
            thread::park();
            1
        });
        thread::sleep(Duration::from_millis(20));
        t.thread().unpark();
        ensure(t.join().unwrap() == 1, "park")?;
        let t = Instant::now();
        thread::park_timeout(Duration::from_millis(30));
        ensure(t.elapsed() >= Duration::from_millis(1), "park_timeout")
    });
    check("timings: contended Mutex, Condvar and park ping-pong", || {
        let m = Arc::new(Mutex::new(0u64));
        let t = Instant::now();
        let hs: Vec<_> = (0..4)
            .map(|_| {
                let m = m.clone();
                thread::spawn(move || {
                    for i in 0..20000 {
                        *m.lock().unwrap() += 1;
                        if i % 64 == 0 {
                            thread::yield_now();
                        }
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        println!("# perf Mutex, 4 threads x 20000: {:?}", t.elapsed());
        ensure(*m.lock().unwrap() == 80000, "count")?;
        let pair = Arc::new((Mutex::new(false), Condvar::new()));
        let p2 = pair.clone();
        let rounds = 5000;
        let t = Instant::now();
        let h = thread::spawn(move || {
            let (m, c) = &*p2;
            for _ in 0..rounds {
                let mut g = m.lock().unwrap();
                while !*g {
                    g = c.wait(g).unwrap();
                }
                *g = false;
                c.notify_one();
            }
        });
        let (m, c) = &*pair;
        for _ in 0..rounds {
            let mut g = m.lock().unwrap();
            while *g {
                g = c.wait(g).unwrap();
            }
            *g = true;
            c.notify_one();
        }
        h.join().unwrap();
        println!("# perf Condvar ping-pong: {:?} per round trip", t.elapsed() / rounds);
        let main = thread::current();
        let flag = Arc::new(AtomicUsize::new(0));
        let f2 = flag.clone();
        let t = Instant::now();
        let h = thread::spawn(move || {
            for i in 0..rounds as usize {
                while f2.load(Ordering::Acquire) != 2 * i + 1 {
                    thread::park();
                }
                f2.store(2 * i + 2, Ordering::Release);
                main.unpark();
            }
        });
        for i in 0..rounds as usize {
            flag.store(2 * i + 1, Ordering::Release);
            h.thread().unpark();
            while flag.load(Ordering::Acquire) != 2 * i + 2 {
                thread::park();
            }
        }
        h.join().unwrap();
        println!("# perf park/unpark ping-pong: {:?} per round trip", t.elapsed() / rounds);
        Ok(())
    });
    check("sleep, Instant, SystemTime", || {
        let t = Instant::now();
        thread::sleep(Duration::from_millis(120));
        let d = t.elapsed();
        ensure(d >= Duration::from_millis(115) && d < Duration::from_secs(5), e(d))?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map_err(e)?;
        ensure(now.as_secs() > 1_700_000_000, e(now))?;
        let n = thread::available_parallelism().map_err(e)?;
        println!("# cores {n}");
        Ok(())
    });

    let exe = env::current_exe().unwrap();
    check("process output, exit code", || {
        let out = Command::new(&exe).arg("child").output().map_err(e)?;
        ensure(out.status.code() == Some(7), e(out.status))?;
        let so = String::from_utf8_lossy(&out.stdout);
        let se = String::from_utf8_lossy(&out.stderr);
        ensure(so.contains("child out") && se.contains("child err"), format!("out {so:?} err {se:?}"))
    });
    check("process stdin, env, cwd", || {
        let mut c = Command::new(&exe)
            .args(["child", "stdin", "cwd"])
            .env("ZTEST", "42")
            .current_dir(env::temp_dir())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(e)?;
        c.stdin.take().unwrap().write_all(b"piped words\n").map_err(e)?;
        let out = c.wait_with_output().map_err(e)?;
        let so = String::from_utf8_lossy(&out.stdout).replace('\r', "");
        ensure(so.contains("got PIPED WORDS"), e(&so))?;
        // tasks->spawn_env: the child gets the variables Command gives it:
        ensure(so.contains("ZTEST=42") && so.contains("has PLATFORM"), format!("env() in the child: {so:?}"))?;
        ensure(out.status.code() == Some(7), e(out.status))?;
        println!("# child: {}", so.lines().filter(|l| l.starts_with("cwd")).collect::<String>());
        Ok(())
    });
    check("process env_clear, set_var reaching the child", || {
        let out = Command::new(&exe).arg("child").env_clear().env("ZTEST", "only").output().map_err(e)?;
        let so = String::from_utf8_lossy(&out.stdout).replace('\r', "");
        ensure(so.contains("ZTEST=only") && !so.contains("has PLATFORM"), format!("env_clear: {so:?}"))?;
        unsafe { env::set_var("ZTEST", "inherited") };
        let out = Command::new(&exe).arg("child").output().map_err(e)?;
        unsafe { env::remove_var("ZTEST") };
        let so = String::from_utf8_lossy(&out.stdout).replace('\r', "");
        ensure(so.contains("ZTEST=inherited"), format!("set_var: {so:?}"))
    });
    check("process status, a ZDOS program", || {
        let st = Command::new(&exe).arg("child").stdout(Stdio::null()).stderr(Stdio::null()).status().map_err(e)?;
        ensure(st.code() == Some(7), e(st))?;
        ensure(Command::new("NO_SUCH_PROGRAM_X").status().is_err(), "missing program")?;
        let out = Command::new("ID").stdin(Stdio::null()).output().map_err(e)?;
        let so = String::from_utf8_lossy(&out.stdout);
        println!("# ID: {}", so.trim());
        ensure(out.status.success() && so.contains("uid="), format!("{:?} {so:?}", out.status))
    });
    check("panic message and exit code", || {
        let caught = panic::catch_unwind(|| panic!("caught here"));
        ensure(caught.is_err(), "catch_unwind")?;
        let out = Command::new(&exe).arg("panic").output().map_err(e)?;
        let se = String::from_utf8_lossy(&out.stderr);
        ensure(out.status.code() == Some(101) && se.contains("boom from the child"), format!("{:?} {se:?}", out.status))?;
        let st = Command::new(&exe).arg("abort").stderr(Stdio::null()).status().map_err(e)?;
        println!("# abort: {st}");
        ensure(!st.success(), e(st))
    });

    // An echo server there (TCP and UDP, answering in capitals) and a
    // client to port 7878 here sending "hello":
    if let Some(i) = args.iter().position(|a| a == "net") {
        let server = args.get(i + 1).cloned().unwrap_or_else(|| "10.0.2.2:7777".into());
        check("net TcpStream", || {
            use std::net::TcpStream;
            let mut s = TcpStream::connect(&server).map_err(e)?;
            s.set_nodelay(true).map_err(e)?;
            s.set_read_timeout(Some(Duration::from_secs(5))).map_err(e)?;
            ensure(s.read_timeout().map_err(e)? == Some(Duration::from_secs(5)), "read_timeout")?;
            s.write_all(b"hello").map_err(e)?;
            let mut buf = [0u8; 5];
            s.read_exact(&mut buf).map_err(e)?;
            ensure(&buf == b"HELLO", e(buf))
        });
        check("net UdpSocket", || {
            use std::net::UdpSocket;
            let u = UdpSocket::bind("0.0.0.0:0").map_err(e)?;
            u.set_read_timeout(Some(Duration::from_secs(5))).map_err(e)?;
            u.send_to(b"ping", &server).map_err(e)?;
            let mut buf = [0u8; 8];
            let (n, from) = u.recv_from(&mut buf).map_err(e)?;
            ensure(&buf[..n] == b"PING", format!("{:?} from {from}", &buf[..n]))
        });
        check("net TcpListener", || {
            use std::net::TcpListener;
            let l = TcpListener::bind("0.0.0.0:7878").map_err(e)?;
            l.set_nonblocking(true).map_err(e)?;
            let t = Instant::now();
            let (mut s, peer) = loop {
                match l.accept() {
                    Ok(c) => break c,
                    Err(x) if x.kind() == std::io::ErrorKind::WouldBlock && t.elapsed() < Duration::from_secs(30) => {
                        thread::sleep(Duration::from_millis(50))
                    }
                    Err(x) => return Err(e(x)),
                }
            };
            s.set_nonblocking(false).map_err(e)?;
            let mut buf = [0u8; 5];
            s.read_exact(&mut buf).map_err(e)?;
            s.write_all(&buf.to_ascii_uppercase()).map_err(e)?;
            println!("# accepted {peer}");
            Ok(())
        });
        check("net lookup", || {
            use std::net::ToSocketAddrs;
            let a: Vec<_> = "localhost:80".to_socket_addrs().map_err(e)?.collect();
            ensure(!a.is_empty(), "localhost")
        });
    }

    // TCP over 127.0.0.1:
    if args.iter().any(|a| a == "loopback") {
        check("net loopback", || {
            use std::net::{TcpListener, TcpStream};
            let l = TcpListener::bind("127.0.0.1:0").map_err(e)?;
            let addr = l.local_addr().map_err(e)?;
            let h = thread::spawn(move || {
                let (mut s, _) = l.accept().unwrap();
                let mut buf = [0u8; 5];
                s.read_exact(&mut buf).unwrap();
                s.write_all(&buf.to_ascii_uppercase()).unwrap();
            });
            let mut s = TcpStream::connect(addr).map_err(e)?;
            s.write_all(b"hello").map_err(e)?;
            let mut buf = [0u8; 5];
            s.read_exact(&mut buf).map_err(e)?;
            h.join().map_err(|_| "server")?;
            ensure(&buf == b"HELLO", e(buf))
        });
    }

    let failed = FAILED.load(Ordering::SeqCst);
    println!("{} tests, {} failed, {:?}", COUNT.load(Ordering::SeqCst), failed, start.elapsed());
    std::process::exit(if failed == 0 { 0 } else { 1 });
}
