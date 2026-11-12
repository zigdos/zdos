// The zdos crate's graphics and input: a moving pattern until a key,
// a click or 5 seconds, then what came in.
use std::time::{Duration, Instant};
use zdos::media::{self, Display, PIXELS_XRGB8888};

fn main() {
    const W: usize = 320;
    const H: usize = 200;
    let mut d = match Display::open(W, H, PIXELS_XRGB8888) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("no graphics (ZDOS error {e})");
            std::process::exit(1);
        }
    };
    let info = d.info();
    let mut px = vec![0u32; W * H];
    let start = Instant::now();
    let mut events = Vec::new();
    let mut t = 0u32;
    while start.elapsed() < Duration::from_secs(5) {
        for y in 0..H {
            for x in 0..W {
                let r = (x as u32 + t) & 255;
                let g = (y as u32 * 255 / H as u32) & 255;
                let b = ((x ^ y) as u32 + t * 2) & 255;
                px[y * W + x] = r << 16 | g << 8 | b;
            }
        }
        d.present(&px);
        let mut done = false;
        while let Some(e) = media::poll_event() {
            done |= e.kind == media::EVENT_KEY_DOWN || e.kind == media::EVENT_MOUSE_DOWN;
            events.push(e.kind);
        }
        if done {
            break;
        }
        t += 4;
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(d);
    println!("display {}x{} -> {}x{}, true color {}; {} frames; events {:?}", info.width, info.height, info.out_w, info.out_h, info.true_color, t / 4 + 1, events);
}
