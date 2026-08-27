const std = @import("std");
const gl = @import("gl");

// High-level opaque abstraction over GL ES 3.0 texture objects.
// The public type is `opaque` — external code cannot see or touch fields
// directly. All interaction goes through methods (`get*`) and the batched
// `Editor` (MethodChain). Internal state lives in `Impl` heap allocated.
const Impl = struct {
    id: u32 = 0,
    target: gl.textures.TextureTarget = .texture_2d,
    internal_format: ?gl.textures.InternalFormat = null,
    width: i32 = 0,
    height: i32 = 0,
    depth: i32 = 0,
    levels: i32 = 1,
    pixel_format: ?gl.textures.PixelFormat = null,
    data_type: ?gl.enums.DataType = null,
    min_filter: gl.textures.TextureMinFilter = .nearest_mipmap_linear,
    mag_filter: gl.textures.TextureMagFilter = .linear,
    wrap_s: gl.textures.TextureWrap = .repeat,
    wrap_t: gl.textures.TextureWrap = .repeat,
    wrap_r: gl.textures.TextureWrap = .repeat,
    compare_mode: gl.textures.CompareMode = .none,
    compare_func: gl.textures.CompareFunc = .lequal,
    base_level: i32 = 0,
    max_level: i32 = 1000,
    min_lod: f32 = -1000.0,
    max_lod: f32 = 1000.0,
    swizzle_r: gl.textures.Swizzle = .red,
    swizzle_g: gl.textures.Swizzle = .green,
    swizzle_b: gl.textures.Swizzle = .blue,
    swizzle_a: gl.textures.Swizzle = .alpha,
    has_mipmap: bool = false,
    active_unit: gl.textures.TextureUnit = .texture0,
};

pub const Texture = opaque {
    inline fn impl(self: *Texture) *Impl {
        return @ptrCast(@alignCast(self));
    }
    inline fn implConst(self: *const Texture) *const Impl {
        return @ptrCast(@alignCast(self));
    }

    // ------------------------------------------------------------
    // Construction / lifecycle — opaque: heap allocated, caller gets *Texture
    // Explicit allocator required per Zig style.
    // ------------------------------------------------------------
    pub fn create(allocator: std.mem.Allocator) !*Texture {
        const m = try allocator.create(Impl);
        m.* = .{};
        var id: u32 = 0;
        if (gl.loader.loaded()) {
            gl.textures.gen(1, @ptrCast(&id));
        } else {
            id = 1;
        }
        m.id = id;
        return @ptrCast(m);
    }

    pub fn init(allocator: std.mem.Allocator) !*Texture {
        return create(allocator);
    }

    pub fn destroy(self: *Texture, allocator: std.mem.Allocator) void {
        const m = self.impl();
        if (m.id != 0) gl.textures.delete(1, @ptrCast(&m.id));
        allocator.destroy(m);
    }

    pub fn deinit(self: *Texture, allocator: std.mem.Allocator) void {
        self.destroy(allocator);
    }

    pub fn isValid(self: *const Texture) bool {
        const m = self.implConst();
        return m.id != 0 and gl.textures.isTexture(m.id);
    }

    // ------------------------------------------------------------
    // Getters — only way to observe state
    // ------------------------------------------------------------
    pub fn getId(self: *const Texture) u32 { return self.implConst().id; }
    pub fn getTarget(self: *const Texture) gl.textures.TextureTarget { return self.implConst().target; }
    pub fn getInternalFormat(self: *const Texture) ?gl.textures.InternalFormat { return self.implConst().internal_format; }
    pub fn getWidth(self: *const Texture) i32 { return self.implConst().width; }
    pub fn getHeight(self: *const Texture) i32 { return self.implConst().height; }
    pub fn getDepth(self: *const Texture) i32 { return self.implConst().depth; }
    pub fn getLevels(self: *const Texture) i32 { return self.implConst().levels; }
    pub fn getPixelFormat(self: *const Texture) ?gl.textures.PixelFormat { return self.implConst().pixel_format; }
    pub fn getDataType(self: *const Texture) ?gl.enums.DataType { return self.implConst().data_type; }
    pub fn getMinFilter(self: *const Texture) gl.textures.TextureMinFilter { return self.implConst().min_filter; }
    pub fn getMagFilter(self: *const Texture) gl.textures.TextureMagFilter { return self.implConst().mag_filter; }
    pub fn getWrapS(self: *const Texture) gl.textures.TextureWrap { return self.implConst().wrap_s; }
    pub fn getWrapT(self: *const Texture) gl.textures.TextureWrap { return self.implConst().wrap_t; }
    pub fn getWrapR(self: *const Texture) gl.textures.TextureWrap { return self.implConst().wrap_r; }
    pub fn getCompareMode(self: *const Texture) gl.textures.CompareMode { return self.implConst().compare_mode; }
    pub fn getCompareFunc(self: *const Texture) gl.textures.CompareFunc { return self.implConst().compare_func; }
    pub fn getBaseLevel(self: *const Texture) i32 { return self.implConst().base_level; }
    pub fn getMaxLevel(self: *const Texture) i32 { return self.implConst().max_level; }
    pub fn getMinLod(self: *const Texture) f32 { return self.implConst().min_lod; }
    pub fn getMaxLod(self: *const Texture) f32 { return self.implConst().max_lod; }
    pub fn getSwizzleR(self: *const Texture) gl.textures.Swizzle { return self.implConst().swizzle_r; }
    pub fn getSwizzleG(self: *const Texture) gl.textures.Swizzle { return self.implConst().swizzle_g; }
    pub fn getSwizzleB(self: *const Texture) gl.textures.Swizzle { return self.implConst().swizzle_b; }
    pub fn getSwizzleA(self: *const Texture) gl.textures.Swizzle { return self.implConst().swizzle_a; }
    pub fn getHasMipmap(self: *const Texture) bool { return self.implConst().has_mipmap; }
    pub fn getActiveUnit(self: *const Texture) gl.textures.TextureUnit { return self.implConst().active_unit; }

    pub fn getSize(self: *const Texture) struct { w: i32, h: i32, d: i32 } {
        const m = self.implConst();
        return .{ .w = m.width, .h = m.height, .d = m.depth };
    }
    pub fn getSwizzle(self: *const Texture) [4]gl.textures.Swizzle {
        const m = self.implConst();
        return .{ m.swizzle_r, m.swizzle_g, m.swizzle_b, m.swizzle_a };
    }

    pub fn bind(self: *const Texture) void {
        const m = self.implConst();
        gl.textures.bind(m.target, m.id);
    }
    pub fn bindToUnit(self: *const Texture, unit: gl.textures.TextureUnit) void {
        gl.textures.activeTexture(unit);
        self.bind();
    }
    pub fn use(self: *const Texture) void { self.bind(); }
    pub fn useUnit(self: *const Texture, unit: gl.textures.TextureUnit) void { self.bindToUnit(unit); }

    pub fn queryParameterI(self: *const Texture, pname: gl.textures.TextureParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.textures.getParameterI(self.implConst().target, pname, @ptrCast(&v));
        return v;
    }
    pub fn queryParameterF(self: *const Texture, pname: gl.textures.TextureParameter) f32 {
        self.bind();
        var v: f32 = 0;
        gl.textures.getParameterF(self.implConst().target, pname, @ptrCast(&v));
        return v;
    }

    pub fn edit(self: *Texture) Editor {
        return Editor.init(self);
    }

    pub const Editor = struct {
        _texture: *Texture,

        _pending_target: ?gl.textures.TextureTarget = null,
        _pending_storage2d: ?struct {
            target: gl.textures.TextureTarget,
            levels: i32,
            internalformat: gl.textures.InternalFormat,
            width: i32,
            height: i32,
        } = null,
        _pending_storage3d: ?struct {
            target: gl.textures.TextureTarget,
            levels: i32,
            internalformat: gl.textures.InternalFormat,
            width: i32,
            height: i32,
            depth: i32,
        } = null,
        _pending_image2d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            internalformat: gl.textures.InternalFormat,
            width: i32,
            height: i32,
            border: i32,
            format: gl.textures.PixelFormat,
            kind: gl.enums.DataType,
            pixels: ?*const anyopaque,
        } = null,
        _pending_image3d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            internalformat: gl.textures.InternalFormat,
            width: i32,
            height: i32,
            depth: i32,
            border: i32,
            format: gl.textures.PixelFormat,
            kind: gl.enums.DataType,
            pixels: ?*const anyopaque,
        } = null,
        _pending_sub2d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            xoffset: i32,
            yoffset: i32,
            width: i32,
            height: i32,
            format: gl.textures.PixelFormat,
            kind: gl.enums.DataType,
            pixels: ?*const anyopaque,
        } = null,
        _pending_sub3d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            xoffset: i32,
            yoffset: i32,
            zoffset: i32,
            width: i32,
            height: i32,
            depth: i32,
            format: gl.textures.PixelFormat,
            kind: gl.enums.DataType,
            pixels: ?*const anyopaque,
        } = null,
        _pending_compressed2d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            internalformat: gl.textures.InternalFormat,
            width: i32,
            height: i32,
            border: i32,
            image_size: i32,
            data: ?*const anyopaque,
        } = null,
        _pending_compressed3d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            internalformat: gl.textures.InternalFormat,
            width: i32,
            height: i32,
            depth: i32,
            border: i32,
            image_size: i32,
            data: ?*const anyopaque,
        } = null,
        _pending_copy2d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            internalformat: gl.textures.InternalFormat,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            border: i32,
        } = null,
        _pending_copy_sub2d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            xoffset: i32,
            yoffset: i32,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        } = null,
        _pending_copy_sub3d: ?struct {
            target: gl.textures.TextureTarget,
            level: i32,
            xoffset: i32,
            yoffset: i32,
            zoffset: i32,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        } = null,

        _pending_min_filter: ?gl.textures.TextureMinFilter = null,
        _pending_mag_filter: ?gl.textures.TextureMagFilter = null,
        _pending_wrap_s: ?gl.textures.TextureWrap = null,
        _pending_wrap_t: ?gl.textures.TextureWrap = null,
        _pending_wrap_r: ?gl.textures.TextureWrap = null,
        _pending_compare_mode: ?gl.textures.CompareMode = null,
        _pending_compare_func: ?gl.textures.CompareFunc = null,
        _pending_base_level: ?i32 = null,
        _pending_max_level: ?i32 = null,
        _pending_min_lod: ?f32 = null,
        _pending_max_lod: ?f32 = null,
        _pending_swizzle_r: ?gl.textures.Swizzle = null,
        _pending_swizzle_g: ?gl.textures.Swizzle = null,
        _pending_swizzle_b: ?gl.textures.Swizzle = null,
        _pending_swizzle_a: ?gl.textures.Swizzle = null,
        _pending_generate_mipmap: bool = false,
        _pending_active_unit: ?gl.textures.TextureUnit = null,
        _pending_param_i: ?struct { pname: gl.textures.TextureParameter, param: i32 } = null,
        _pending_param_f: ?struct { pname: gl.textures.TextureParameter, param: f32 } = null,

        pub fn init(texture: *Texture) Editor {
            return .{ ._texture = texture };
        }

        pub fn setTarget(self: *const Editor, target: gl.textures.TextureTarget) *const Editor { @constCast(self)._pending_target = target; return @constCast(self); }
        pub fn setActiveUnit(self: *const Editor, unit: gl.textures.TextureUnit) *const Editor { @constCast(self)._pending_active_unit = unit; return @constCast(self); }
        pub fn setStorage2D(self: *const Editor, target: gl.textures.TextureTarget, levels: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_storage2d = .{ .target = target, .levels = levels, .internalformat = internalformat, .width = width, .height = height };
            return @constCast(self);
        }
        pub fn setStorage2DSimple(self: *const Editor, levels: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32) *const Editor {
            const tgt = @constCast(self)._pending_target orelse @constCast(self)._texture.implConst().target;
            return self.setStorage2D(tgt, levels, internalformat, width, height);
        }
        pub fn setStorage3D(self: *const Editor, target: gl.textures.TextureTarget, levels: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, depth: i32) *const Editor {
            @constCast(self)._pending_storage3d = .{ .target = target, .levels = levels, .internalformat = internalformat, .width = width, .height = height, .depth = depth };
            return @constCast(self);
        }
        pub fn setImage2D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, border: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *const Editor {
            @constCast(self)._pending_image2d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .border = border, .format = format, .kind = kind, .pixels = pixels };
            return @constCast(self);
        }
        pub fn setImage3D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, depth: i32, border: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *const Editor {
            @constCast(self)._pending_image3d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .depth = depth, .border = border, .format = format, .kind = kind, .pixels = pixels };
            return @constCast(self);
        }
        pub fn setSubImage2D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, width: i32, height: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *const Editor {
            @constCast(self)._pending_sub2d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .width = width, .height = height, .format = format, .kind = kind, .pixels = pixels };
            return @constCast(self);
        }
        pub fn setSubImage3D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, zoffset: i32, width: i32, height: i32, depth: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *const Editor {
            @constCast(self)._pending_sub3d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .zoffset = zoffset, .width = width, .height = height, .depth = depth, .format = format, .kind = kind, .pixels = pixels };
            return @constCast(self);
        }
        pub fn setCompressedImage2D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, border: i32, image_size: i32, data: ?*const anyopaque) *const Editor {
            @constCast(self)._pending_compressed2d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .border = border, .image_size = image_size, .data = data };
            return @constCast(self);
        }
        pub fn setCompressedImage3D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, depth: i32, border: i32, image_size: i32, data: ?*const anyopaque) *const Editor {
            @constCast(self)._pending_compressed3d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .depth = depth, .border = border, .image_size = image_size, .data = data };
            return @constCast(self);
        }
        pub fn setCopyImage2D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, x: i32, y: i32, width: i32, height: i32, border: i32) *const Editor {
            @constCast(self)._pending_copy2d = .{ .target = target, .level = level, .internalformat = internalformat, .x = x, .y = y, .width = width, .height = height, .border = border };
            return @constCast(self);
        }
        pub fn setCopySubImage2D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, x: i32, y: i32, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_copy_sub2d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .x = x, .y = y, .width = width, .height = height };
            return @constCast(self);
        }
        pub fn setCopySubImage3D(self: *const Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, zoffset: i32, x: i32, y: i32, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_copy_sub3d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .zoffset = zoffset, .x = x, .y = y, .width = width, .height = height };
            return @constCast(self);
        }
        pub fn setMinFilter(self: *const Editor, filter: gl.textures.TextureMinFilter) *const Editor { @constCast(self)._pending_min_filter = filter; return @constCast(self); }
        pub fn setMagFilter(self: *const Editor, filter: gl.textures.TextureMagFilter) *const Editor { @constCast(self)._pending_mag_filter = filter; return @constCast(self); }
        pub fn setWrapS(self: *const Editor, wrap: gl.textures.TextureWrap) *const Editor { @constCast(self)._pending_wrap_s = wrap; return @constCast(self); }
        pub fn setWrapT(self: *const Editor, wrap: gl.textures.TextureWrap) *const Editor { @constCast(self)._pending_wrap_t = wrap; return @constCast(self); }
        pub fn setWrapR(self: *const Editor, wrap: gl.textures.TextureWrap) *const Editor { @constCast(self)._pending_wrap_r = wrap; return @constCast(self); }
        pub fn setWrap(self: *const Editor, s: gl.textures.TextureWrap, t: gl.textures.TextureWrap) *const Editor { @constCast(self)._pending_wrap_s = s; @constCast(self)._pending_wrap_t = t; return @constCast(self); }
        pub fn setWrapSTR(self: *const Editor, s: gl.textures.TextureWrap, t: gl.textures.TextureWrap, r: gl.textures.TextureWrap) *const Editor { @constCast(self)._pending_wrap_s = s; @constCast(self)._pending_wrap_t = t; @constCast(self)._pending_wrap_r = r; return @constCast(self); }
        pub fn setCompareMode(self: *const Editor, mode: gl.textures.CompareMode) *const Editor { @constCast(self)._pending_compare_mode = mode; return @constCast(self); }
        pub fn setCompareFunc(self: *const Editor, func: gl.textures.CompareFunc) *const Editor { @constCast(self)._pending_compare_func = func; return @constCast(self); }
        pub fn setBaseLevel(self: *const Editor, level: i32) *const Editor { @constCast(self)._pending_base_level = level; return @constCast(self); }
        pub fn setMaxLevel(self: *const Editor, level: i32) *const Editor { @constCast(self)._pending_max_level = level; return @constCast(self); }
        pub fn setMinLod(self: *const Editor, lod: f32) *const Editor { @constCast(self)._pending_min_lod = lod; return @constCast(self); }
        pub fn setMaxLod(self: *const Editor, lod: f32) *const Editor { @constCast(self)._pending_max_lod = lod; return @constCast(self); }
        pub fn setSwizzleR(self: *const Editor, swizzle: gl.textures.Swizzle) *const Editor { @constCast(self)._pending_swizzle_r = swizzle; return @constCast(self); }
        pub fn setSwizzleG(self: *const Editor, swizzle: gl.textures.Swizzle) *const Editor { @constCast(self)._pending_swizzle_g = swizzle; return @constCast(self); }
        pub fn setSwizzleB(self: *const Editor, swizzle: gl.textures.Swizzle) *const Editor { @constCast(self)._pending_swizzle_b = swizzle; return @constCast(self); }
        pub fn setSwizzleA(self: *const Editor, swizzle: gl.textures.Swizzle) *const Editor { @constCast(self)._pending_swizzle_a = swizzle; return @constCast(self); }
        pub fn setSwizzle(self: *const Editor, r: gl.textures.Swizzle, g: gl.textures.Swizzle, b: gl.textures.Swizzle, a: gl.textures.Swizzle) *const Editor { @constCast(self)._pending_swizzle_r = r; @constCast(self)._pending_swizzle_g = g; @constCast(self)._pending_swizzle_b = b; @constCast(self)._pending_swizzle_a = a; return @constCast(self); }
        pub fn setGenerateMipmap(self: *const Editor, gen: bool) *const Editor { @constCast(self)._pending_generate_mipmap = gen; return @constCast(self); }
        pub fn setParameterI(self: *const Editor, pname: gl.textures.TextureParameter, param: i32) *const Editor { @constCast(self)._pending_param_i = .{ .pname = pname, .param = param }; return @constCast(self); }
        pub fn setParameterF(self: *const Editor, pname: gl.textures.TextureParameter, param: f32) *const Editor { @constCast(self)._pending_param_f = .{ .pname = pname, .param = param }; return @constCast(self); }

        pub fn apply(self: *const Editor) void {
            const m = @constCast(self)._texture.impl();
            const loaded = gl.loader.loaded();
            const effective_target = @constCast(self)._pending_target orelse m.target;
            if (@constCast(self)._pending_active_unit) |unit| {
                if (loaded) gl.textures.activeTexture(unit);
                m.active_unit = unit;
            }
            if (loaded) gl.textures.bind(effective_target, m.id);
            if (@constCast(self)._pending_target) |t| m.target = t;
            if (@constCast(self)._pending_storage2d) |s| {
                if (loaded) gl.textures.storage2d(s.target, s.levels, s.internalformat, s.width, s.height);
                m.internal_format = s.internalformat; m.width = s.width; m.height = s.height; m.levels = s.levels; m.target = s.target;
            }
            if (@constCast(self)._pending_storage3d) |s| {
                if (loaded) gl.textures.storage3d(s.target, s.levels, s.internalformat, s.width, s.height, s.depth);
                m.internal_format = s.internalformat; m.width = s.width; m.height = s.height; m.depth = s.depth; m.levels = s.levels; m.target = s.target;
            }
            if (@constCast(self)._pending_image2d) |i| {
                if (loaded) gl.textures.image2d(i.target, i.level, i.internalformat, i.width, i.height, i.border, i.format, i.kind, i.pixels);
                m.internal_format = i.internalformat; m.width = i.width; m.height = i.height; m.pixel_format = i.format; m.data_type = i.kind;
            }
            if (@constCast(self)._pending_image3d) |i| {
                if (loaded) gl.textures.image3d(i.target, i.level, i.internalformat, i.width, i.height, i.depth, i.border, i.format, i.kind, i.pixels);
                m.internal_format = i.internalformat; m.width = i.width; m.height = i.height; m.depth = i.depth; m.pixel_format = i.format; m.data_type = i.kind;
            }
            if (@constCast(self)._pending_sub2d) |s| if (loaded) gl.textures.subImage2d(s.target, s.level, s.xoffset, s.yoffset, s.width, s.height, s.format, s.kind, s.pixels);
            if (@constCast(self)._pending_sub3d) |s| if (loaded) gl.textures.subImage3d(s.target, s.level, s.xoffset, s.yoffset, s.zoffset, s.width, s.height, s.depth, s.format, s.kind, s.pixels);
            if (@constCast(self)._pending_compressed2d) |c| {
                if (loaded) gl.textures.compressedImage2d(c.target, c.level, c.internalformat, c.width, c.height, c.border, c.image_size, c.data);
                m.internal_format = c.internalformat; m.width = c.width; m.height = c.height;
            }
            if (@constCast(self)._pending_compressed3d) |c| {
                if (loaded) gl.textures.compressedImage3d(c.target, c.level, c.internalformat, c.width, c.height, c.depth, c.border, c.image_size, c.data);
                m.internal_format = c.internalformat; m.width = c.width; m.height = c.height; m.depth = c.depth;
            }
            if (@constCast(self)._pending_copy2d) |c| if (loaded) gl.textures.copyImage2d(c.target, c.level, c.internalformat, c.x, c.y, c.width, c.height, c.border);
            if (@constCast(self)._pending_copy_sub2d) |c| if (loaded) gl.textures.copySubImage2d(c.target, c.level, c.xoffset, c.yoffset, c.x, c.y, c.width, c.height);
            if (@constCast(self)._pending_copy_sub3d) |c| if (loaded) gl.textures.copySubImage3d(c.target, c.level, c.xoffset, c.yoffset, c.zoffset, c.x, c.y, c.width, c.height);
            if (@constCast(self)._pending_min_filter) |f| { if (loaded) gl.textures.parameterI(effective_target, .texture_min_filter, @intCast(@intFromEnum(f))); m.min_filter = f; }
            if (@constCast(self)._pending_mag_filter) |f| { if (loaded) gl.textures.parameterI(effective_target, .texture_mag_filter, @intCast(@intFromEnum(f))); m.mag_filter = f; }
            if (@constCast(self)._pending_wrap_s) |w| { if (loaded) gl.textures.parameterI(effective_target, .texture_wrap_s, @intCast(@intFromEnum(w))); m.wrap_s = w; }
            if (@constCast(self)._pending_wrap_t) |w| { if (loaded) gl.textures.parameterI(effective_target, .texture_wrap_t, @intCast(@intFromEnum(w))); m.wrap_t = w; }
            if (@constCast(self)._pending_wrap_r) |w| { if (loaded) gl.textures.parameterI(effective_target, .texture_wrap_r, @intCast(@intFromEnum(w))); m.wrap_r = w; }
            if (@constCast(self)._pending_compare_mode) |v| { if (loaded) gl.textures.parameterI(effective_target, .texture_compare_mode, @intCast(@intFromEnum(v))); m.compare_mode = v; }
            if (@constCast(self)._pending_compare_func) |v| { if (loaded) gl.textures.parameterI(effective_target, .texture_compare_func, @intCast(@intFromEnum(v))); m.compare_func = v; }
            if (@constCast(self)._pending_base_level) |v| { if (loaded) gl.textures.parameterI(effective_target, .texture_base_level, v); m.base_level = v; }
            if (@constCast(self)._pending_max_level) |v| { if (loaded) gl.textures.parameterI(effective_target, .texture_max_level, v); m.max_level = v; }
            if (@constCast(self)._pending_min_lod) |v| { if (loaded) gl.textures.parameterF(effective_target, .texture_min_lod, v); m.min_lod = v; }
            if (@constCast(self)._pending_max_lod) |v| { if (loaded) gl.textures.parameterF(effective_target, .texture_max_lod, v); m.max_lod = v; }
            if (@constCast(self)._pending_swizzle_r) |s| { if (loaded) gl.textures.parameterI(effective_target, .texture_swizzle_r, @intCast(@intFromEnum(s))); m.swizzle_r = s; }
            if (@constCast(self)._pending_swizzle_g) |s| { if (loaded) gl.textures.parameterI(effective_target, .texture_swizzle_g, @intCast(@intFromEnum(s))); m.swizzle_g = s; }
            if (@constCast(self)._pending_swizzle_b) |s| { if (loaded) gl.textures.parameterI(effective_target, .texture_swizzle_b, @intCast(@intFromEnum(s))); m.swizzle_b = s; }
            if (@constCast(self)._pending_swizzle_a) |s| { if (loaded) gl.textures.parameterI(effective_target, .texture_swizzle_a, @intCast(@intFromEnum(s))); m.swizzle_a = s; }
            if (@constCast(self)._pending_param_i) |p| if (loaded) gl.textures.parameterI(effective_target, p.pname, p.param);
            if (@constCast(self)._pending_param_f) |p| if (loaded) gl.textures.parameterF(effective_target, p.pname, p.param);
            if (@constCast(self)._pending_generate_mipmap) { if (loaded) gl.textures.generateMipmap(effective_target); m.has_mipmap = true; }
            @constCast(self).* = Editor.init(@constCast(self)._texture);
        }
    };
};
