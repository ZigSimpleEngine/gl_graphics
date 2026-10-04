/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");

/// Local aliases for GL types used by this wrapper, so signatures and bodies
/// stay short without fully qualified `gl.*` type paths.
const RenderbufferTarget = gl.renderbuffers.RenderbufferTarget;
const RenderbufferParameter = gl.renderbuffers.RenderbufferParameter;
const InternalFormat = gl.textures.InternalFormat;

/// Internal implementation storage for an opaque Renderbuffer handle.
/// Holds OpenGL object state and cached storage parameters.
const Impl = struct {
    /// OpenGL renderbuffer object identifier.
    id: u32 = 0,
    /// Target binding point for this renderbuffer.
    target: RenderbufferTarget = .renderbuffer,
    /// Sized internal format of the storage, if allocated.
    internal_format: ?InternalFormat = null,
    /// Width of the storage in pixels.
    width: i32 = 0,
    /// Height of the storage in pixels.
    height: i32 = 0,
    /// Sample count of the storage. Zero means non-multisampled.
    samples: i32 = 0,
};

/// Opaque renderbuffer object with builder-style editing.
///
/// A renderbuffer is a non-samplable image usable as a framebuffer
/// attachment (color, depth or stencil), including multisampled storage
/// for MSAA render targets. Attach it with
/// `Framebuffer.edit().setRenderbuffer(attachment, rb.getId())` and
/// resolve multisampled content via `gl.framebuffers.blit`.
pub const Renderbuffer = opaque {
    /// Returns mutable implementation pointer for this handle.
    /// Parameters:
    /// - self: mutable opaque renderbuffer pointer.
    ///
    /// Returns: pointer to internal Impl.
    inline fn impl(self: *Renderbuffer) *Impl {
        return @ptrCast(@alignCast(self));
    }
    /// Returns immutable implementation pointer for this handle.
    /// Parameters:
    /// - self: const opaque renderbuffer pointer.
    ///
    /// Returns: pointer to const Impl.
    inline fn implConst(self: *const Renderbuffer) *const Impl {
        return @ptrCast(@alignCast(self));
    }

    /// Creates a new renderbuffer object.
    /// Parameters:
    /// - allocator: allocator used to allocate Impl storage.
    ///
    /// Returns: pointer to created Renderbuffer or allocation error.
    pub fn create(allocator: std.mem.Allocator) !*Renderbuffer {
        const m = try allocator.create(Impl);
        m.* = .{};
        var id: u32 = 0;
        if (gl.loader.loaded()) {
            gl.renderbuffers.gen(1, @ptrCast(&id));
        } else {
            id = 1;
        }
        m.id = id;
        return @ptrCast(m);
    }
    /// Destroys the renderbuffer and frees Impl storage.
    /// Parameters:
    /// - self: renderbuffer to destroy.
    /// - allocator: allocator that was used for creation.
    ///
    /// Returns: void.
    pub fn destroy(self: *Renderbuffer, allocator: std.mem.Allocator) void {
        const m = self.impl();
        if (gl.loader.loaded() and m.id != 0) gl.renderbuffers.delete(1, @ptrCast(&m.id));
        allocator.destroy(m);
    }
    /// Checks whether the underlying OpenGL renderbuffer object is valid.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: true if the renderbuffer exists.
    pub fn isValid(self: *const Renderbuffer) bool {
        const m = self.implConst();
        return m.id != 0 and gl.renderbuffers.isRenderbuffer(m.id);
    }

    /// Returns the OpenGL identifier for this renderbuffer.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: OpenGL renderbuffer id.
    pub fn getId(self: *const Renderbuffer) u32 {
        return self.implConst().id;
    }
    /// Returns the current binding target.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: renderbuffer target enum.
    pub fn getTarget(self: *const Renderbuffer) RenderbufferTarget {
        return self.implConst().target;
    }
    /// Returns the cached internal format, if storage was allocated.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: optional internal format; null if no storage yet.
    pub fn getInternalFormat(self: *const Renderbuffer) ?InternalFormat {
        return self.implConst().internal_format;
    }
    /// Returns the cached width.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: width in pixels.
    pub fn getWidth(self: *const Renderbuffer) i32 {
        return self.implConst().width;
    }
    /// Returns the cached height.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: height in pixels.
    pub fn getHeight(self: *const Renderbuffer) i32 {
        return self.implConst().height;
    }
    /// Returns the cached sample count.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: sample count; 0 means non-multisampled storage.
    pub fn getSamples(self: *const Renderbuffer) i32 {
        return self.implConst().samples;
    }
    /// Returns the cached storage size.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: anonymous struct with fields `w` and `h`.
    pub fn getSize(self: *const Renderbuffer) struct { w: i32, h: i32 } {
        const m = self.implConst();
        return .{ .w = m.width, .h = m.height };
    }
    /// Returns true when the cached storage is multisampled.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: true when sample count is greater than zero.
    pub fn isMultisampled(self: *const Renderbuffer) bool {
        return self.implConst().samples > 0;
    }

    /// Binds this renderbuffer to its stored target.
    /// Parameters:
    /// - self: renderbuffer to bind.
    ///
    /// Returns: void.
    pub fn bind(self: *const Renderbuffer) void {
        const m = self.implConst();
        gl.renderbuffers.bind(m.target, m.id);
    }
    /// Binds this renderbuffer to an explicit target.
    /// Parameters:
    /// - self: renderbuffer to bind.
    /// - target: renderbuffer target to bind to.
    ///
    /// Returns: void.
    pub fn bindTo(self: *const Renderbuffer, target: RenderbufferTarget) void {
        gl.renderbuffers.bind(target, self.implConst().id);
    }
    /// Binds this renderbuffer for use as current renderbuffer.
    /// Parameters:
    /// - self: renderbuffer to use.
    ///
    /// Returns: void.
    pub fn use(self: *const Renderbuffer) void {
        self.bind();
    }

    /// Queries a renderbuffer parameter from GL after binding.
    /// Parameters:
    /// - self: renderbuffer to query.
    /// - pname: parameter name to query.
    ///
    /// Returns: integer value of the parameter.
    pub fn queryParameter(self: *const Renderbuffer, pname: RenderbufferParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.renderbuffers.getParameter(self.implConst().target, pname, @ptrCast(&v));
        return v;
    }
    /// Queries the storage width from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: width in pixels as reported by GL.
    pub fn queryWidth(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_width);
    }
    /// Queries the storage height from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: height in pixels as reported by GL.
    pub fn queryHeight(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_height);
    }
    /// Queries the sample count from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: sample count as reported by GL.
    pub fn querySamples(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_samples);
    }
    /// Queries the internal format from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: internal format as reported by GL.
    pub fn queryInternalFormat(self: *const Renderbuffer) InternalFormat {
        return @enumFromInt(@as(u32, @intCast(self.queryParameter(.renderbuffer_internal_format))));
    }
    /// Queries the red component resolution from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: red size in bits as reported by GL.
    pub fn queryRedSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_red_size);
    }
    /// Queries the green component resolution from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: green size in bits as reported by GL.
    pub fn queryGreenSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_green_size);
    }
    /// Queries the blue component resolution from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: blue size in bits as reported by GL.
    pub fn queryBlueSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_blue_size);
    }
    /// Queries the alpha component resolution from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: alpha size in bits as reported by GL.
    pub fn queryAlphaSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_alpha_size);
    }
    /// Queries the depth component resolution from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: depth size in bits as reported by GL.
    pub fn queryDepthSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_depth_size);
    }
    /// Queries the stencil component resolution from GL.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: stencil size in bits as reported by GL.
    pub fn queryStencilSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_stencil_size);
    }

    /// Returns the maximum supported sample count (`GL_MAX_SAMPLES`).
    /// Parameters: none.
    ///
    /// Returns: maximum samples per pixel, or 0 when GL is not loaded.
    pub fn maxSamples() i32 {
        if (!gl.loader.loaded()) return 0;
        var v: i32 = 0;
        gl.state.getInteger(.max_samples, @ptrCast(&v));
        return v;
    }

    /// Returns an editor for batched renderbuffer mutation.
    /// Parameters:
    /// - self: renderbuffer to edit.
    ///
    /// Returns: Editor instance referencing this renderbuffer.
    pub fn edit(self: *Renderbuffer) Editor {
        return Editor.init(self);
    }

    /// Builder for deferred renderbuffer state changes.
    pub const Editor = struct {
        /// Reference to the renderbuffer being edited.
        _rb: *Renderbuffer,
        /// Pending target change if any.
        _pending_target: ?RenderbufferTarget = null,
        /// Pending plain storage allocation.
        _pending_storage: ?struct { internalformat: InternalFormat, width: i32, height: i32 } = null,
        /// Pending multisampled storage allocation. Wins over plain
        /// storage when both are queued in the same batch.
        _pending_storage_multisample: ?struct { samples: i32, internalformat: InternalFormat, width: i32, height: i32 } = null,

        /// Creates an editor bound to a renderbuffer.
        /// Parameters:
        /// - rb: renderbuffer to edit.
        ///
        /// Returns: initialized Editor.
        pub fn init(rb: *Renderbuffer) Editor {
            return .{ ._rb = rb };
        }
        /// Queues a target change.
        /// Parameters:
        /// - self: editor instance.
        /// - target: new renderbuffer target.
        ///
        /// Returns: self for chaining.
        pub fn setTarget(self: *const Editor, target: RenderbufferTarget) *const Editor {
            @constCast(self)._pending_target = target;
            return @constCast(self);
        }
        /// Queues a plain storage allocation via `glRenderbufferStorage`.
        /// Parameters:
        /// - self: editor instance.
        /// - internalformat: sized internal format.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorage(self: *const Editor, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_storage = .{ .internalformat = internalformat, .width = width, .height = height };
            return @constCast(self);
        }
        /// Queues a plain storage allocation on an explicit target.
        /// Parameters:
        /// - self: editor instance.
        /// - target: renderbuffer target for the storage.
        /// - internalformat: sized internal format.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorageOn(self: *const Editor, target: RenderbufferTarget, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            _ = self.setTarget(target);
            return self.setStorage(internalformat, width, height);
        }
        /// Queues a multisampled storage allocation via
        /// `glRenderbufferStorageMultisample`. `samples` must not exceed
        /// `GL_MAX_SAMPLES` (see `maxSamples`).
        /// Parameters:
        /// - self: editor instance.
        /// - samples: sample count (e.g. 4 for MSAA x4).
        /// - internalformat: sized internal format.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorageMultisample(self: *const Editor, samples: i32, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_storage_multisample = .{ .samples = samples, .internalformat = internalformat, .width = width, .height = height };
            return @constCast(self);
        }
        /// Queues a multisampled storage allocation on an explicit target.
        /// Parameters:
        /// - self: editor instance.
        /// - target: renderbuffer target for the storage.
        /// - samples: sample count (e.g. 4 for MSAA x4).
        /// - internalformat: sized internal format.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorageMultisampleOn(self: *const Editor, target: RenderbufferTarget, samples: i32, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            _ = self.setTarget(target);
            return self.setStorageMultisample(samples, internalformat, width, height);
        }
        /// Applies all queued changes to the renderbuffer.
        /// Parameters:
        /// - self: editor instance.
        ///
        /// Returns: void.
        pub fn apply(self: *const Editor) void {
            const rb = @constCast(self)._rb.impl();
            const loaded = gl.loader.loaded();
            const target = @constCast(self)._pending_target orelse rb.target;
            if (@constCast(self)._pending_target) |t| rb.target = t;
            if (loaded) gl.renderbuffers.bind(target, rb.id);
            if (@constCast(self)._pending_storage_multisample) |s| {
                if (loaded) gl.renderbuffers.storageMultisample(target, s.samples, s.internalformat, s.width, s.height);
                rb.internal_format = s.internalformat;
                rb.width = s.width;
                rb.height = s.height;
                rb.samples = s.samples;
                rb.target = target;
            } else if (@constCast(self)._pending_storage) |s| {
                if (loaded) gl.renderbuffers.storage(target, s.internalformat, s.width, s.height);
                rb.internal_format = s.internalformat;
                rb.width = s.width;
                rb.height = s.height;
                rb.samples = 0;
                rb.target = target;
            }
            @constCast(self).* = Editor.init(@constCast(self)._rb);
        }
    };
};
