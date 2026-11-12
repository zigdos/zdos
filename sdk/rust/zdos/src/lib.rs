//! What Rust's std lacks on ZDOS: console colors and keys, graphics, mouse,
//! sound and system information. Mirrors `zdos.h` and `zdos_media.h`;
//! change them together.
#![allow(clippy::missing_safety_doc)]

pub mod media;
pub mod raw;

/// The program's version in its header, once at crate level:
/// `zdos::file_version!(1, 2, 0, 0);` (each part 0-255)
#[macro_export]
macro_rules! file_version {
    ($major:literal, $minor:literal, $patch:literal, $build:literal) => {
        core::arch::global_asm!(concat!(
            ".globl zdos_file_version\n.set zdos_file_version, (",
            stringify!($major), ")*16777216+(", stringify!($minor), ")*65536+(",
            stringify!($patch), ")*256+(", stringify!($build), ")\n"
        ));
    };
}

/// The API version the program needs, once at crate level:
/// `zdos::api_version!(2);` (without it 1; a newer one than ZDOS has:
/// the program isn't loaded)
#[macro_export]
macro_rules! api_version {
    ($v:literal) => {
        const _: () = assert!($v >= 1 && $v <= $crate::system::API_VERSION, "zdos::api_version!: not one this SDK has");
        core::arch::global_asm!(concat!(".globl zdos_api_version\n.set zdos_api_version, ", stringify!($v), "\n"));
    };
}

use raw::api;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Black, Blue, Green, Cyan, Red, Magenta, Brown, LightGray,
    DarkGray, LightBlue, LightGreen, LightCyan, LightRed, LightMagenta, Yellow, White,
}

/// `ch` the character (0 for special keys), `scan` a `SCAN_*` code for
/// those, `mods` the `MOD_*` bits held.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Key {
    pub scan: u16,
    pub ch: u16,
    pub mods: u16,
    pad: u16,
}

impl Key {
    pub fn char(&self) -> Option<char> {
        if self.ch == 0 { None } else { char::from_u32(self.ch as u32) }
    }
}

pub const SCAN_UP: u16 = 0x01;
pub const SCAN_DOWN: u16 = 0x02;
pub const SCAN_RIGHT: u16 = 0x03;
pub const SCAN_LEFT: u16 = 0x04;
pub const SCAN_HOME: u16 = 0x05;
pub const SCAN_END: u16 = 0x06;
pub const SCAN_INSERT: u16 = 0x07;
pub const SCAN_DELETE: u16 = 0x08;
pub const SCAN_PAGE_UP: u16 = 0x09;
pub const SCAN_PAGE_DOWN: u16 = 0x0a;
pub const SCAN_F1: u16 = 0x0b; // F1..F10 follow on
pub const SCAN_F11: u16 = 0x15;
pub const SCAN_F12: u16 = 0x16;
pub const SCAN_ESC: u16 = 0x17;
pub const MOD_SHIFT: u16 = 0x0003;
pub const MOD_CTRL: u16 = 0x000C;
pub const MOD_ALT: u16 = 0x0030;

/// Output through std (`print!`) goes to the same screen.
pub mod console {
    use super::*;

    pub fn set_color(fg: Color, bg: Color) {
        unsafe { ((*api().console).set_color)(fg as u8, bg as u8) }
    }
    pub fn clear_screen() {
        unsafe { ((*api().console).clear_screen)() }
    }
    pub fn set_cursor(col: u32, row: u32) {
        unsafe { ((*api().console).set_cursor)(col, row) }
    }
    pub fn cursor() -> (u32, u32) {
        let p = unsafe { ((*api().console).get_cursor)() };
        (p.col, p.row)
    }
    /// Columns and rows.
    pub fn size() -> (u32, u32) {
        let p = unsafe { ((*api().console).screen_size)() };
        (p.col, p.row)
    }
    pub fn show_cursor(visible: bool) {
        unsafe { ((*api().console).show_cursor)(visible) }
    }
    /// The keyboard, not standard input.
    pub fn read_key() -> Key {
        unsafe { ((*api().console).read_key)() }
    }
    /// If one was pressed.
    pub fn poll_key() -> Option<Key> {
        let mut k = Key::default();
        if unsafe { ((*api().console).poll_key)(&mut k) } { Some(k) } else { None }
    }
}

pub mod system {
    use super::*;

    #[derive(Clone, Debug)]
    pub struct Info {
        pub total_memory: u64,
        pub free_memory: u64,
        pub largest_free: u64,
        pub cpu_mhz: u32,
        pub cpu_name: String,
    }

    pub fn info() -> Info {
        let mut i = raw::SystemInfo { os_version: [0; 4], pad0: [0; 4], total_memory: 0, free_memory: 0, largest_free: 0, cpu_mhz: 0, cpu_name_len: 0, pad: [0; 3], cpu_name: [0; 128] };
        unsafe { ((*api().programs).system_info)(&mut i) };
        let n = (i.cpu_name_len as usize).min(i.cpu_name.len());
        Info {
            total_memory: i.total_memory,
            free_memory: i.free_memory,
            largest_free: i.largest_free,
            cpu_mhz: i.cpu_mhz,
            cpu_name: String::from_utf8_lossy(&i.cpu_name[..n]).into_owned(),
        }
    }
    /// Since ZDOS started.
    pub fn millis() -> u64 {
        unsafe { ((*api().time).millis)() }
    }
    /// For programs' jobs (`cores` group); tasks use them all only on metal.
    pub fn cores() -> u32 {
        unsafe { ((*api().cores).count)() }
    }
    /// `zdos.h`'s ZDOS_SDK_API_VERSION
    pub const API_VERSION: u32 = 1;
}

/// x86; without one the calls fail.
pub mod speaker {
    use super::*;

    /// Until the next call; 0: silence.
    pub fn tone(hz: u32) -> bool {
        unsafe { ((*api().sound).tone)(hz) }
    }
    pub fn beep(hz: u32, ms: u32) -> bool {
        unsafe { ((*api().sound).beep)(hz, ms) }
    }
}

/// `ZDOS_ERROR_*` in zdos.h
pub fn last_error() -> u32 {
    unsafe { ((*api().programs).last_error)() }
}
