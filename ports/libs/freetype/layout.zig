// apps/zdos/freetype.zig's types against FreeType's C headers: sizes
// and field offsets, checked at compile time for each CPU (build.sh).
const std = @import("std");
const ft = @import("freetype");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftglyph.h");
});

fn same(comptime Z: type, comptime C: type, comptime fields: []const [2][]const u8) void {
    if (@sizeOf(Z) != @sizeOf(C)) @compileError("size of " ++ @typeName(Z));
    for (fields) |f| {
        if (@offsetOf(Z, f[0]) != @offsetOf(C, f[1])) @compileError(@typeName(Z) ++ "." ++ f[0]);
    }
}

// Each Zig field and its C name:
comptime {
    same(ft.Generic, c.FT_Generic, &.{ .{ "data", "data" }, .{ "finalizer", "finalizer" } });
    same(ft.BBox, c.FT_BBox, &.{ .{ "x_min", "xMin" }, .{ "y_min", "yMin" }, .{ "x_max", "xMax" }, .{ "y_max", "yMax" } });
    same(ft.Vector, c.FT_Vector, &.{ .{ "x", "x" }, .{ "y", "y" } });
    same(ft.Bitmap, c.FT_Bitmap, &.{
        .{ "rows", "rows" },                 .{ "width", "width" },         .{ "pitch", "pitch" },
        .{ "buffer", "buffer" },             .{ "num_grays", "num_grays" }, .{ "pixel_mode", "pixel_mode" },
        .{ "palette_mode", "palette_mode" }, .{ "palette", "palette" },
    });
    same(ft.Outline, c.FT_Outline, &.{
        .{ "n_contours", "n_contours" }, .{ "n_points", "n_points" }, .{ "points", "points" },
        .{ "tags", "tags" },             .{ "contours", "contours" }, .{ "flags", "flags" },
    });
    same(ft.SizeMetrics, c.FT_Size_Metrics, &.{
        .{ "x_ppem", "x_ppem" },     .{ "y_ppem", "y_ppem" },       .{ "x_scale", "x_scale" }, .{ "y_scale", "y_scale" },
        .{ "ascender", "ascender" }, .{ "descender", "descender" }, .{ "height", "height" },   .{ "max_advance", "max_advance" },
    });
    same(ft.SizeRec, c.FT_SizeRec, &.{ .{ "face", "face" }, .{ "generic", "generic" }, .{ "metrics", "metrics" }, .{ "internal", "internal" } });
    same(ft.GlyphMetrics, c.FT_Glyph_Metrics, &.{
        .{ "width", "width" },                 .{ "height", "height" },
        .{ "hori_bearing_x", "horiBearingX" }, .{ "hori_bearing_y", "horiBearingY" },
        .{ "hori_advance", "horiAdvance" },    .{ "vert_bearing_x", "vertBearingX" },
        .{ "vert_bearing_y", "vertBearingY" }, .{ "vert_advance", "vertAdvance" },
    });
    same(ft.CharMapRec, c.FT_CharMapRec, &.{ .{ "face", "face" }, .{ "encoding", "encoding" }, .{ "platform_id", "platform_id" }, .{ "encoding_id", "encoding_id" } });
    same(ft.GlyphSlot, c.FT_GlyphSlotRec, &.{
        .{ "library", "library" },                       .{ "face", "face" },                             .{ "next", "next" },
        .{ "glyph_index", "glyph_index" },               .{ "generic", "generic" },                       .{ "metrics", "metrics" },
        .{ "linear_hori_advance", "linearHoriAdvance" }, .{ "linear_vert_advance", "linearVertAdvance" }, .{ "advance", "advance" },
        .{ "format", "format" },                         .{ "bitmap", "bitmap" },                         .{ "bitmap_left", "bitmap_left" },
        .{ "bitmap_top", "bitmap_top" },                 .{ "outline", "outline" },                       .{ "num_subglyphs", "num_subglyphs" },
        .{ "subglyphs", "subglyphs" },                   .{ "control_data", "control_data" },             .{ "control_len", "control_len" },
        .{ "lsb_delta", "lsb_delta" },                   .{ "rsb_delta", "rsb_delta" },                   .{ "other", "other" },
        .{ "internal", "internal" },
    });
    same(ft.GlyphRec, c.FT_GlyphRec, &.{ .{ "library", "library" }, .{ "clazz", "clazz" }, .{ "format", "format" }, .{ "advance", "advance" } });
    same(ft.BitmapGlyphRec, c.FT_BitmapGlyphRec, &.{ .{ "root", "root" }, .{ "left", "left" }, .{ "top", "top" }, .{ "bitmap", "bitmap" } });
    same(ft.Face, c.FT_FaceRec, &.{
        .{ "num_faces", "num_faces" },                   .{ "face_index", "face_index" },                 .{ "face_flags", "face_flags" },
        .{ "style_flags", "style_flags" },               .{ "num_glyphs", "num_glyphs" },                 .{ "family_name", "family_name" },
        .{ "style_name", "style_name" },                 .{ "num_fixed_sizes", "num_fixed_sizes" },       .{ "available_sizes", "available_sizes" },
        .{ "num_charmaps", "num_charmaps" },             .{ "charmaps", "charmaps" },                     .{ "generic", "generic" },
        .{ "bbox", "bbox" },                             .{ "units_per_em", "units_per_EM" },             .{ "ascender", "ascender" },
        .{ "descender", "descender" },                   .{ "height", "height" },                         .{ "max_advance_width", "max_advance_width" },
        .{ "max_advance_height", "max_advance_height" }, .{ "underline_position", "underline_position" }, .{ "underline_thickness", "underline_thickness" },
        .{ "glyph", "glyph" },                           .{ "size", "size" },                             .{ "charmap", "charmap" },
        .{ "driver", "driver" },                         .{ "memory", "memory" },                         .{ "stream", "stream" },
        .{ "sizes_list", "sizes_list" },                 .{ "autohint", "autohint" },                     .{ "extensions", "extensions" },
        .{ "internal", "internal" },
    });
    if (ft.load_render != c.FT_LOAD_RENDER or ft.face_scalable != c.FT_FACE_FLAG_SCALABLE or ft.face_kerning != c.FT_FACE_FLAG_KERNING or
        ft.load_force_autohint != c.FT_LOAD_FORCE_AUTOHINT or ft.load_target_mono != c.FT_LOAD_TARGET_MONO or
        ft.pixel_mono != c.FT_PIXEL_MODE_MONO or ft.pixel_gray != c.FT_PIXEL_MODE_GRAY)
        @compileError("a FreeType constant differs");
}
