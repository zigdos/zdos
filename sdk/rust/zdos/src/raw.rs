//! The tables of `zdos.h` this crate uses, each up to its last function
//! used (`Reserved` for the others). Calling convention: Microsoft x64
//! on x86-64, C elsewhere.
use core::ffi::c_void;

#[cfg(target_arch = "x86_64")]
macro_rules! zfn {
    ($($t:tt)*) => { unsafe extern "win64" fn $($t)* };
}
#[cfg(not(target_arch = "x86_64"))]
macro_rules! zfn {
    ($($t:tt)*) => { unsafe extern "C" fn $($t)* };
}

pub type Reserved = usize;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Pos {
    pub col: u32,
    pub row: u32,
}

#[repr(C)]
pub struct SystemInfo {
    pub os_version: [u8; 4],
    pub pad0: [u8; 4],
    pub total_memory: u64,
    pub free_memory: u64,
    pub largest_free: u64,
    pub cpu_mhz: u32,
    pub cpu_name_len: u8,
    pub pad: [u8; 3],
    pub cpu_name: [u8; 128],
}

#[repr(C)]
pub struct Console {
    pub slots: usize,
    pub print: zfn!((*const u8, usize)),
    pub read_key: zfn!(() -> crate::Key),
    pub poll_key: zfn!((*mut crate::Key) -> bool),
    pub edit_line: zfn!((i32)),
    pub reserved_console: [Reserved; 3],
    pub read_input: zfn!((*mut c_void, usize) -> usize),
    pub input_redirected: zfn!(() -> bool),
    pub output_redirected: zfn!(() -> bool),
    pub print_error: zfn!((*const u8, usize)),
    pub error_redirected: zfn!(() -> bool),
    pub clear_screen: zfn!(()),
    pub set_cursor: zfn!((u32, u32)),
    pub get_cursor: zfn!(() -> Pos),
    pub screen_size: zfn!(() -> Pos),
    pub set_color: zfn!((u8, u8)),
    pub show_cursor: zfn!((bool)),
}

#[repr(C)]
pub struct Time {
    pub slots: usize,
    pub millis: zfn!(() -> u64),
    pub sleep: zfn!((u32)),
}

#[repr(C)]
pub struct Programs {
    pub slots: usize,
    pub exec: Reserved,
    pub run_command: Reserved,
    pub exit: Reserved,
    pub program_path: Reserved,
    pub set_ctrl_c: zfn!((bool)),
    pub system_info: zfn!((*mut SystemInfo)),
    pub get_ids: Reserved,
    pub set_ids: Reserved,
    pub load_library: Reserved,
    pub reserved_programs: [Reserved; 2],
    pub get_var: Reserved,
    pub set_var: Reserved,
    pub var_at: Reserved,
    pub reserved_variables: [Reserved; 2],
    pub last_error: zfn!(() -> u32),
}

#[repr(C)]
pub struct Cores {
    pub slots: usize,
    pub count: zfn!(() -> u32),
}

#[repr(C)]
pub struct Sound {
    pub slots: usize,
    pub tone: zfn!((u32) -> bool),
    pub beep: zfn!((u32, u32) -> bool),
}

/// zdos_api, connected by the C library's start-up.
#[repr(C)]
pub struct Api {
    pub console: *const Console,
    pub memory: *const c_void,
    pub files: *const c_void,
    pub drives: *const c_void,
    pub time: *const Time,
    pub programs: *const Programs,
    pub system: *const c_void,
    pub gfx: *const c_void,
    pub disks: *const c_void,
    pub keyb: *const c_void,
    pub cores: *const Cores,
    pub tasks: *const c_void,
    pub threads: *const c_void,
    pub signals: *const c_void,
    pub net: *const c_void,
    pub sound: *const Sound,
}

unsafe extern "C" {
    #[link_name = "zdos"]
    static ZDOS: *const Api;
}

/// Groups not mirrored here are pointers to cast to your own tables.
pub fn api() -> &'static Api {
    unsafe { &*ZDOS }
}
