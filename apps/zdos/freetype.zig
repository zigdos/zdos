// FREETYPE.ZDL (ports/libs/freetype) for Zig programs: its export
// table by name, the FreeType types they need and a small layer on top.
// The library is C, called with the C convention (callconv(.c)), not
// ZDOS's own (abi.cc). One copy for every program: the faces and
// their files are the calling program's.
const std = @import("std");
const zdos = @import("zdos.zig");

// SLOTS: exports.def's names in its order (ports/libs/freetype/build.sh
// checks they agree); slot 1 is the first.
const names = [_][]const u8{
    "FT_Init_FreeType", "FT_Done_FreeType", "FT_New_Face", "FT_New_Memory_Face",
    "FT_Open_Face", "FT_Attach_File", "FT_Attach_Stream", "FT_Reference_Face",
    "FT_Done_Face", "FT_Select_Size", "FT_Request_Size", "FT_Set_Char_Size",
    "FT_Set_Pixel_Sizes", "FT_Load_Glyph", "FT_Load_Char", "FT_Set_Transform",
    "FT_Get_Transform", "FT_Render_Glyph", "FT_Get_Kerning",
    "FT_Get_Track_Kerning", "FT_Select_Charmap", "FT_Set_Charmap",
    "FT_Get_Charmap_Index", "FT_Get_Char_Index", "FT_Get_First_Char",
    "FT_Get_Next_Char", "FT_Face_Properties", "FT_Get_Name_Index",
    "FT_Get_Glyph_Name", "FT_Get_Postscript_Name", "FT_Get_SubGlyph_Info",
    "FT_Get_FSType_Flags", "FT_Face_GetCharVariantIndex",
    "FT_Face_GetCharVariantIsDefault", "FT_Face_GetVariantSelectors",
    "FT_Face_GetVariantsOfChar", "FT_Face_GetCharsOfVariant", "FT_MulDiv",
    "FT_MulFix", "FT_DivFix", "FT_RoundFix", "FT_CeilFix", "FT_FloorFix",
    "FT_Vector_Transform", "FT_Library_Version", "FT_Face_CheckTrueTypePatents",
    "FT_Face_SetUnpatentedHinting", "FT_Get_Advance", "FT_Get_Advances",
    "FT_Outline_Get_BBox", "FT_Get_BDF_Charset_ID", "FT_Get_BDF_Property",
    "FT_Bitmap_Init", "FT_Bitmap_New", "FT_Bitmap_Copy", "FT_Bitmap_Embolden",
    "FT_Bitmap_Convert", "FT_Bitmap_Blend", "FT_GlyphSlot_Own_Bitmap",
    "FT_Bitmap_Done", "FT_Stream_OpenBzip2", "FTC_Manager_New",
    "FTC_Manager_Reset", "FTC_Manager_Done", "FTC_Manager_LookupFace",
    "FTC_Manager_LookupSize", "FTC_Node_Unref", "FTC_Manager_RemoveFaceID",
    "FTC_CMapCache_New", "FTC_CMapCache_Lookup", "FTC_ImageCache_New",
    "FTC_ImageCache_Lookup", "FTC_ImageCache_LookupScaler", "FTC_SBitCache_New",
    "FTC_SBitCache_Lookup", "FTC_SBitCache_LookupScaler",
    "FT_Get_CID_Registry_Ordering_Supplement",
    "FT_Get_CID_Is_Internally_CID_Keyed", "FT_Get_CID_From_Glyph_Index",
    "FT_Palette_Data_Get", "FT_Palette_Select",
    "FT_Palette_Set_Foreground_Color", "FT_Get_Color_Glyph_Layer",
    "FT_Get_Color_Glyph_Paint", "FT_Get_Color_Glyph_ClipBox",
    "FT_Get_Paint_Layers", "FT_Get_Colorline_Stops", "FT_Get_Paint",
    "FT_Error_String", "FT_Get_Font_Format", "FT_Get_X11_Font_Format",
    "FT_Get_Gasp", "FT_New_Glyph", "FT_Get_Glyph", "FT_Glyph_Copy",
    "FT_Glyph_Transform", "FT_Glyph_Get_CBox", "FT_Glyph_To_Bitmap",
    "FT_Done_Glyph", "FT_Matrix_Multiply", "FT_Matrix_Invert",
    "FT_TrueTypeGX_Validate", "FT_TrueTypeGX_Free", "FT_ClassicKern_Validate",
    "FT_ClassicKern_Free", "FT_Stream_OpenGzip", "FT_Gzip_Uncompress",
    "FT_Library_SetLcdFilter", "FT_Library_SetLcdFilterWeights",
    "FT_Library_SetLcdGeometry", "FT_List_Find", "FT_List_Add",
    "FT_List_Insert", "FT_List_Remove", "FT_List_Up", "FT_List_Iterate",
    "FT_List_Finalize", "FT_Trace_Set_Level", "FT_Trace_Set_Default_Level",
    "FT_Set_Log_Handler", "FT_Set_Default_Log_Handler", "FT_Stream_OpenLZW",
    "FT_Get_Multi_Master", "FT_Get_MM_Var", "FT_Done_MM_Var",
    "FT_Set_MM_Design_Coordinates", "FT_Set_Var_Design_Coordinates",
    "FT_Get_Var_Design_Coordinates", "FT_Set_MM_Blend_Coordinates",
    "FT_Get_MM_Blend_Coordinates", "FT_Set_Var_Blend_Coordinates",
    "FT_Get_Var_Blend_Coordinates", "FT_Set_MM_WeightVector",
    "FT_Get_MM_WeightVector", "FT_Get_Var_Axis_Flags", "FT_Set_Named_Instance",
    "FT_Get_Default_Named_Instance", "FT_Add_Module", "FT_Get_Module",
    "FT_Remove_Module", "FT_Property_Set", "FT_Property_Get",
    "FT_Set_Default_Properties", "FT_Reference_Library", "FT_New_Library",
    "FT_Done_Library", "FT_Set_Debug_Hook", "FT_Add_Default_Modules",
    "FT_Get_TrueType_Engine_Type", "FT_OpenType_Validate", "FT_OpenType_Free",
    "FT_Outline_Decompose", "FT_Outline_New", "FT_Outline_Done",
    "FT_Outline_Check", "FT_Outline_Get_CBox", "FT_Outline_Translate",
    "FT_Outline_Copy", "FT_Outline_Transform", "FT_Outline_Embolden",
    "FT_Outline_EmboldenXY", "FT_Outline_Reverse", "FT_Outline_Get_Bitmap",
    "FT_Outline_Render", "FT_Outline_Get_Orientation", "FT_Get_PFR_Metrics",
    "FT_Get_PFR_Kerning", "FT_Get_PFR_Advance", "FT_Get_Renderer",
    "FT_Set_Renderer", "FT_New_Size", "FT_Done_Size", "FT_Activate_Size",
    "FT_Get_Sfnt_Name_Count", "FT_Get_Sfnt_Name", "FT_Get_Sfnt_LangTag",
    "FT_Outline_GetInsideBorder", "FT_Outline_GetOutsideBorder",
    "FT_Stroker_New", "FT_Stroker_Set", "FT_Stroker_Rewind",
    "FT_Stroker_ParseOutline", "FT_Stroker_BeginSubPath",
    "FT_Stroker_EndSubPath", "FT_Stroker_LineTo", "FT_Stroker_ConicTo",
    "FT_Stroker_CubicTo", "FT_Stroker_GetBorderCounts",
    "FT_Stroker_ExportBorder", "FT_Stroker_GetCounts", "FT_Stroker_Export",
    "FT_Stroker_Done", "FT_Glyph_Stroke", "FT_Glyph_StrokeBorder",
    "FT_GlyphSlot_Embolden", "FT_GlyphSlot_AdjustWeight",
    "FT_GlyphSlot_Oblique", "FT_GlyphSlot_Slant", "FT_Sin", "FT_Cos", "FT_Tan",
    "FT_Atan2", "FT_Angle_Diff", "FT_Vector_Unit", "FT_Vector_Rotate",
    "FT_Vector_Length", "FT_Vector_Polarize", "FT_Vector_From_Polar",
    "FT_Get_WinFNT_Header", "FT_Has_PS_Glyph_Names", "FT_Get_PS_Font_Info",
    "FT_Get_PS_Font_Private", "FT_Get_PS_Font_Value", "FT_Get_Sfnt_Table",
    "FT_Load_Sfnt_Table", "FT_Sfnt_Table_Info", "FT_Get_CMap_Language_ID",
    "FT_Get_CMap_Format",
};

fn slot(comptime name: []const u8) usize {
    inline for (names, 1..) |n, i| {
        if (comptime std.mem.eql(u8, n, name)) return i;
    }
    @compileError("FREETYPE.ZDL has no " ++ name);
}

var table: ?[*]const usize = null;

// The function of that name, typed F; NotSupported if this
// FREETYPE.ZDL is older than the slot:
fn get(comptime name: []const u8, comptime F: type) Error!F {
    const t = table orelse return error.NotLoaded;
    if (slot(name) > t[0]) return error.NotSupported;
    return @ptrFromInt(t[slot(name)]);
}

// TYPES (fttypes.h, freetype.h, ftimage.h, ftglyph.h)

pub const Pos = c_long; // 26.6 pixels or font units
pub const Fixed = c_long; // 16.16

pub const Generic = extern struct {
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub const BBox = extern struct { x_min: Pos, y_min: Pos, x_max: Pos, y_max: Pos };
pub const Vector = extern struct { x: Pos, y: Pos };
const ListRec = extern struct { head: ?*anyopaque, tail: ?*anyopaque };

pub const Bitmap = extern struct {
    rows: c_uint,
    width: c_uint,
    pitch: c_int,
    buffer: ?[*]u8,
    num_grays: c_ushort,
    pixel_mode: u8,
    palette_mode: u8,
    palette: ?*anyopaque,

    // Coverage 0-255 at column x, row y (gray: as is; mono: 0 or 255):
    pub fn at(self: *const Bitmap, x: usize, y: usize) u8 {
        const buf = self.buffer orelse return 0;
        const row: isize = @as(isize, @intCast(y)) * self.pitch;
        if (self.pixel_mode == pixel_mono) {
            const byte = buf[@intCast(row + @as(isize, @intCast(x / 8)))];
            return if (byte >> @intCast(7 - x % 8) & 1 != 0) 255 else 0;
        }
        return buf[@intCast(row + @as(isize, @intCast(x)))];
    }
};

pub const Outline = extern struct {
    n_contours: c_ushort,
    n_points: c_ushort,
    points: ?[*]Vector,
    tags: ?[*]u8,
    contours: ?[*]c_ushort,
    flags: c_int,
};

pub const SizeMetrics = extern struct {
    x_ppem: c_ushort,
    y_ppem: c_ushort,
    x_scale: Fixed,
    y_scale: Fixed,
    ascender: Pos,
    descender: Pos,
    height: Pos,
    max_advance: Pos,
};

pub const SizeRec = extern struct {
    face: *Face,
    generic: Generic,
    metrics: SizeMetrics,
    internal: ?*anyopaque,
};

pub const GlyphMetrics = extern struct {
    width: Pos,
    height: Pos,
    hori_bearing_x: Pos,
    hori_bearing_y: Pos,
    hori_advance: Pos,
    vert_bearing_x: Pos,
    vert_bearing_y: Pos,
    vert_advance: Pos,
};

pub const CharMapRec = extern struct {
    face: *Face,
    encoding: c_int,
    platform_id: c_ushort,
    encoding_id: c_ushort,
};

pub const GlyphSlot = extern struct {
    library: *Library,
    face: *Face,
    next: ?*GlyphSlot,
    glyph_index: c_uint,
    generic: Generic,
    metrics: GlyphMetrics,
    linear_hori_advance: Fixed,
    linear_vert_advance: Fixed,
    advance: Vector,
    format: c_uint,
    bitmap: Bitmap,
    bitmap_left: c_int,
    bitmap_top: c_int,
    outline: Outline,
    num_subglyphs: c_uint,
    subglyphs: ?*anyopaque,
    control_data: ?*anyopaque,
    control_len: c_long,
    lsb_delta: Pos,
    rsb_delta: Pos,
    other: ?*anyopaque,
    internal: ?*anyopaque,
};

pub const GlyphRec = extern struct {
    library: *Library,
    clazz: ?*const anyopaque,
    format: c_uint,
    advance: Vector,
};

pub const BitmapGlyphRec = extern struct {
    root: GlyphRec,
    left: c_int,
    top: c_int,
    bitmap: Bitmap,
};

// CONSTANTS

pub const load_default: i32 = 0;
pub const load_render: i32 = 1 << 2;
pub const load_force_autohint: i32 = 1 << 5; // FreeType's own hinting
pub const load_target_mono: i32 = 2 << 16; // drawn 1-bit (pixel_mono)
pub const pixel_mono: u8 = 1;
pub const pixel_gray: u8 = 2;
pub const render_normal: c_uint = 0;
pub const face_scalable: c_long = 1 << 0;
pub const face_kerning: c_long = 1 << 6;

pub const LineCap = enum(c_uint) { butt = 0, round = 1, square = 2 };
pub const LineJoin = enum(c_uint) { round = 0, bevel = 1, miter_variable = 2, miter_fixed = 3 };

// ERRORS: FreeType's codes (fterrdef.h) as Zig errors; the code of
// the last one in last_code.

pub const Error = error{
    NotLoaded, // FREETYPE.ZDL missing (load wasn't called or failed)
    NotSupported, // this FREETYPE.ZDL lacks the function
    CannotOpen,
    UnknownFormat,
    InvalidArgument,
    OutOfMemory,
    FreeType, // any other: see last_code
};

pub var last_code: c_int = 0;

fn check(code: c_int) Error!void {
    if (code == 0) return;
    last_code = code;
    return switch (code) {
        0x01 => error.CannotOpen,
        0x02, 0x03 => error.UnknownFormat,
        0x06, 0x10...0x17, 0x20...0x28 => error.InvalidArgument,
        0x40 => error.OutOfMemory,
        else => error.FreeType,
    };
}

// LOADING

pub fn load() Error!void {
    if (table != null) return;
    const t = zdos.loadLibrary("FREETYPE") catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotLoaded,
    };
    table = @ptrCast(@alignCast(t));
}

// THE LIBRARY

pub const Library = opaque {
    pub fn init() Error!*Library {
        try load();
        var lib: ?*Library = null;
        try check((try get("FT_Init_FreeType", *const fn (*?*Library) callconv(.c) c_int))(&lib));
        return lib.?;
    }

    pub fn deinit(self: *Library) Error!void {
        try check((try get("FT_Done_FreeType", *const fn (*Library) callconv(.c) c_int))(self));
    }

    // A module's setting (ftdriver.h), e.g. "truetype",
    // "interpreter-version" with a c_uint 35 or 40:
    pub fn setProperty(self: *Library, module: [*:0]const u8, name: [*:0]const u8, value: *const anyopaque) Error!void {
        const f = try get("FT_Property_Set", *const fn (*Library, [*:0]const u8, [*:0]const u8, *const anyopaque) callconv(.c) c_int);
        try check(f(self, module, name, value));
    }

    pub const Version = struct { major: c_int, minor: c_int, patch: c_int };

    pub fn version(self: *Library) Error!Version {
        var v: Version = undefined;
        (try get("FT_Library_Version", *const fn (*Library, *c_int, *c_int, *c_int) callconv(.c) void))(self, &v.major, &v.minor, &v.patch);
        return v;
    }

    // A font file's face (index: of a collection, 0 for most):
    pub fn openFace(self: *Library, path: []const u8, index: c_long) Error!*Face {
        var buf: [1024]u8 = undefined;
        if (path.len >= buf.len) return error.InvalidArgument;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        var face: ?*Face = null;
        const f = try get("FT_New_Face", *const fn (*Library, [*:0]const u8, c_long, *?*Face) callconv(.c) c_int);
        try check(f(self, buf[0..path.len :0], index, &face));
        return face.?;
    }
};

// A FACE: the font's own fields (FT_FaceRec), and its functions

pub const Face = extern struct {
    num_faces: c_long,
    face_index: c_long,
    face_flags: c_long,
    style_flags: c_long,
    num_glyphs: c_long,
    family_name: ?[*:0]const u8,
    style_name: ?[*:0]const u8,
    num_fixed_sizes: c_int,
    available_sizes: ?*anyopaque,
    num_charmaps: c_int,
    charmaps: ?[*]*CharMapRec,
    generic: Generic,
    bbox: BBox,
    units_per_em: c_ushort,
    ascender: c_short,
    descender: c_short,
    height: c_short,
    max_advance_width: c_short,
    max_advance_height: c_short,
    underline_position: c_short,
    underline_thickness: c_short,
    glyph: *GlyphSlot,
    size: ?*SizeRec,
    charmap: ?*CharMapRec,
    driver: ?*anyopaque,
    memory: ?*anyopaque,
    stream: ?*anyopaque,
    sizes_list: ListRec,
    autohint: Generic,
    extensions: ?*anyopaque,
    internal: ?*anyopaque,

    pub fn deinit(self: *Face) Error!void {
        try check((try get("FT_Done_Face", *const fn (*Face) callconv(.c) c_int))(self));
    }

    pub fn family(self: *const Face) []const u8 {
        return if (self.family_name) |n| std.mem.span(n) else "";
    }

    pub fn style(self: *const Face) []const u8 {
        return if (self.style_name) |n| std.mem.span(n) else "";
    }

    pub fn scalable(self: *const Face) bool {
        return self.face_flags & face_scalable != 0;
    }

    pub fn hasKerning(self: *const Face) bool {
        return self.face_flags & face_kerning != 0;
    }

    // 0 for either: as the other
    pub fn setPixelSizes(self: *Face, width: c_uint, height: c_uint) Error!void {
        try check((try get("FT_Set_Pixel_Sizes", *const fn (*Face, c_uint, c_uint) callconv(.c) c_int))(self, width, height));
    }

    // 0: the font has no glyph for it
    pub fn charIndex(self: *Face, char: u21) Error!c_uint {
        return (try get("FT_Get_Char_Index", *const fn (*Face, c_ulong) callconv(.c) c_uint))(self, char);
    }

    // Into self.glyph; load_render also draws it (self.glyph.bitmap)
    pub fn loadGlyph(self: *Face, index: c_uint, flags: i32) Error!void {
        try check((try get("FT_Load_Glyph", *const fn (*Face, c_uint, i32) callconv(.c) c_int))(self, index, flags));
    }

    pub fn loadChar(self: *Face, char: u21, flags: i32) Error!void {
        try check((try get("FT_Load_Char", *const fn (*Face, c_ulong, i32) callconv(.c) c_int))(self, char, flags));
    }
};

// GLYPHS (ftglyph.h): a copy of the slot's glyph, which may be
// stroked and drawn

pub const Glyph = *GlyphRec;

pub fn getGlyph(slot_: *GlyphSlot) Error!Glyph {
    var g: ?Glyph = null;
    try check((try get("FT_Get_Glyph", *const fn (*GlyphSlot, *?Glyph) callconv(.c) c_int))(slot_, &g));
    return g.?;
}

pub fn doneGlyph(g: Glyph) void {
    const f = get("FT_Done_Glyph", *const fn (Glyph) callconv(.c) void) catch return;
    f(g);
}

// Replaced by its drawing (a BitmapGlyphRec) on success:
pub fn glyphToBitmap(g: *Glyph, mode: c_uint) Error!void {
    const f = try get("FT_Glyph_To_Bitmap", *const fn (*Glyph, c_uint, ?*const Vector, u8) callconv(.c) c_int);
    try check(f(g, mode, null, 1));
}

pub fn bitmapOf(g: Glyph) *BitmapGlyphRec {
    return @ptrCast(@alignCast(g));
}

// STROKER (ftstroke.h): outlines widened, as subtitle borders

pub const Stroker = opaque {
    pub fn init(lib: *Library) Error!*Stroker {
        var s: ?*Stroker = null;
        try check((try get("FT_Stroker_New", *const fn (*Library, *?*Stroker) callconv(.c) c_int))(lib, &s));
        return s.?;
    }

    pub fn deinit(self: *Stroker) void {
        const f = get("FT_Stroker_Done", *const fn (*Stroker) callconv(.c) void) catch return;
        f(self);
    }

    // radius in 26.6 pixels
    pub fn set(self: *Stroker, radius: Fixed, cap: LineCap, join: LineJoin, miter_limit: Fixed) Error!void {
        const f = try get("FT_Stroker_Set", *const fn (*Stroker, Fixed, c_uint, c_uint, Fixed) callconv(.c) void);
        f(self, radius, @intFromEnum(cap), @intFromEnum(join), miter_limit);
    }

    // The glyph replaced by its stroke:
    pub fn stroke(self: *Stroker, g: *Glyph) Error!void {
        try check((try get("FT_Glyph_Stroke", *const fn (*Glyph, *Stroker, u8) callconv(.c) c_int))(g, self, 1));
    }
};

// CACHE (ftcache.h): faces opened on demand by an ID the program
// chooses, glyph indexes kept

pub const FaceId = ?*anyopaque;
pub const Requester = *const fn (FaceId, *Library, ?*anyopaque, *?*Face) callconv(.c) c_int;

pub const CacheManager = opaque {
    pub fn init(lib: *Library, max_faces: c_uint, max_sizes: c_uint, max_bytes: c_ulong, requester: Requester, data: ?*anyopaque) Error!*CacheManager {
        var m: ?*CacheManager = null;
        const f = try get("FTC_Manager_New", *const fn (*Library, c_uint, c_uint, c_ulong, Requester, ?*anyopaque, *?*CacheManager) callconv(.c) c_int);
        try check(f(lib, max_faces, max_sizes, max_bytes, requester, data, &m));
        return m.?;
    }

    pub fn deinit(self: *CacheManager) void {
        const f = get("FTC_Manager_Done", *const fn (*CacheManager) callconv(.c) void) catch return;
        f(self);
    }
};

pub const CMapCache = opaque {
    pub fn init(manager: *CacheManager) Error!*CMapCache {
        var c: ?*CMapCache = null;
        try check((try get("FTC_CMapCache_New", *const fn (*CacheManager, *?*CMapCache) callconv(.c) c_int))(manager, &c));
        return c.?;
    }

    // charmap -1: the face's Unicode one; 0: no glyph
    pub fn lookup(self: *CMapCache, id: FaceId, charmap: c_int, char: u21) Error!c_uint {
        const f = try get("FTC_CMapCache_Lookup", *const fn (*CMapCache, FaceId, c_int, u32) callconv(.c) c_uint);
        return f(self, id, charmap, char);
    }
};

// FT_New_Face itself: a file as a face, for library-level
// callbacks (the cache's requester)
pub fn newFaceRaw(lib: *Library, path: [*:0]const u8, index: c_long, face: *?*Face) c_int {
    const f = get("FT_New_Face", *const fn (*Library, [*:0]const u8, c_long, *?*Face) callconv(.c) c_int) catch return 0x01;
    return f(lib, path, index, face);
}
