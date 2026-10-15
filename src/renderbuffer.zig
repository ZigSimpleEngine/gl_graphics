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

    /// Generates GL renderbuffer via glGenRenderbuffers and seeds fresh cached Impl state.
    /// Use an RBO (non-samplable, fast for depth/stencil/MSAA) vs a texture when you only
    /// need a framebuffer attachment and never sample it in a shader; stub id=1 when GL unloaded.
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
    /// Deletes GL object via glDeleteRenderbuffers (if loaded and id != 0) and frees cached Impl storage.
    /// Call once to avoid GPU and allocator leaks; the handle dangles after free so never reuse it.
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
    /// Checks cached Impl.id (!= 0) plus glIsRenderbuffer without mutating GL or cached Impl state.
    /// Use to validate before attach/bind after context loss; cached id alone may be stale.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: true if the renderbuffer exists.
    pub fn isValid(self: *const Renderbuffer) bool {
        const m = self.implConst();
        return m.id != 0 and gl.renderbuffers.isRenderbuffer(m.id);
    }

    /// Reads cached Impl.id without any GL call; id was created by glGenRenderbuffers in create.
    /// Use for framebuffer attachment; contrast query* which round-trip to GL for driver truth.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: OpenGL renderbuffer id.
    pub fn getId(self: *const Renderbuffer) u32 {
        return self.implConst().id;
    }
    /// Reads cached Impl.target without any GL call; tracks the last applied bind point.
    /// Use to reason about where bind() binds; use bindTo for a one-off explicit target without mutating cache.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: renderbuffer target enum.
    pub fn getTarget(self: *const Renderbuffer) RenderbufferTarget {
        return self.implConst().target;
    }
    /// Reads cached Impl.internal_format (sized internal format enum) without any GL call.
    /// Null means Editor.apply never allocated storage; contrast queryInternalFormat which re-reads driver truth.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: optional internal format; null if no storage yet.
    pub fn getInternalFormat(self: *const Renderbuffer) ?InternalFormat {
        return self.implConst().internal_format;
    }
    /// Reads cached Impl.width in pixels without any GL call; last value written by Editor.apply.
    /// Why cached: zero-cost layout without a GL round-trip; contrast queryWidth (pixels from GL) for verification.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: width in pixels.
    pub fn getWidth(self: *const Renderbuffer) i32 {
        return self.implConst().width;
    }
    /// Reads cached Impl.height in pixels without any GL call; last value written by Editor.apply.
    /// Why cached: zero-cost layout without a GL round-trip; contrast queryHeight (pixels from GL) for verification.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: height in pixels.
    pub fn getHeight(self: *const Renderbuffer) i32 {
        return self.implConst().height;
    }
    /// Reads cached Impl.samples as sample count without any GL call (0=single-sample, e.g. 4=MSAAx4).
    /// Clamp future MSAA allocations against maxSamples() (GL_MAX_SAMPLES limit); contrast querySamples for driver truth.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: sample count; 0 means non-multisampled storage.
    pub fn getSamples(self: *const Renderbuffer) i32 {
        return self.implConst().samples;
    }
    /// Reads cached Impl.width/height in pixels without any GL call; last values written by Editor.apply.
    /// Why cached: fast framebuffer sizing; contrast queryWidth/queryHeight (pixels from GL) when verification is needed.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: anonymous struct with fields `w` and `h` in pixels.
    pub fn getSize(self: *const Renderbuffer) struct { w: i32, h: i32 } {
        const m = self.implConst();
        return .{ .w = m.width, .h = m.height };
    }
    /// Derives cached Impl.samples > 0 without any GL call; leaves GL and cached Impl unmutated.
    /// When true, plan an MSAA resolve via Framebuffer.blitFrom since RBOs are non-samplable (unlike textures).
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: true when sample count is greater than zero.
    pub fn isMultisampled(self: *const Renderbuffer) bool {
        return self.implConst().samples > 0;
    }

    /// Calls glBindRenderbuffer with cached id/target without mutating cached Impl state.
    /// Use before manual queryParameter calls; Editor.apply binds internally so explicit bind is rarely needed otherwise.
    /// Parameters:
    /// - self: renderbuffer to bind.
    ///
    /// Returns: void.
    pub fn bind(self: *const Renderbuffer) void {
        const m = self.implConst();
        gl.renderbuffers.bind(m.target, m.id);
    }
    /// Calls glBindRenderbuffer with cached id plus an explicit target without mutating cached Impl.target.
    /// Use for a one-off bind elsewhere; use Editor.setTarget plus apply to persist a target change in cache.
    /// Parameters:
    /// - self: renderbuffer to bind.
    /// - target: renderbuffer target to bind to.
    ///
    /// Returns: void.
    pub fn bindTo(self: *const Renderbuffer, target: RenderbufferTarget) void {
        gl.renderbuffers.bind(target, self.implConst().id);
    }
    /// Calls glBindRenderbuffer via bind() with cached id/target without mutating cached Impl state.
    /// Ergonomic alias for making this RBO current; identical cost and semantics to bind().
    /// Parameters:
    /// - self: renderbuffer to use.
    ///
    /// Returns: void.
    pub fn use(self: *const Renderbuffer) void {
        self.bind();
    }

    /// Binds RBO then reads driver state via glGetRenderbufferParameteriv without mutating cached Impl.
    /// Why vs cached get*: ground truth after external GL changes but slower round-trip, so prefer get* on hot paths.
    /// Parameters:
    /// - self: renderbuffer to query.
    /// - pname: parameter name to query (units of Returns vary: pixels for WIDTH/HEIGHT, sample count for SAMPLES, bits per channel for RED/GREEN/BLUE/ALPHA/DEPTH/STENCIL sizes, internal format enum value for INTERNAL_FORMAT).
    ///
    /// Returns: integer value of the parameter in pname-specific units.
    pub fn queryParameter(self: *const Renderbuffer, pname: RenderbufferParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.renderbuffers.getParameter(self.implConst().target, pname, @ptrCast(&v));
        return v;
    }
    /// Binds then queries GL RENDERBUFFER_WIDTH without mutating cached Impl; returns pixels.
    /// Why vs cached getWidth (pixels, zero-cost): verifies driver truth after external or resized storage.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: width in pixels as reported by GL.
    pub fn queryWidth(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_width);
    }
    /// Binds then queries GL RENDERBUFFER_HEIGHT without mutating cached Impl; returns pixels.
    /// Why vs cached getHeight (pixels, zero-cost): verifies driver truth after external or resized storage.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: height in pixels as reported by GL.
    pub fn queryHeight(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_height);
    }
    /// Binds then queries GL RENDERBUFFER_SAMPLES without mutating cached Impl; returns sample count.
    /// Units are sample count (0=single-sample, e.g. 4=MSAAx4, capped by GL_MAX_SAMPLES from maxSamples()).
    /// Contrast cached getSamples for the fast zero-cost path.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: sample count as reported by GL.
    pub fn querySamples(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_samples);
    }
    /// Binds then queries GL RENDERBUFFER_INTERNAL_FORMAT without mutating cached Impl; returns internal format enum.
    /// Why vs cached getInternalFormat: confirms the sized internal format enum actually allocated by the driver.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: internal format as reported by GL.
    pub fn queryInternalFormat(self: *const Renderbuffer) InternalFormat {
        return @enumFromInt(@as(u32, @intCast(self.queryParameter(.renderbuffer_internal_format))));
    }
    /// Binds then queries GL RENDERBUFFER_RED_SIZE without mutating cached Impl; returns bits per channel, not pixels.
    /// Why: validates actual red precision of the sized internal format enum; contrast queryWidth/queryHeight which return pixels.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: red size in bits as reported by GL.
    pub fn queryRedSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_red_size);
    }
    /// Binds then queries GL RENDERBUFFER_GREEN_SIZE without mutating cached Impl; returns bits per channel, not pixels.
    /// Why: validates actual green precision of the sized internal format enum; contrast queryWidth/queryHeight which return pixels.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: green size in bits as reported by GL.
    pub fn queryGreenSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_green_size);
    }
    /// Binds then queries GL RENDERBUFFER_BLUE_SIZE without mutating cached Impl; returns bits per channel, not pixels.
    /// Why: validates actual blue precision of the sized internal format enum; contrast queryWidth/queryHeight which return pixels.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: blue size in bits as reported by GL.
    pub fn queryBlueSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_blue_size);
    }
    /// Binds then queries GL RENDERBUFFER_ALPHA_SIZE without mutating cached Impl; returns bits per channel, not pixels.
    /// Why: validates actual alpha precision of the sized internal format enum; contrast queryWidth/queryHeight which return pixels.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: alpha size in bits as reported by GL.
    pub fn queryAlphaSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_alpha_size);
    }
    /// Binds then queries GL RENDERBUFFER_DEPTH_SIZE without mutating cached Impl; returns bits per channel, not pixels.
    /// Why: validates actual depth precision (RBOs are the fast non-samplable path for depth vs textures); contrast pixel-sized queries.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: depth size in bits as reported by GL.
    pub fn queryDepthSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_depth_size);
    }
    /// Binds then queries GL RENDERBUFFER_STENCIL_SIZE without mutating cached Impl; returns bits per channel, not pixels.
    /// Why: validates actual stencil precision (RBOs are the fast non-samplable path for stencil vs textures); contrast pixel-sized queries.
    /// Parameters:
    /// - self: renderbuffer to query.
    ///
    /// Returns: stencil size in bits as reported by GL.
    pub fn queryStencilSize(self: *const Renderbuffer) i32 {
        return self.queryParameter(.renderbuffer_stencil_size);
    }

    /// Reads GL_MAX_SAMPLES via glGetIntegerv without touching any cached Impl state; changes no GL state.
    /// Why: clamp setStorageMultisample samples (sample count, e.g. 4=MSAAx4) to this limit to avoid GL errors.
    /// Parameters: none.
    ///
    /// Returns: maximum samples per pixel, or 0 when GL is not loaded.
    pub fn maxSamples() i32 {
        if (!gl.loader.loaded()) return 0;
        var v: i32 = 0;
        gl.state.getInteger(.max_samples, @ptrCast(&v));
        return v;
    }

    /// Creates an Editor bound to self without any GL call or cached Impl mutation; defers work to apply.
    /// Why builder: batches target plus storage into one bind in apply; multisample pending wins if both queued.
    /// Parameters:
    /// - self: renderbuffer to edit.
    ///
    /// Returns: Editor instance referencing this renderbuffer.
    pub fn edit(self: *Renderbuffer) Editor {
        return Editor.init(self);
    }

    /// Builder for deferred renderbuffer state changes.
    pub const Editor = struct {
        /// Target RBO whose cached Impl is only mutated by apply; holding it has no GL effect on its own.
        _rb: *Renderbuffer,
        /// Queued target enum change (null keeps cached Impl.target); persisted to cache by apply.
        _pending_target: ?RenderbufferTarget = null,
        /// Queued plain single-sample storage: internalformat is sized internal format enum, width/height in pixels.
        _pending_storage: ?struct { internalformat: InternalFormat, width: i32, height: i32 } = null,
        /// Queued multisample storage: samples is sample count (e.g. 4=MSAAx4, capped by GL_MAX_SAMPLES), width/height in pixels, internalformat is sized internal format enum.
        /// Wins over plain storage when both are queued in the same batch; resolve via Framebuffer.blitFrom since RBOs are non-samplable.
        _pending_storage_multisample: ?struct { samples: i32, internalformat: InternalFormat, width: i32, height: i32 } = null,

        /// Creates an Editor bound to rb without any GL call or cached Impl mutation; starts with empty pending queue.
        /// Beginning of the builder chain; follow with setStorage or setStorageMultisample then apply to allocate.
        /// Parameters:
        /// - rb: renderbuffer to edit.
        ///
        /// Returns: initialized Editor.
        pub fn init(rb: *Renderbuffer) Editor {
            return .{ ._rb = rb };
        }
        /// Queues a pending target enum change without any GL call or cached Impl mutation until apply.
        /// Why vs bindTo (temporary bind without cache update): persists as cached Impl.target in apply for future bind() calls.
        /// Parameters:
        /// - self: editor instance.
        /// - target: new renderbuffer target.
        ///
        /// Returns: self for chaining.
        pub fn setTarget(self: *const Editor, target: RenderbufferTarget) *const Editor {
            @constCast(self)._pending_target = target;
            return @constCast(self);
        }
        /// Queues plain single-sample storage (glRenderbufferStorage semantics) without GL or cache mutation until apply.
        /// Use an RBO (non-samplable, fast) vs a texture when the attachment is never sampled; multisample pending wins if both queued.
        /// Parameters:
        /// - self: editor instance.
        /// - internalformat: sized internal format enum.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorage(self: *const Editor, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_storage = .{ .internalformat = internalformat, .width = width, .height = height };
            return @constCast(self);
        }
        /// Queues a pending target plus plain single-sample storage without GL or cache mutation until apply.
        /// Same RBO-vs-texture rationale as setStorage but pins an explicit target; multisample still wins if also queued.
        /// Parameters:
        /// - self: editor instance.
        /// - target: renderbuffer target for the storage.
        /// - internalformat: sized internal format enum.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorageOn(self: *const Editor, target: RenderbufferTarget, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            _ = self.setTarget(target);
            return self.setStorage(internalformat, width, height);
        }
        /// Queues multisample storage (glRenderbufferStorageMultisample semantics) without GL or cache mutation until apply.
        /// Use for an MSAA render target on the fast non-samplable RBO path; resolve via Framebuffer.blitFrom; wins over plain storage if both queued.
        /// Parameters:
        /// - self: editor instance.
        /// - samples: sample count (0=single-sample fallback, e.g. 4=MSAAx4, must be <= GL_MAX_SAMPLES from maxSamples()).
        /// - internalformat: sized internal format enum.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorageMultisample(self: *const Editor, samples: i32, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            @constCast(self)._pending_storage_multisample = .{ .samples = samples, .internalformat = internalformat, .width = width, .height = height };
            return @constCast(self);
        }
        /// Queues a pending target plus multisample storage without GL or cache mutation until apply.
        /// Same MSAA RBO rationale as setStorageMultisample but on an explicit target; resolve via Framebuffer.blitFrom; wins over plain storage.
        /// Parameters:
        /// - self: editor instance.
        /// - target: renderbuffer target for the storage.
        /// - samples: sample count (0=single-sample fallback, e.g. 4=MSAAx4, must be <= GL_MAX_SAMPLES from maxSamples()).
        /// - internalformat: sized internal format enum.
        /// - width: width in pixels.
        /// - height: height in pixels.
        ///
        /// Returns: self for chaining.
        pub fn setStorageMultisampleOn(self: *const Editor, target: RenderbufferTarget, samples: i32, internalformat: InternalFormat, width: i32, height: i32) *const Editor {
            _ = self.setTarget(target);
            return self.setStorageMultisample(samples, internalformat, width, height);
        }
        /// Binds GL target and allocates storage via glRenderbufferStorage/Multisample then syncs cached Impl and clears pending.
        /// Multisample pending wins if both queued; plain path resets cached samples to 0 (single-sample); resolve MSAA via Framebuffer.blitFrom.
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
