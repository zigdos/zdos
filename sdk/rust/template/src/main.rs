// A ZDOS program with Rust's std: zdos-cargo build --release
use std::io::{self, BufRead, Write};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    zdos::console::set_color(zdos::Color::Yellow, zdos::Color::Black);
    println!("Hello from Rust on ZDOS!");
    zdos::console::set_color(zdos::Color::LightGray, zdos::Color::Black);
    println!("arguments: {:?}", &args[1..]);
    let info = zdos::system::info();
    println!("{} MB free, {}", info.free_memory >> 20, info.cpu_name);

    print!("Your name: ");
    io::stdout().flush().unwrap();
    let mut name = String::new();
    if io::stdin().lock().read_line(&mut name).is_ok() && !name.trim().is_empty() {
        println!("Hello, {}!", name.trim());
    }
}
