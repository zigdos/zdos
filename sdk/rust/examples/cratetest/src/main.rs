// Popular crates on ZDOS: prints "ok N - ..." / "not ok N - ...".
use rand::Rng;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Serialize, Deserialize, PartialEq, Debug)]
struct Point {
    x: i32,
    name: String,
    tags: Vec<String>,
}

fn main() {
    let mut n = 0;
    let mut failed = 0;
    let mut check = |name: &str, ok: bool, info: String| {
        n += 1;
        if ok {
            println!("ok {n} - {name}");
        } else {
            failed += 1;
            println!("not ok {n} - {name}: {info}");
        }
    };

    let p = Point { x: 7, name: "zdos".into(), tags: vec!["a".into(), "b".into()] };
    let j = serde_json::to_string(&p).unwrap();
    let back: Point = serde_json::from_str(&j).unwrap();
    check("serde_json", back == p && j.contains("\"x\":7"), j);

    let re = regex::Regex::new(r"(\w+)@(\w+)\.com").unwrap();
    let caps = re.captures("mail alice@example.com now").unwrap();
    check("regex", &caps[1] == "alice" && &caps[2] == "example", format!("{caps:?}"));

    let mut rng = rand::rng();
    let v: Vec<u32> = (0..100).map(|_| rng.random_range(0..10)).collect();
    check("rand", v.iter().all(|&x| x < 10) && v.iter().any(|&x| x != v[0]), format!("{v:?}"));

    let h = Sha256::digest(b"abc");
    let hex: String = h.iter().map(|b| format!("{b:02x}")).collect();
    check("sha2", hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex);

    let now = chrono::Local::now();
    let utc = chrono::Utc::now();
    println!("# chrono local {now} utc {utc}");
    let d = chrono::NaiveDate::from_ymd_opt(2026, 10, 30).unwrap();
    check("chrono", now.timestamp() > 1_700_000_000 && d.format("%A").to_string() == "Friday", now.to_string());

    let (tx, rx) = crossbeam_channel::bounded(4);
    let t = std::thread::spawn(move || (0..1000).for_each(|i| tx.send(i).unwrap()));
    let sum: i64 = rx.iter().sum();
    t.join().unwrap();
    check("crossbeam-channel", sum == 499500, sum.to_string());

    let s: u64 = (0..200_000u64).into_par_iter().map(|x| x % 7).sum();
    check("rayon", s == (0..200_000u64).map(|x| x % 7).sum::<u64>(), format!("{s} on {} threads", rayon::current_num_threads()));

    println!("{n} tests, {failed} failed");
}
