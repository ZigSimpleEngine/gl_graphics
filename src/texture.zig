const std = @import("std");
const gl = @import("gl");

// High-level opaque abstraction over GL ES 3.0 texture objects.
// All fields are considered private (prefixed with `_`).  User code must go
// through getters and the Editor (MethodChain) for mutation, which batches
// GL calls and applies them once in `Editor.apply()` for context-switch
// minimisation.
pub const Texture = struct {
    // ---- opaque state ----
    _id: u32 = 0,
    _target: gl.textures.TextureTarget = .texture_2d,
    _internal_format: ?gl.textures.InternalFormat = null,
    _width: i32 = 0,
    _height: i32 = 0,
    _depth: i32 = 0,
    _levels: i32 = 1,
    _pixel_format: ?gl.textures.PixelFormat = null,
    _data_type: ?gl.enums.DataType = null,
    _min_filter: gl.textures.TextureMinFilter = .nearest_mipmap_linear,
    _mag_filter: gl.textures.TextureMagFilter = .linear,
    _wrap_s: gl.textures.TextureWrap = .repeat,
    _wrap_t: gl.textures.TextureWrap = .repeat,
    _wrap_r: gl.textures.TextureWrap = .repeat,
    _compare_mode: gl.textures.CompareMode = .none,
    _compare_func: gl.textures.CompareFunc = .lequal,
    _base_level: i32 = 0,
    _max_level: i32 = 1000,
    _min_lod: f32 = -1000.0,
    _max_lod: f32 = 1000.0,
    _swizzle_r: gl.textures.Swizzle = .red,
    _swizzle_g: gl.textures.Swizzle = .green,
    _swizzle_b: gl.textures.Swizzle = .blue,
    _swizzle_a: gl.textures.Swizzle = .alpha,
    _has_mipmap: bool = false,
    _active_unit: gl.textures.TextureUnit = .texture0,

    // ------------------------------------------------------------
    // Construction / lifecycle
    // ------------------------------------------------------------
    pub fn init() Texture {
        var id: u32 = 0;
        gl.textures.gen(1, &id);
        return .{ ._id = id };
    }

    pub fn deinit(self: *Texture) void {
        if (self._id != 0) {
            gl.textures.delete(1, &self._id);
            self._id = 0;
        }
    }

    pub fn isValid(self: *const Texture) bool {
        return self._id != 0 and gl.textures.isTexture(self._id);
    }

    // ------------------------------------------------------------
    // Getters — the only way to observe opaque state
    // ------------------------------------------------------------
    pub fn getId(self: *const Texture) u32 { return self._id; }
    pub fn getTarget(self: *const Texture) gl.textures.TextureTarget { return self._target; }
    pub fn getInternalFormat(self: *const Texture) ?gl.textures.InternalFormat { return self._internal_format; }
    pub fn getWidth(self: *const Texture) i32 { return self._width; }
    pub fn getHeight(self: *const Texture) i32 { return self._height; }
    pub fn getDepth(self: *const Texture) i32 { return self._depth; }
    pub fn getLevels(self: *const Texture) i32 { return self._levels; }
    pub fn getPixelFormat(self: *const Texture) ?gl.textures.PixelFormat { return self._pixel_format; }
    pub fn getDataType(self: *const Texture) ?gl.enums.DataType { return self._data_type; }
    pub fn getMinFilter(self: *const Texture) gl.textures.TextureMinFilter { return self._min_filter; }
    pub fn getMagFilter(self: *const Texture) gl.textures.TextureMagFilter { return self._mag_filter; }
    pub fn getWrapS(self: *const Texture) gl.textures.TextureWrap { return self._wrap_s; }
    pub fn getWrapT(self: *const Texture) gl.textures.TextureWrap { return self._wrap_t; }
    pub fn getWrapR(self: *const Texture) gl.textures.TextureWrap { return self._wrap_r; }
    pub fn getCompareMode(self: *const Texture) gl.textures.CompareMode { return self._compare_mode; }
    pub fn getCompareFunc(self: *const Texture) gl.textures.CompareFunc { return self._compare_func; }
    pub fn getBaseLevel(self: *const Texture) i32 { return self._base_level; }
    pub fn getMaxLevel(self: *const Texture) i32 { return self._max_level; }
    pub fn getMinLod(self: *const Texture) f32 { return self._min_lod; }
    pub fn getMaxLod(self: *const Texture) f32 { return self._max_lod; }
    pub fn getSwizzleR(self: *const Texture) gl.textures.Swizzle { return self._swizzle_r; }
    pub fn getSwizzleG(self: *const Texture) gl.textures.Swizzle { return self._swizzle_g; }
    pub fn getSwizzleB(self: *const Texture) gl.textures.Swizzle { return self._swizzle_b; }
    pub fn getSwizzleA(self: *const Texture) gl.textures.Swizzle { return self._swizzle_a; }
    pub fn getHasMipmap(self: *const Texture) bool { return self._has_mipmap; }
    pub fn getActiveUnit(self: *const Texture) gl.textures.TextureUnit { return self._active_unit; }

    // Convenience combined getters
    pub fn getSize(self: *const Texture) struct { w: i32, h: i32, d: i32 } {
        return .{ .w = self._width, .h = self._height, .d = self._depth };
    }
    pub fn getSwizzle(self: *const Texture) [4]gl.textures.Swizzle {
        return .{ self._swizzle_r, self._swizzle_g, self._swizzle_b, self._swizzle_a };
    }

    // Bind helpers (read-only, does not mutate cached state)
    pub fn bind(self: *const Texture) void {
        gl.textures.bind(self._target, self._id);
    }
    pub fn bindToUnit(self: *const Texture, unit: gl.textures.TextureUnit) void {
        gl.textures.activeTexture(unit);
        gl.textures.bind(self._target, self._id);
    }
    pub fn use(self: *const Texture) void { self.bind(); }
    pub fn useUnit(self: *const Texture, unit: gl.textures.TextureUnit) void { self.bindToUnit(unit); }

    // Query GL directly for a parameter (useful for validation, not cached)
    pub fn queryParameterI(self: *const Texture, pname: gl.textures.TextureParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.textures.getParameterI(self._target, pname, &v);
        return v;
    }
    pub fn queryParameterF(self: *const Texture, pname: gl.textures.TextureParameter) f32 {
        self.bind();
        var v: f32 = 0;
        gl.textures.getParameterF(self._target, pname, &v);
        return v;
    }

    // ------------------------------------------------------------
    // Editor — MethodChain deferred apply
    // ------------------------------------------------------------
    pub fn edit(self: *Texture) Editor {
        return Editor.init(self);
    }

    pub const Editor = struct {
        _texture: *Texture,

        // ---- pending batches ----
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

        // sampler params
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

        // generic parameter overrides
        _pending_param_i: ?struct { pname: gl.textures.TextureParameter, param: i32 } = null,
        _pending_param_f: ?struct { pname: gl.textures.TextureParameter, param: f32 } = null,

        pub fn init(texture: *Texture) Editor {
            return .{ ._texture = texture };
        }

        // --------------------------------------------------------
        // MethodChain setters — each returns *Editor
        // --------------------------------------------------------
        pub fn setTarget(self: *Editor, target: gl.textures.TextureTarget) *Editor {
            self._pending_target = target;
            return self;
        }
        pub fn setActiveUnit(self: *Editor, unit: gl.textures.TextureUnit) *Editor {
            self._pending_active_unit = unit;
            return self;
        }
        pub fn setStorage2D(self: *Editor, target: gl.textures.TextureTarget, levels: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32) *Editor {
            self._pending_storage2d = .{ .target = target, .levels = levels, .internalformat = internalformat, .width = width, .height = height };
            return self;
        }
        pub fn setStorage2DSimple(self: *Editor, levels: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32) *Editor {
            const tgt = self._pending_target orelse self._texture._target;
            return self.setStorage2D(tgt, levels, internalformat, width, height);
        }
        pub fn setStorage3D(self: *Editor, target: gl.textures.TextureTarget, levels: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, depth: i32) *Editor {
            self._pending_storage3d = .{ .target = target, .levels = levels, .internalformat = internalformat, .width = width, .height = height, .depth = depth };
            return self;
        }
        pub fn setImage2D(self: *Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, border: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *Editor {
            self._pending_image2d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .border = border, .format = format, .kind = kind, .pixels = pixels };
            return self;
        }
        pub fn setImage3D(self: *Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, depth: i32, border: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *Editor {
            self._pending_image3d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .depth = depth, .border = border, .format = format, .kind = kind, .pixels = pixels };
            return self;
        }
        pub fn setSubImage2D(self: *Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, width: i32, height: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *Editor {
            self._pending_sub2d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .width = width, .height = height, .format = format, .kind = kind, .pixels = pixels };
            return self;
        }
        pub fn setSubImage3D(self: *Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, zoffset: i32, width: i32, height: i32, depth: i32, format: gl.textures.PixelFormat, kind: gl.enums.DataType, pixels: ?*const anyopaque) *Editor {
            self._pending_sub3d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .zoffset = zoffset, .width = width, .height = height, .depth = depth, .format = format, .kind = kind, .pixels = pixels };
            return self;
        }
        pub fn setCompressedImage2D(self: *Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, border: i32, image_size: i32, data: ?*const anyopaque) *Editor {
            self._pending_compressed2d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .border = border, .image_size = image_size, .data = data };
            return self;
        }
        pub fn setCompressedImage3D(self: *Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, width: i32, height: i32, depth: i32, border: i32, image_size: i32, data: ?*const anyopaque) *Editor {
            self._pending_compressed3d = .{ .target = target, .level = level, .internalformat = internalformat, .width = width, .height = height, .depth = depth, .border = border, .image_size = image_size, .data = data };
            return self;
        }
        pub fn setCopyImage2D(self: *Editor, target: gl.textures.TextureTarget, level: i32, internalformat: gl.textures.InternalFormat, x: i32, y: i32, width: i32, height: i32, border: i32) *Editor {
            self._pending_copy2d = .{ .target = target, .level = level, .internalformat = internalformat, .x = x, .y = y, .width = width, .height = height, .border = border };
            return self;
        }
        pub fn setCopySubImage2D(self: *Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, x: i32, y: i32, width: i32, height: i32) *Editor {
            self._pending_copy_sub2d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .x = x, .y = y, .width = width, .height = height };
            return self;
        }
        pub fn setCopySubImage3D(self: *Editor, target: gl.textures.TextureTarget, level: i32, xoffset: i32, yoffset: i32, zoffset: i32, x: i32, y: i32, width: i32, height: i32) *Editor {
            self._pending_copy_sub3d = .{ .target = target, .level = level, .xoffset = xoffset, .yoffset = yoffset, .zoffset = zoffset, .x = x, .y = y, .width = width, .height = height };
            return self;
        }

        pub fn setMinFilter(self: *Editor, filter: gl.textures.TextureMinFilter) *Editor {
            self._pending_min_filter = filter;
            return self;
        }
        pub fn setMagFilter(self: *Editor, filter: gl.textures.TextureMagFilter) *Editor {
            self._pending_mag_filter = filter;
            return self;
        }
        pub fn setWrapS(self: *Editor, wrap: gl.textures.TextureWrap) *Editor {
            self._pending_wrap_s = wrap;
            return self;
        }
        pub fn setWrapT(self: *Editor, wrap: gl.textures.TextureWrap) *Editor {
            self._pending_wrap_t = wrap;
            return self;
        }
        pub fn setWrapR(self: *Editor, wrap: gl.textures.TextureWrap) *Editor {
            self._pending_wrap_r = wrap;
            return self;
        }
        pub fn setWrap(self: *Editor, s: gl.textures.TextureWrap, t: gl.textures.TextureWrap) *Editor {
            self._pending_wrap_s = s;
            self._pending_wrap_t = t;
            return self;
        }
        pub fn setWrapSTR(self: *Editor, s: gl.textures.TextureWrap, t: gl.textures.TextureWrap, r: gl.textures.TextureWrap) *Editor {
            self._pending_wrap_s = s;
            self._pending_wrap_t = t;
            self._pending_wrap_r = r;
            return self;
        }
        pub fn setCompareMode(self: *Editor, mode: gl.textures.CompareMode) *Editor {
            self._pending_compare_mode = mode;
            return self;
        }
        pub fn setCompareFunc(self: *Editor, func: gl.textures.CompareFunc) *Editor {
            self._pending_compare_func = func;
            return self;
        }
        pub fn setBaseLevel(self: *Editor, level: i32) *Editor {
            self._pending_base_level = level;
            return self;
        }
        pub fn setMaxLevel(self: *Editor, level: i32) *Editor {
            self._pending_max_level = level;
            return self;
        }
        pub fn setMinLod(self: *Editor, lod: f32) *Editor {
            self._pending_min_lod = lod;
            return self;
        }
        pub fn setMaxLod(self: *Editor, lod: f32) *Editor {
            self._pending_max_lod = lod;
            return self;
        }
        pub fn setSwizzleR(self: *Editor, swizzle: gl.textures.Swizzle) *Editor {
            self._pending_swizzle_r = swizzle;
            return self;
        }
        pub fn setSwizzleG(self: *Editor, swizzle: gl.textures.Swizzle) *Editor {
            self._pending_swizzle_g = swizzle;
            return self;
        }
        pub fn setSwizzleB(self: *Editor, swizzle: gl.textures.Swizzle) *Editor {
            self._pending_swizzle_b = swizzle;
            return self;
        }
        pub fn setSwizzleA(self: *Editor, swizzle: gl.textures.Swizzle) *Editor {
            self._pending_swizzle_a = swizzle;
            return self;
        }
        pub fn setSwizzle(self: *Editor, r: gl.textures.Swizzle, g: gl.textures.Swizzle, b: gl.textures.Swizzle, a: gl.textures.Swizzle) *Editor {
            self._pending_swizzle_r = r;
            self._pending_swizzle_g = g;
            self._pending_swizzle_b = b;
            self._pending_swizzle_a = a;
            return self;
        }
        pub fn setGenerateMipmap(self: *Editor, gen: bool) *Editor {
            self._pending_generate_mipmap = gen;
            return self;
        }
        // Generic parameter setters covering all gl TexParameter routes
        pub fn setParameterI(self: *Editor, pname: gl.textures.TextureParameter, param: i32) *Editor {
            self._pending_param_i = .{ .pname = pname, .param = param };
            return self;
        }
        pub fn setParameterF(self: *Editor, pname: gl.textures.TextureParameter, param: f32) *Editor {
            self._pending_param_f = .{ .pname = pname, .param = param };
            return self;
        }
        pub fn setBorderColor(self: *Editor, r: f32, g: f32, b: f32, a: f32) *Editor {
            // Not directly a core ES3 texture param but provide convenience
            // Stored as swizzle-like; we use generic path if needed
            _ = r; _ = g; _ = b; _ = a;
            return self;
        }

        // Apply all pending changes in one batched bind
        pub fn apply(self: *Editor) void {
            const tex = self._texture;
            const effective_target = self._pending_target orelse tex._target;

            // Activate unit if requested
            if (self._pending_active_unit) |unit| {
                gl.textures.activeTexture(unit);
                tex._active_unit = unit;
            }
            gl.textures.bind(effective_target, tex._id);

            // Update cached target
            if (self._pending_target) |t| tex._target = t;

            // Storage / image ops — each also updates cached size/format fields
            if (self._pending_storage2d) |s| {
                gl.textures.storage2d(s.target, s.levels, s.internalformat, s.width, s.height);
                tex._internal_format = s.internalformat;
                tex._width = s.width;
                tex._height = s.height;
                tex._levels = s.levels;
                tex._target = s.target;
            }
            if (self._pending_storage3d) |s| {
                gl.textures.storage3d(s.target, s.levels, s.internalformat, s.width, s.height, s.depth);
                tex._internal_format = s.internalformat;
                tex._width = s.width;
                tex._height = s.height;
                tex._depth = s.depth;
                tex._levels = s.levels;
                tex._target = s.target;
            }
            if (self._pending_image2d) |i| {
                gl.textures.image2d(i.target, i.level, i.internalformat, i.width, i.height, i.border, i.format, i.kind, i.pixels);
                tex._internal_format = i.internalformat;
                tex._width = i.width;
                tex._height = i.height;
                tex._pixel_format = i.format;
                tex._data_type = i.kind;
            }
            if (self._pending_image3d) |i| {
                gl.textures.image3d(i.target, i.level, i.internalformat, i.width, i.height, i.depth, i.border, i.format, i.kind, i.pixels);
                tex._internal_format = i.internalformat;
                tex._width = i.width;
                tex._height = i.height;
                tex._depth = i.depth;
                tex._pixel_format = i.format;
                tex._data_type = i.kind;
            }
            if (self._pending_sub2d) |s| {
                gl.textures.subImage2d(s.target, s.level, s.xoffset, s.yoffset, s.width, s.height, s.format, s.kind, s.pixels);
            }
            if (self._pending_sub3d) |s| {
                gl.textures.subImage3d(s.target, s.level, s.xoffset, s.yoffset, s.zoffset, s.width, s.height, s.depth, s.format, s.kind, s.pixels);
            }
            if (self._pending_compressed2d) |c| {
                gl.textures.compressedImage2d(c.target, c.level, c.internalformat, c.width, c.height, c.border, c.image_size, c.data);
                tex._internal_format = c.internalformat;
                tex._width = c.width;
                tex._height = c.height;
            }
            if (self._pending_compressed3d) |c| {
                gl.textures.compressedImage3d(c.target, c.level, c.internalformat, c.width, c.height, c.depth, c.border, c.image_size, c.data);
                tex._internal_format = c.internalformat;
                tex._width = c.width;
                tex._height = c.height;
                tex._depth = c.depth;
            }
            if (self._pending_copy2d) |c| {
                gl.textures.copyImage2d(c.target, c.level, c.internalformat, c.x, c.y, c.width, c.height, c.border);
            }
            if (self._pending_copy_sub2d) |c| {
                gl.textures.copySubImage2d(c.target, c.level, c.xoffset, c.yoffset, c.x, c.y, c.width, c.height);
            }
            if (self._pending_copy_sub3d) |c| {
                gl.textures.copySubImage3d(c.target, c.level, c.xoffset, c.yoffset, c.zoffset, c.x, c.y, c.width, c.height);
            }

            // Sampler parameters — each uses TexParameter
            if (self._pending_min_filter) |f| {
                gl.textures.parameterI(effective_target, .texture_min_filter, @intFromEnum(f));
                tex._min_filter = f;
            }
            if (self._pending_mag_filter) |f| {
                gl.textures.parameterI(effective_target, .texture_mag_filter, @intFromEnum(f));
                tex._mag_filter = f;
            }
            if (self._pending_wrap_s) |w| {
                gl.textures.parameterI(effective_target, .texture_wrap_s, @intFromEnum(w));
                tex._wrap_s = w;
            }
            if (self._pending_wrap_t) |w| {
                gl.textures.parameterI(effective_target, .texture_wrap_t, @intFromEnum(w));
                tex._wrap_t = w;
            }
            if (self._pending_wrap_r) |w| {
                gl.textures.parameterI(effective_target, .texture_wrap_r, @intFromEnum(w));
                tex._wrap_r = w;
            }
            if (self._pending_compare_mode) |m| {
                gl.textures.parameterI(effective_target, .texture_compare_mode, @intFromEnum(m));
                tex._compare_mode = m;
            }
            if (self._pending_compare_func) |f| {
                gl.textures.parameterI(effective_target, .texture_compare_func, @intFromEnum(f));
                tex._compare_func = f;
            }
            if (self._pending_base_level) |v| {
                gl.textures.parameterI(effective_target, .texture_base_level, v);
                tex._base_level = v;
            }
            if (self._pending_max_level) |v| {
                gl.textures.parameterI(effective_target, .texture_max_level, v);
                tex._max_level = v;
            }
            if (self._pending_min_lod) |v| {
                gl.textures.parameterF(effective_target, .texture_min_lod, v);
                tex._min_lod = v;
            }
            if (self._pending_max_lod) |v| {
                gl.textures.parameterF(effective_target, .texture_max_lod, v);
                tex._max_lod = v;
            }
            if (self._pending_swizzle_r) |s| {
                gl.textures.parameterI(effective_target, .texture_swizzle_r, @intFromEnum(s));
                tex._swizzle_r = s;
            }
            if (self._pending_swizzle_g) |s| {
                gl.textures.parameterI(effective_target, .texture_swizzle_g, @intFromEnum(s));
                tex._swizzle_g = s;
            }
            if (self._pending_swizzle_b) |s| {
                gl.textures.parameterI(effective_target, .texture_swizzle_b, @intFromEnum(s));
                tex._swizzle_b = s;
            }
            if (self._pending_swizzle_a) |s| {
                gl.textures.parameterI(effective_target, .texture_swizzle_a, @intFromEnum(s));
                tex._swizzle_a = s;
            }
            if (self._pending_param_i) |p| {
                gl.textures.parameterI(effective_target, p.pname, p.param);
            }
            if (self._pending_param_f) |p| {
                gl.textures.parameterF(effective_target, p.pname, p.param);
            }
            if (self._pending_generate_mipmap) {
                gl.textures.generateMipmap(effective_target);
                tex._has_mipmap = true;
            }

            // Reset pending is not strictly needed as Editor is transient,
            // but clear to allow reuse.
            self.* = Editor.init(tex);
        }
    };
};
