//! Graphics, input events and sound: `zdos_media.h`. One display and one
//! sound stream per program.
use core::ffi::c_void;

pub const PIXELS_XRGB8888: i32 = 0;
pub const PIXELS_XBGR8888: i32 = 1;
pub const PIXELS_RGB565: i32 = 2;
pub const PIXELS_INDEX8: i32 = 3;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DisplayInfo {
    pub width: i32,
    pub height: i32,
    pub out_w: i32,
    pub out_h: i32,
    pub true_color: bool,
    pub colors: i32,
}

pub const EVENT_KEY_DOWN: u8 = 1;
pub const EVENT_KEY_UP: u8 = 2;
pub const EVENT_TEXT: u8 = 3;
pub const EVENT_MOUSE_MOTION: u8 = 4;
pub const EVENT_MOUSE_DOWN: u8 = 5;
pub const EVENT_MOUSE_UP: u8 = 6;
pub const EVENT_MOUSE_WHEEL: u8 = 7;
pub const EVENT_FOCUS_GAINED: u8 = 8;
pub const EVENT_FOCUS_LOST: u8 = 9;
pub const MOUSE_LEFT: u32 = 1;
pub const MOUSE_RIGHT: u32 = 2;
pub const MOUSE_MIDDLE: u32 = 4;

/// `kind`: `EVENT_*`; `scancode` a USB HID usage, `code` ZDOS's key code;
/// the mouse in picture pixels.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Event {
    pub kind: u8,
    pub repeat: bool,
    pub scancode: u16,
    pub code: u16,
    pub mods: u16,
    pub x: i32,
    pub y: i32,
    pub dx: i32,
    pub dy: i32,
    pub button: u32,
    pub text: [u8; 8],
}

impl Event {
    /// Of an `EVENT_TEXT`.
    pub fn text(&self) -> &str {
        let n = self.text.iter().position(|&b| b == 0).unwrap_or(8);
        core::str::from_utf8(&self.text[..n]).unwrap_or("")
    }
}

type Fill = unsafe extern "C" fn(*mut c_void, *mut u8, usize);

unsafe extern "C" {
    fn zdos_display_open(width: i32, height: i32, format: i32) -> bool;
    fn zdos_display_palette(first: i32, count: i32, rgb: *const u8);
    fn zdos_display_present(pixels: *const c_void, pitch: i32);
    fn zdos_display_cursor(x: i32, y: i32, shown: bool);
    fn zdos_display_get(info: *mut DisplayInfo);
    fn zdos_display_close();
    fn zdos_input_poll(event: *mut Event) -> bool;
    fn zdos_input_text(on: bool);
    fn zdos_audio_start(rate: u32, channels: u32, bits: u32, frames: u32, fill: Fill, user: *mut c_void) -> bool;
    fn zdos_audio_lock();
    fn zdos_audio_unlock();
    fn zdos_audio_stop();
    fn zdos_aligned_callback(pair: *mut c_void, a: *mut u8, b: usize);
}

/// Back to text when dropped.
pub struct Display {
    width: usize,
    height: usize,
}

impl Display {
    /// Format: `PIXELS_*`. Err with ZDOS's error code.
    pub fn open(width: usize, height: usize, format: i32) -> Result<Display, u32> {
        if unsafe { zdos_display_open(width as i32, height as i32, format) } {
            Ok(Display { width, height })
        } else {
            Err(crate::last_error())
        }
    }
    /// 0x00RRGGBB pixels, rows packed.
    pub fn present(&mut self, pixels: &[u32]) {
        assert!(pixels.len() >= self.width * self.height);
        unsafe { zdos_display_present(pixels.as_ptr().cast(), 0) }
    }
    /// Rows of pitch bytes.
    pub fn present_bytes(&mut self, pixels: &[u8], pitch: usize) {
        assert!(pixels.len() >= pitch * self.height);
        unsafe { zdos_display_present(pixels.as_ptr().cast(), pitch as i32) }
    }
    /// For PIXELS_INDEX8: red, green, blue bytes from first.
    pub fn palette(&mut self, first: usize, rgb: &[u8]) {
        unsafe { zdos_display_palette(first as i32, (rgb.len() / 3) as i32, rgb.as_ptr()) }
    }
    /// Drawn into each picture.
    pub fn cursor(&mut self, x: i32, y: i32, shown: bool) {
        unsafe { zdos_display_cursor(x, y, shown) }
    }
    pub fn info(&self) -> DisplayInfo {
        let mut i = DisplayInfo::default();
        unsafe { zdos_display_get(&mut i) };
        i
    }
}

impl Drop for Display {
    fn drop(&mut self) {
        unsafe { zdos_display_close() }
    }
}

pub fn poll_event() -> Option<Event> {
    let mut e = Event::default();
    if unsafe { zdos_input_poll(&mut e) } { Some(e) } else { None }
}

/// Off at the start.
pub fn text_input(on: bool) {
    unsafe { zdos_input_text(on) }
}

/// A thread calls `fill` for the samples (8-bit unsigned or
/// 16-bit signed, interleaved); stops when dropped.
pub struct Audio {
    _pair: Box<[*mut c_void; 2]>,
    _fill: Box<Box<dyn FnMut(&mut [u8]) + Send>>,
}

unsafe extern "C" fn fill_tramp(user: *mut c_void, buf: *mut u8, len: usize) {
    let f = unsafe { &mut *(user as *mut Box<dyn FnMut(&mut [u8]) + Send>) };
    f(unsafe { core::slice::from_raw_parts_mut(buf, len) });
}

impl Audio {
    /// Err with ZDOS's error code (no card, another program plays).
    pub fn start(rate: u32, channels: u32, bits: u32, frames: u32, fill: impl FnMut(&mut [u8]) + Send + 'static) -> Result<Audio, u32> {
        let mut f: Box<Box<dyn FnMut(&mut [u8]) + Send>> = Box::new(Box::new(fill));
        let user = &mut *f as *mut Box<dyn FnMut(&mut [u8]) + Send> as *mut c_void;
        // Through the C library's realigning helper: i686's C keeps 4-byte
        // stacks, Rust expects 16:
        let mut pair = Box::new([fill_tramp as *mut c_void, user]);
        let p = pair.as_mut_ptr() as *mut c_void;
        let helper: Fill = zdos_aligned_callback;
        if unsafe { zdos_audio_start(rate, channels, bits, frames, helper, p) } {
            Ok(Audio { _pair: pair, _fill: f })
        } else {
            Err(crate::last_error())
        }
    }
    /// While fill is held off.
    pub fn locked<R>(&self, f: impl FnOnce() -> R) -> R {
        unsafe { zdos_audio_lock() };
        let r = f();
        unsafe { zdos_audio_unlock() };
        r
    }
}

impl Drop for Audio {
    fn drop(&mut self) {
        unsafe { zdos_audio_stop() }
    }
}
