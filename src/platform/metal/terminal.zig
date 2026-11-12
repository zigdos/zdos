// The serial port's ANSI terminal (drivers/serial/terminal.zig)
const serial = @import("serial.zig");
const T = @import("../../drivers/serial/terminal.zig").Terminal(serial);

pub fn init() void {
    serial.init();
}

pub const clear = T.clear;
pub const write = T.write;
pub const clearBelow = T.clearBelow;
pub const getCursor = T.getCursor;
pub const setCursor = T.setCursor;
pub const setColor = T.setColor;
pub const showCursor = T.showCursor;
pub const size = T.size;
pub const pollKey = T.pollKey;
