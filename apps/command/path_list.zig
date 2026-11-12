// PATH folders, split at ';' or at ':' that isn't a drive's
const std = @import("std");

pub const Iterator = struct {
    value: []const u8,
    index: usize = 0,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.index < self.value.len) {
            const start = self.index;
            while (self.index < self.value.len) : (self.index += 1) {
                const byte = self.value[self.index];
                if (byte == ';' or (byte == ':' and !isDriveColon(self.value, start, self.index))) {
                    const component = self.value[start..self.index];
                    self.index += 1;
                    if (component.len > 0) return component;
                    break;
                }
            } else {
                self.index = self.value.len;
                const component = self.value[start..];
                if (component.len > 0) return component;
            }
        }
        return null;
    }
};

fn isDriveColon(value: []const u8, component_start: usize, colon: usize) bool {
    const prefix = std.mem.trimLeft(u8, value[component_start..colon], " \t");
    return (prefix.len == 1 and std.ascii.isAlphabetic(prefix[0])) or
        (prefix.len == 2 and (prefix[0] == '/' or prefix[0] == '\\') and
        std.ascii.isAlphabetic(prefix[1]));
}
