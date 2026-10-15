/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");

/// Local aliases for GL types used by this wrapper, so signatures and bodies
/// stay short without fully qualified `gl.*` type paths.
const FramebufferTarget = gl.framebuffers.FramebufferTarget;
const Attachment = gl.framebuffers.Attachment;
const DrawBuffer = gl.framebuffers.DrawBuffer;
const FramebufferStatus = gl.framebuffers.FramebufferStatus;
const AttachmentParameter = gl.framebuffers.AttachmentParameter;
const BlitFilter = gl.framebuffers.BlitFilter;
const TextureTarget = gl.textures.TextureTarget;
const BufferMask = gl.enums.BufferMask;
const ReadBuffer = gl.pixels.ReadBuffer;

/// Internal implementation storage for an opaque Framebuffer handle.
/// Holds OpenGL object state and cached attachments.
const Impl = struct {
    /// OpenGL framebuffer object identifier (0 means default/uninitialized).
    id: u32 = 0,
    /// Target binding point for this framebuffer used by bind().
    target: FramebufferTarget = .framebuffer,
    /// Width in pixels (FBO window coords extent, manual cache via setSize).
    width: i32 = 0,
    /// Height in pixels (FBO window coords extent, manual cache via setSize).
    height: i32 = 0,
    /// Cached color attachment identifiers indexed by attachment index 0-15.
    color_attachments: [16]?u32 = [_]?u32{null} ** 16,
    /// Cached depth attachment identifier if present.
    depth_attachment: ?u32 = null,
    /// Cached stencil attachment identifier if present.
    stencil_attachment: ?u32 = null,
    /// Cached combined depth-stencil attachment identifier if present.
    depth_stencil_attachment: ?u32 = null,
    /// Cached draw buffer configuration for multiple render targets.
    draw_buffers: [16]DrawBuffer = [_]DrawBuffer{.none} ** 16,
    /// Number of active draw buffers in use.
    draw_count: usize = 1,
};

/// Opaque framebuffer object with builder-style editing.
pub const Framebuffer = opaque {
    /// Returns mutable implementation pointer for this handle.
    /// Parameters:
    /// - self: mutable opaque framebuffer pointer.
    ///
    /// Returns: pointer to internal Impl.
    inline fn impl(self: *Framebuffer) *Impl {
        return @ptrCast(@alignCast(self));
    }
    /// Returns immutable implementation pointer for this handle.
    /// Parameters:
    /// - self: const opaque framebuffer pointer.
    ///
    /// Returns: pointer to const Impl.
    inline fn implConst(self: *const Framebuffer) *const Impl {
        return @ptrCast(@alignCast(self));
    }

    /// Generates a GL framebuffer via glGenFramebuffers and allocates cached Impl state.
    /// Use once per offscreen render target; configure later with edit()+apply()
    /// instead of raw GL. Pitfall: returns stub id 1 when GL loader is not loaded
    /// (tests/headless), so isValid() fails until a real context exists.
    /// Parameters:
    /// - allocator: allocator used to allocate Impl storage.
    ///
    /// Returns: pointer to created Framebuffer or allocation error.
    pub fn create(allocator: std.mem.Allocator) !*Framebuffer {
        const m = try allocator.create(Impl);
        m.* = .{};
        var id: u32 = 0;
        if (gl.loader.loaded()) {
            gl.framebuffers.gen(1, @ptrCast(&id));
        } else {
            id = 1;
        }
        m.id = id;
        return @ptrCast(m);
    }
    /// Deletes the GL object via glDeleteFramebuffers and frees cached Impl storage.
    /// Call once ownership ends; prefer bindDefault() first if it is currently bound
    /// instead of leaving a deleted id bound. Pitfall: skips glDelete when id is 0
    /// and does not unbind; pointer must not be used after this call.
    /// Parameters:
    /// - self: framebuffer to destroy.
    /// - allocator: allocator that was used for creation.
    ///
    /// Returns: void.
    pub fn destroy(self: *Framebuffer, allocator: std.mem.Allocator) void {
        const m = self.impl();
        if (gl.loader.loaded() and m.id != 0) gl.framebuffers.delete(1, @ptrCast(&m.id));
        allocator.destroy(m);
    }
    /// Queries GL via glIsFramebuffer without mutating cached Impl state.
    /// Use to detect context loss or stub ids before rendering; this checks object
    /// existence, not completeness. Prefer isComplete() when you need attachment
    /// validity. Pitfall: requires a loaded GL context to be meaningful.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: true if the framebuffer exists.
    pub fn isValid(self: *const Framebuffer) bool {
        const m = self.implConst();
        return m.id != 0 and gl.framebuffers.isFramebuffer(m.id);
    }

    /// Reads cached Impl.id without issuing GL calls.
    /// Use for raw GL interop or debugging; prefer bind()/bindTo() for actual use.
    /// Pitfall: 0 means default/uninitialized, 1 may be a stub when the loader is
    /// unloaded; cache does not track external glDeleteFramebuffers.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: OpenGL framebuffer id.
    pub fn getId(self: *const Framebuffer) u32 {
        return self.implConst().id;
    }
    /// Reads cached Impl.target without issuing GL calls; controls what bind() uses.
    /// Use to inspect which binding point apply() will bind to. Prefer bindTo()
    /// for a one-off explicit target without persisting. Pitfall: stale if raw
    /// glBindFramebuffer was used outside this wrapper.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: framebuffer target enum.
    pub fn getTarget(self: *const Framebuffer) FramebufferTarget {
        return self.implConst().target;
    }
    /// Reads cached Impl.width in pixels without issuing GL calls.
    /// Use to size viewports, scissors, and blit rectangles. Prefer setSize()+apply()
    /// to update it. Pitfall: manual cache only, does NOT query GL or auto-derive
    /// from attachments and does NOT resize attachments; 0 until set.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: width in pixels.
    pub fn getWidth(self: *const Framebuffer) i32 {
        return self.implConst().width;
    }
    /// Reads cached Impl.height in pixels without issuing GL calls.
    /// Use to size viewports, scissors, and blit rectangles. Prefer setSize()+apply()
    /// to update it. Pitfall: manual cache only, does NOT query GL or auto-derive
    /// from attachments and does NOT resize attachments; 0 until set.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: height in pixels.
    pub fn getHeight(self: *const Framebuffer) i32 {
        return self.implConst().height;
    }
    /// Reads cached Impl.color_attachments[index] without issuing GL calls.
    /// Use for fast CPU-side lookup; prefer getAttachmentParameter() for live GL
    /// state. Pitfall: reflects only wrapper attach paths, not external GL attaches.
    /// Parameters:
    /// - self: framebuffer to query.
    /// - index: attachment index 0-15 mapping to GL_COLOR_ATTACHMENT0 + index.
    ///
    /// Returns: texture or renderbuffer id or null if out of bounds or unset.
    pub fn getColorAttachment(self: *const Framebuffer, index: usize) ?u32 {
        if (index >= 16) return null;
        return self.implConst().color_attachments[index];
    }
    /// Reads cached Impl.depth_attachment without issuing GL calls.
    /// Use to check for a separate depth texture/renderbuffer; prefer combined
    /// depth-stencil APIs for packed D24S8. Pitfall: null if only depth-stencil
    /// combined attachment is set; does not query live GL.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: optional depth attachment id.
    pub fn getDepthAttachment(self: *const Framebuffer) ?u32 {
        return self.implConst().depth_attachment;
    }
    /// Reads cached Impl.stencil_attachment without issuing GL calls.
    /// Use to check for a separate stencil texture/renderbuffer; rarely used alone,
    /// combined depth-stencil is more common. Pitfall: null if only combined
    /// attachment is set; does not query live GL.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: optional stencil attachment id.
    pub fn getStencilAttachment(self: *const Framebuffer) ?u32 {
        return self.implConst().stencil_attachment;
    }
    /// Reads cached Impl.depth_stencil_attachment without issuing GL calls.
    /// Use for packed D24S8-style textures; prefer this over separate depth+stencil
    /// to save attachments. Pitfall: separate depth/stencil getters stay null when
    /// only the combined point is used; does not query live GL.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: optional depth-stencil attachment id.
    pub fn getDepthStencilAttachment(self: *const Framebuffer) ?u32 {
        return self.implConst().depth_stencil_attachment;
    }
    /// Reads cached Impl.draw_buffers slice without issuing GL calls.
    /// Use to inspect current MRT routing; configure via setDrawBuffers()+apply()
    /// instead of raw glDrawBuffers. Pitfall: length is draw_count, not always 16;
    /// cache misses external glDrawBuffers calls.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: slice of draw buffers currently configured.
    pub fn getDrawBuffers(self: *const Framebuffer) []const DrawBuffer {
        const m = self.implConst();
        return m.draw_buffers[0..m.draw_count];
    }
    /// Binds to cached target then queries GL completeness via glCheckFramebufferStatus.
    /// Does not mutate cached Impl state apart from the bind side effect. Use after
    /// apply() and before rendering; prefer isComplete() for a boolean check.
    /// Pitfall: changes current GL binding; incomplete if sizes, formats, or draw
    /// buffers mismatch.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: framebuffer status enum.
    pub fn getStatus(self: *const Framebuffer) FramebufferStatus {
        self.bind();
        return gl.framebuffers.checkStatus(self.implConst().target);
    }
    /// Binds to cached target then checks GL status equals .framebuffer_complete.
    /// Does not mutate cached Impl state apart from the bind side effect. Use as a
    /// quick validity gate before draw calls; prefer getStatus() for the reason code.
    /// Pitfall: binds as a side effect; false if attachments disagree on size or
    /// draw buffers are misconfigured.
    /// Parameters:
    /// - self: framebuffer to query.
    ///
    /// Returns: true when status is framebuffer_complete.
    pub fn isComplete(self: *const Framebuffer) bool {
        return self.getStatus() == .framebuffer_complete;
    }
    /// Binds to cached target then queries live GL state via glGetFramebufferAttachment.
    /// Does not mutate cached Impl state apart from the bind side effect. Use for
    /// object type, level, or layer introspection; prefer cached getColorAttachment()
    /// getters to avoid a GL round-trip. Pitfall: binds as a side effect and needs
    /// a current context.
    /// Parameters:
    /// - self: framebuffer to query.
    /// - attachment: attachment point to query (e.g. .color_attachment0).
    /// - pname: parameter name to query (e.g. object type, texture level).
    ///
    /// Returns: integer value of the parameter.
    pub fn getAttachmentParameter(self: *const Framebuffer, attachment: Attachment, pname: AttachmentParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.framebuffers.getAttachmentParameter(self.implConst().target, attachment, pname, @ptrCast(&v));
        return v;
    }
    /// Issues glBindFramebuffer on cached Impl.target with cached Impl.id.
    /// Does not mutate cached Impl state. Use for normal rendering to this target;
    /// prefer bindTo() when you need an explicit read/draw split for blits.
    /// Pitfall: wrapper does not track external binds, so getTarget() can be stale.
    /// Parameters:
    /// - self: framebuffer to bind.
    ///
    /// Returns: void.
    pub fn bind(self: *const Framebuffer) void {
        const m = self.implConst();
        gl.framebuffers.bind(m.target, m.id);
    }
    /// Issues glBindFramebuffer on an explicit target with cached Impl.id.
    /// Does not mutate cached Impl.target. Use for blit paths needing separate
    /// GL_READ_FRAMEBUFFER vs GL_DRAW_FRAMEBUFFER bindings; prefer setTarget()+
    /// apply() to persist a target change. Pitfall: next bind() still uses the
    /// cached target, not this override.
    /// Parameters:
    /// - self: framebuffer to bind.
    /// - target: framebuffer target to bind to.
    ///
    /// Returns: void.
    pub fn bindTo(self: *const Framebuffer, target: FramebufferTarget) void {
        gl.framebuffers.bind(target, self.implConst().id);
    }
    /// Issues glBindFramebuffer on cached target with cached id (alias for bind()).
    /// Does not mutate cached Impl state. Use as a semantic "make current" helper;
    /// prefer bindTo() for explicit targets. Pitfall: same as bind(), does not
    /// validate completeness, call isComplete() if unsure.
    /// Parameters:
    /// - self: framebuffer to use.
    ///
    /// Returns: void.
    pub fn use(self: *const Framebuffer) void {
        self.bind();
    }
    /// Issues glBindFramebuffer(target, 0) to restore the default framebuffer.
    /// Touches no cached Impl state. Use after offscreen passes and before presenting;
    /// prefer useDefault() for the generic target shorthand. Pitfall: does not update
    /// any Framebuffer cache or validate default-framebuffer size.
    /// Parameters:
    /// - target: target to bind default framebuffer to.
    ///
    /// Returns: void.
    pub fn bindDefault(target: FramebufferTarget) void {
        gl.framebuffers.bind(target, 0);
    }
    /// Issues glBindFramebuffer(.framebuffer, 0) to restore the default target.
    /// Touches no cached Impl state. Use to end offscreen rendering quickly; prefer
    /// bindDefault() when you need an explicit read/draw target. Pitfall: affects
    /// both read and draw when .framebuffer is used, unlike split bindings.
    /// Parameters: none.
    ///
    /// Returns: void.
    pub fn useDefault() void {
        bindDefault(.framebuffer);
    }
    /// Binds src to GL_READ_FRAMEBUFFER and self to GL_DRAW_FRAMEBUFFER then issues.
    /// glBlitFramebuffer, without mutating cached Impl state. Use for copies, scaling,
    /// and MSAA resolve when sample counts differ; prefer resolveFrom() for full-size
    /// resolve. Pitfall: depth/stencil requires filter .nearest (.linear is color-only
    /// and raises GL_INVALID_OPERATION); formats and sample layouts must be compatible.
    /// Parameters:
    /// - self: destination framebuffer (draw target).
    /// - src: source framebuffer (read target).
    /// - src_x0: source rectangle lower-left x in pixels (FBO coords, origin lower-left).
    /// - src_y0: source rectangle lower-left y in pixels (FBO coords, origin lower-left).
    /// - src_x1: source rectangle upper-right x in pixels (FBO coords, origin lower-left).
    /// - src_y1: source rectangle upper-right y in pixels (FBO coords, origin lower-left).
    /// - dst_x0: destination rectangle lower-left x in pixels (FBO coords, origin lower-left).
    /// - dst_y0: destination rectangle lower-left y in pixels (FBO coords, origin lower-left).
    /// - dst_x1: destination rectangle upper-right x in pixels (FBO coords, origin lower-left).
    /// - dst_y1: destination rectangle upper-right y in pixels (FBO coords, origin lower-left).
    /// - mask: buffers to copy (color/depth/stencil).
    /// - filter: resampling filter used when sizes differ (.nearest required for depth/stencil).
    ///
    /// Returns: void.
    pub fn blitFrom(
        self: *const Framebuffer,
        src: *const Framebuffer,
        src_x0: i32,
        src_y0: i32,
        src_x1: i32,
        src_y1: i32,
        dst_x0: i32,
        dst_y0: i32,
        dst_x1: i32,
        dst_y1: i32,
        mask: BufferMask,
        filter: BlitFilter,
    ) void {
        src.bindTo(.read_framebuffer);
        self.bindTo(.draw_framebuffer);
        gl.framebuffers.blit(src_x0, src_y0, src_x1, src_y1, dst_x0, dst_y0, dst_x1, dst_y1, mask, filter);
    }
    /// Binds src/dst and issues a full-size glBlitFramebuffer with .nearest for MSAA.
    /// resolve, without mutating cached Impl state. Use to resolve a multisampled source
    /// into this destination when sizes match; prefer blitFrom() for sub-rects or
    /// scaling. Pitfall: .nearest is the only valid filter for depth/stencil resolve,
    /// and sample counts must differ or be explicitly resolvable.
    /// Parameters:
    /// - self: destination (resolve) framebuffer.
    /// - src: multisampled source framebuffer.
    /// - width: framebuffer width in pixels (FBO window coords extent).
    /// - height: framebuffer height in pixels (FBO window coords extent).
    /// - mask: buffers to resolve (color/depth/stencil).
    ///
    /// Returns: void.
    pub fn resolveFrom(self: *const Framebuffer, src: *const Framebuffer, width: i32, height: i32, mask: BufferMask) void {
        self.blitFrom(src, 0, 0, width, height, 0, 0, width, height, mask, .nearest);
    }
    /// Binds src to GL_READ_FRAMEBUFFER and id 0 to GL_DRAW_FRAMEBUFFER then issues.
    /// glBlitFramebuffer to the default framebuffer, without mutating cached state.
    /// Use to present an offscreen target directly; like blitFrom(), differing sample
    /// counts trigger an MSAA resolve without an intermediate texture. Pitfall:
    /// depth/stencil requires filter .nearest (.linear is color-only); dst rect is in
    /// default-framebuffer pixels (origin lower-left) and may differ in size.
    /// Parameters:
    /// - src: source framebuffer (read target).
    /// - src_x0: source rectangle lower-left x in pixels (FBO coords, origin lower-left).
    /// - src_y0: source rectangle lower-left y in pixels (FBO coords, origin lower-left).
    /// - src_x1: source rectangle upper-right x in pixels (FBO coords, origin lower-left).
    /// - src_y1: source rectangle upper-right y in pixels (FBO coords, origin lower-left).
    /// - dst_x0: destination rectangle lower-left x in pixels (default FBO, origin lower-left).
    /// - dst_y0: destination rectangle lower-left y in pixels (default FBO, origin lower-left).
    /// - dst_x1: destination rectangle upper-right x in pixels (default FBO, origin lower-left).
    /// - dst_y1: destination rectangle upper-right y in pixels (default FBO, origin lower-left).
    /// - mask: buffers to copy (color/depth/stencil).
    /// - filter: resampling filter used when sizes differ (.nearest required for depth/stencil).
    ///
    /// Returns: void.
    pub fn blitToDefault(
        src: *const Framebuffer,
        src_x0: i32,
        src_y0: i32,
        src_x1: i32,
        src_y1: i32,
        dst_x0: i32,
        dst_y0: i32,
        dst_x1: i32,
        dst_y1: i32,
        mask: BufferMask,
        filter: BlitFilter,
    ) void {
        src.bindTo(.read_framebuffer);
        bindDefault(.draw_framebuffer);
        gl.framebuffers.blit(src_x0, src_y0, src_x1, src_y1, dst_x0, dst_y0, dst_x1, dst_y1, mask, filter);
    }
    /// Binds src and the default framebuffer and issues a full-size glBlitFramebuffer.
    /// with .nearest for MSAA resolve to screen, without mutating cached state. Use to
    /// present a multisampled source directly; prefer blitToDefault() for sub-rects or
    /// scaling. Pitfall: .nearest is the only valid filter for depth/stencil resolve;
    /// width/height are in pixels and must match the source size for a pure resolve.
    /// Parameters:
    /// - src: multisampled source framebuffer.
    /// - width: framebuffer width in pixels (FBO window coords extent).
    /// - height: framebuffer height in pixels (FBO window coords extent).
    /// - mask: buffers to resolve (color/depth/stencil).
    ///
    /// Returns: void.
    pub fn resolveToDefault(src: *const Framebuffer, width: i32, height: i32, mask: BufferMask) void {
        blitToDefault(src, 0, 0, width, height, 0, 0, width, height, mask, .nearest);
    }

    /// Constructs an Editor bound to this framebuffer without issuing GL calls.
    /// Does not mutate cached Impl state yet; mutations queue until apply(). Use to
    /// batch target, size, attachments, and draw buffers efficiently; prefer raw GL
    /// only for one-off interop. Pitfall: Editor holds a raw pointer, must not outlive
    /// the framebuffer, and pending state is lost unless apply() is called.
    /// Parameters:
    /// - self: framebuffer to edit.
    ///
    /// Returns: Editor instance referencing this framebuffer.
    pub fn edit(self: *Framebuffer) Editor {
        return Editor.init(self);
    }

    /// Issues glFramebufferRenderbuffer and mirrors the id in cached Impl state.
    /// Updates depth/stencil/depth-stencil slots or color index 0-15 derived from
    /// the attachment enum. Shared by single and batched renderbuffer apply paths
    /// to keep GL and cache in sync; prefer Editor.setRenderbuffer() for public use.
    fn attachRenderbufferCached(fb: *Impl, target: FramebufferTarget, attachment: Attachment, renderbuffer: u32, loaded: bool) void {
        if (loaded) gl.framebuffers.attachRenderbuffer(target, attachment, renderbuffer);
        switch (attachment) {
            .depth_attachment => fb.depth_attachment = renderbuffer,
            .stencil_attachment => fb.stencil_attachment = renderbuffer,
            .depth_stencil_attachment => fb.depth_stencil_attachment = renderbuffer,
            else => {
                const idx = @intFromEnum(attachment) - @intFromEnum(Attachment.color_attachment0);
                if (idx >= 0 and idx < 16) fb.color_attachments[@intCast(idx)] = renderbuffer;
            },
        }
    }

    /// Builder for deferred framebuffer state changes.
    pub const Editor = struct {
        /// One color attachment assignment for `setColorAttachments`.
        pub const ColorAttachment = struct {
            /// Color attachment index 0-15 (maps to GL_COLOR_ATTACHMENT0 + index).
            index: usize,
            /// Texture identifier.
            texture: u32,
            /// Texture target.
            textarget: TextureTarget,
            /// Mipmap level index (0 is base level).
            level: i32,
        };
        /// One renderbuffer attachment assignment for `setRenderbuffers`.
        pub const RenderbufferAttachment = struct {
            /// Attachment point.
            attachment: Attachment,
            /// Renderbuffer identifier.
            renderbuffer: u32,
        };
        /// Reference to the framebuffer being edited.
        _fb: *Framebuffer,
        /// Pending target change if any (applied to Impl.target on apply()).
        _pending_target: ?FramebufferTarget = null,
        /// Pending size in pixels: w/h extents (FBO coords, manual cache only).
        _pending_size: ?struct { w: i32, h: i32 } = null,
        /// Pending single color attachment change.
        _pending_color: ?struct { index: usize, texture: u32, textarget: TextureTarget, level: i32 } = null,
        /// Pending layered color attachment change (layer is array/cubemap/3D slice).
        _pending_color_layer: ?struct { index: usize, texture: u32, level: i32, layer: i32 } = null,
        /// Pending depth attachment change.
        _pending_depth: ?struct { texture: u32, textarget: TextureTarget, level: i32 } = null,
        /// Pending stencil attachment change.
        _pending_stencil: ?struct { texture: u32, textarget: TextureTarget, level: i32 } = null,
        /// Pending depth-stencil attachment change.
        _pending_depth_stencil: ?struct { texture: u32, textarget: TextureTarget, level: i32 } = null,
        /// Pending renderbuffer attachment change.
        _pending_renderbuffer: ?struct { attachment: Attachment, renderbuffer: u32 } = null,
        /// Pending batch of renderbuffer attachments.
        _pending_multiple_renderbuffers: ?[]const RenderbufferAttachment = null,
        /// Pending layered depth attachment change (layer is array/cubemap/3D slice).
        _pending_depth_layer: ?struct { texture: u32, level: i32, layer: i32 } = null,
        /// Pending layered stencil attachment change (layer is array/cubemap/3D slice).
        _pending_stencil_layer: ?struct { texture: u32, level: i32, layer: i32 } = null,
        /// Pending layered depth-stencil attachment change (layer is slice index).
        _pending_depth_stencil_layer: ?struct { texture: u32, level: i32, layer: i32 } = null,
        /// Pending draw buffers change.
        _pending_draw_buffers: ?[]const DrawBuffer = null,
        /// Pending invalidate list holding GL enum values as u32 (perf hint only).
        _pending_invalidate: ?[]const u32 = null,
        /// Pending invalidate sub-rect: attachments as GL enums u32, x/y in pixels.
        /// with lower-left origin, w/h sizes in pixels.
        _pending_invalidate_sub: ?struct { attachments: []const u32, x: i32, y: i32, w: i32, h: i32 } = null,
        /// Pending read buffer selection.
        _pending_read_buffer: ?ReadBuffer = null,
        /// Pending batch of color attachments.
        _pending_multiple_colors: ?[]const ColorAttachment = null,

        /// Creates an Editor with empty pending state referencing fb, issuing no GL.
        /// Does not mutate cached Impl state. Use via framebuffer.edit() to start a
        /// batch; prefer chaining setters then apply(). Pitfall: holds a raw pointer,
        /// so it must not outlive the framebuffer.
        /// Parameters:
        /// - fb: framebuffer to edit.
        ///
        /// Returns: initialized Editor.
        pub fn init(fb: *Framebuffer) Editor {
            return .{ ._fb = fb };
        }
        /// Stages a target change in pending state; on apply() updates Impl.target.
        /// and binds before attaches. Use .read_framebuffer/.draw_framebuffer for blit
        /// splits, .framebuffer for generic rendering; prefer bindTo() for a one-off
        /// bind without persisting. Pitfall: no GL effect until apply() is called.
        /// Parameters:
        /// - self: editor instance.
        /// - target: new framebuffer target.
        ///
        /// Returns: self for chaining.
        pub fn setTarget(self: *const Editor, target: FramebufferTarget) *const Editor {
            @constCast(self)._pending_target = target;
            return @constCast(self);
        }
        /// Stages w/h size in pending state; on apply() overwrites Impl.width/height.
        /// without issuing GL calls. Use to keep CPU-side extents for viewports/blits
        /// in sync after you resize attachments yourself; prefer querying texture size
        /// when unsure. Pitfall: manual cache only, does NOT resize or reallocate any
        /// texture/renderbuffer attachment.
        /// Parameters:
        /// - self: editor instance.
        /// - w: new width in pixels (FBO window coords extent).
        /// - h: new height in pixels (FBO window coords extent).
        ///
        /// Returns: self for chaining.
        pub fn setSize(self: *const Editor, w: i32, h: i32) *const Editor {
            @constCast(self)._pending_size = .{ .w = w, .h = h };
            return @constCast(self);
        }
        /// Stages a 2D texture attach; on apply() issues glFramebufferTexture2D to.
        /// GL_COLOR_ATTACHMENT0+index and caches the id. Use for plain 2D faces;
        /// prefer setColorAttachmentLayer() for array/cubemap/3D slices and
        /// setRenderbuffer() for non-sampled storage. Pitfall: texture storage must
        /// already exist with matching size, otherwise the FBO is incomplete.
        /// Parameters:
        /// - self: editor instance.
        /// - index: color attachment index 0-15.
        /// - texture: texture identifier (GL texture object id).
        /// - textarget: texture target (e.g. .texture_2d).
        /// - level: mipmap level index (0 is base level).
        ///
        /// Returns: self for chaining.
        pub fn setColorAttachment(self: *const Editor, index: usize, texture: u32, textarget: TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_color = .{ .index = index, .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Stages N 2D texture attaches; on apply() issues glFramebufferTexture2D per.
        /// entry and caches each id. Use for MRT setup in one batch; prefer
        /// setColorAttachment() for a single output. Pitfall: entries share apply order
        /// with single/layered variants, later slots overwrite earlier ones on conflict;
        /// all textures should share size and sample count.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of color attachment descriptors.
        ///
        /// Returns: self for chaining.
        pub fn setColorAttachments(self: *const Editor, attachments: []const ColorAttachment) *const Editor {
            @constCast(self)._pending_multiple_colors = attachments;
            return @constCast(self);
        }
        /// Stages a layered single-slice attach; on apply() issues glFramebufferTexture.
        /// Layer to GL_COLOR_ATTACHMENT0+index and caches the id. Use for array textures,
        /// cubemap faces, or 3D slices; prefer setColorAttachment() for plain 2D.
        /// Pitfall: texture must be a layered type and layer must be in range, else the
        /// FBO is incomplete.
        /// Parameters:
        /// - self: editor instance.
        /// - index: color attachment index 0-15.
        /// - texture: texture identifier (GL texture object id).
        /// - level: mipmap level index (0 is base level).
        /// - layer: layer index (array/cubemap/3D slice).
        ///
        /// Returns: self for chaining.
        pub fn setColorAttachmentLayer(self: *const Editor, index: usize, texture: u32, level: i32, layer: i32) *const Editor {
            @constCast(self)._pending_color_layer = .{ .index = index, .texture = texture, .level = level, .layer = layer };
            return @constCast(self);
        }
        /// Stages a 2D depth texture attach; on apply() issues glFramebufferTexture2D.
        /// to .depth_attachment and caches the id. Use for sampled depth or shadow maps;
        /// prefer combined depth-stencil for packed D24S8 and setRenderbuffer() for
        /// non-sampled MSAA depth. Pitfall: do not mix with combined depth-stencil on
        /// the same FBO, and blits resolving depth require filter .nearest.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier (GL texture object id).
        /// - textarget: texture target (e.g. .texture_2d).
        /// - level: mipmap level index (0 is base level).
        ///
        /// Returns: self for chaining.
        pub fn setDepthAttachment(self: *const Editor, texture: u32, textarget: TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_depth = .{ .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Stages a 2D stencil texture attach; on apply() issues glFramebufferTexture2D.
        /// to .stencil_attachment and caches the id. Use only when standalone stencil is
        /// needed; combined depth-stencil is more widely supported. Pitfall: rarely used
        /// alone, must match FBO size, and blits resolving stencil require .nearest.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier (GL texture object id).
        /// - textarget: texture target (e.g. .texture_2d).
        /// - level: mipmap level index (0 is base level).
        ///
        /// Returns: self for chaining.
        pub fn setStencilAttachment(self: *const Editor, texture: u32, textarget: TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_stencil = .{ .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Stages a 2D combined texture attach; on apply() issues glFramebufferTexture2D.
        /// to .depth_stencil_attachment and caches the id. Use for packed D24S8 where
        /// depth+stencil travel together; prefer separate attaches only for exotic
        /// formats. Pitfall: conflicts with separate depth/stencil points, pick one style,
        /// and resolves require .nearest.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier (GL texture object id).
        /// - textarget: texture target (e.g. .texture_2d).
        /// - level: mipmap level index (0 is base level).
        ///
        /// Returns: self for chaining.
        pub fn setDepthStencilAttachment(self: *const Editor, texture: u32, textarget: TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_depth_stencil = .{ .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Stages a renderbuffer attach; on apply() issues glFramebufferRenderbuffer.
        /// and caches the id. Use for non-sampled MSAA or depth that never needs shader
        /// sampling; prefer texture attaches when sampling is required. Pitfall:
        /// renderbuffer storage must be allocated with matching size/samples or the FBO
        /// is incomplete.
        /// Parameters:
        /// - self: editor instance.
        /// - attachment: attachment point (color index, depth, stencil, or depth-stencil).
        /// - renderbuffer: renderbuffer identifier (GL renderbuffer object id).
        ///
        /// Returns: self for chaining.
        pub fn setRenderbuffer(self: *const Editor, attachment: Attachment, renderbuffer: u32) *const Editor {
            @constCast(self)._pending_renderbuffer = .{ .attachment = attachment, .renderbuffer = renderbuffer };
            return @constCast(self);
        }
        /// Stages N renderbuffer attaches; on apply() issues glFramebufferRenderbuffer.
        /// per entry and caches each id. Use to attach MSAA color+depth buffers together;
        /// prefer setRenderbuffer() for a single buffer. Pitfall: each storage must match
        /// FBO size/samples; color indices derive from attachment enum 0-15 range.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of attachment/renderbuffer pairs.
        ///
        /// Returns: self for chaining.
        pub fn setRenderbuffers(self: *const Editor, attachments: []const RenderbufferAttachment) *const Editor {
            @constCast(self)._pending_multiple_renderbuffers = attachments;
            return @constCast(self);
        }
        /// Stages a layered depth slice attach; on apply() issues glFramebufferTexture.
        /// Layer to .depth_attachment and caches the id. Use for arrayed shadow maps or
        /// 3D depth slices; prefer setDepthAttachment() for plain 2D. Pitfall: texture
        /// must be layered and layer in range; resolves require filter .nearest.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier (GL texture object id).
        /// - level: mipmap level index (0 is base level).
        /// - layer: layer index (array/cubemap/3D slice).
        ///
        /// Returns: self for chaining.
        pub fn setDepthAttachmentLayer(self: *const Editor, texture: u32, level: i32, layer: i32) *const Editor {
            @constCast(self)._pending_depth_layer = .{ .texture = texture, .level = level, .layer = layer };
            return @constCast(self);
        }
        /// Stages a layered stencil slice attach; on apply() issues glFramebufferTexture.
        /// Layer to .stencil_attachment and caches the id. Use for arrayed stencil slices;
        /// prefer setStencilAttachment() for plain 2D. Pitfall: rarely used layered, needs
        /// a layered texture and in-range layer or the FBO is incomplete.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier (GL texture object id).
        /// - level: mipmap level index (0 is base level).
        /// - layer: layer index (array/cubemap/3D slice).
        ///
        /// Returns: self for chaining.
        pub fn setStencilAttachmentLayer(self: *const Editor, texture: u32, level: i32, layer: i32) *const Editor {
            @constCast(self)._pending_stencil_layer = .{ .texture = texture, .level = level, .layer = layer };
            return @constCast(self);
        }
        /// Stages a layered combined slice attach; on apply() issues glFramebufferTexture.
        /// Layer to .depth_stencil_attachment and caches the id. Use for arrayed packed
        /// D24S8; prefer setDepthStencilAttachment() for plain 2D. Pitfall: conflicts with
        /// separate layered depth/stencil, pick one style; resolves need .nearest.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier (GL texture object id).
        /// - level: mipmap level index (0 is base level).
        /// - layer: layer index (array/cubemap/3D slice).
        ///
        /// Returns: self for chaining.
        pub fn setDepthStencilAttachmentLayer(self: *const Editor, texture: u32, level: i32, layer: i32) *const Editor {
            @constCast(self)._pending_depth_stencil_layer = .{ .texture = texture, .level = level, .layer = layer };
            return @constCast(self);
        }
        /// Stages a draw-buffers list; on apply() issues glDrawBuffers and overwrites.
        /// cached Impl.draw_buffers/draw_count. Use for MRT routing or disabling outputs
        /// with .none; prefer setReadBuffer() to choose the read source. Pitfall: list
        /// must match attached colors (max 16), mismatch yields incompleteness or no output.
        /// Parameters:
        /// - self: editor instance.
        /// - bufs: slice of draw buffer enums.
        ///
        /// Returns: self for chaining.
        pub fn setDrawBuffers(self: *const Editor, bufs: []const DrawBuffer) *const Editor {
            @constCast(self)._pending_draw_buffers = bufs;
            return @constCast(self);
        }
        /// Stages a read-buffer selection; on apply() issues glReadBuffer with no cache.
        /// change to draw state. Use to choose the glReadPixels/blit source; prefer
        /// setDrawBuffers() for MRT outputs. Pitfall: only one read buffer at a time,
        /// use .color_attachment0+i for FBOs vs .front/.back for the default framebuffer.
        /// Parameters:
        /// - self: editor instance.
        /// - src: read buffer to select as `readPixels` source.
        ///
        /// Returns: self for chaining.
        pub fn setReadBuffer(self: *const Editor, src: ReadBuffer) *const Editor {
            @constCast(self)._pending_read_buffer = src;
            return @constCast(self);
        }
        /// Stages an invalidate list; on apply() issues glInvalidateFramebuffer as a.
        /// perf hint without mutating cached attachments. Use after a pass whose contents
        /// will not be sampled to save bandwidth; prefer setInvalidateSub() for partial
        /// discard. Pitfall: hint only, contents become undefined and driver may ignore it;
        /// it never affects completeness.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of attachment identifiers to invalidate as GL enum values u32.
        ///
        /// Returns: self for chaining.
        pub fn setInvalidate(self: *const Editor, attachments: []const u32) *const Editor {
            @constCast(self)._pending_invalidate = attachments;
            return @constCast(self);
        }
        /// Stages a sub-rect invalidate; on apply() issues glInvalidateSubData as a perf.
        /// hint without mutating cached attachments. Use to discard only a dirty region;
        /// prefer setInvalidate() for whole attachments. Pitfall: hint only, region becomes
        /// undefined and may be ignored; rect is in pixels with lower-left origin.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of attachments to invalidate as GL enum values u32.
        /// - x: rectangle x origin in pixels (FBO window coords, origin lower-left).
        /// - y: rectangle y origin in pixels (FBO window coords, origin lower-left).
        /// - w: rectangle width in pixels (FBO window coords extent).
        /// - h: rectangle height in pixels (FBO window coords extent).
        ///
        /// Returns: self for chaining.
        pub fn setInvalidateSub(self: *const Editor, attachments: []const u32, x: i32, y: i32, w: i32, h: i32) *const Editor {
            @constCast(self)._pending_invalidate_sub = .{ .attachments = attachments, .x = x, .y = y, .w = w, .h = h };
            return @constCast(self);
        }
        /// Binds fb id to the pending-or-cached target then replays all queued GL calls.
        /// and syncs cached Impl state, finally resetting pending to empty. Use once after
        /// chaining setters to commit; prefer small batches over many single apply() calls
        /// to avoid redundant binds. Pitfall: fixed order (target/size/bind, colors, depth,
        /// layers, renderbuffers, draw/read/invalidate) so same-slot duplicates last-win;
        /// binds as a side effect.
        /// Parameters:
        /// - self: editor instance.
        ///
        /// Returns: void.
        pub fn apply(self: *const Editor) void {
            const fb = @constCast(self)._fb.impl();
            const loaded = gl.loader.loaded();
            const target = @constCast(self)._pending_target orelse fb.target;
            if (@constCast(self)._pending_target) |t| fb.target = t;
            if (@constCast(self)._pending_size) |s| {
                fb.width = s.w;
                fb.height = s.h;
            }
            if (loaded) gl.framebuffers.bind(target, fb.id);
            if (@constCast(self)._pending_multiple_colors) |arr| for (arr) |a| {
                const attachment: Attachment = @enumFromInt(@intFromEnum(Attachment.color_attachment0) + a.index);
                if (loaded) gl.framebuffers.attachTexture2d(target, attachment, a.textarget, a.texture, a.level);
                if (a.index < 16) fb.color_attachments[a.index] = a.texture;
            };
            if (@constCast(self)._pending_color) |c| {
                const attachment: Attachment = @enumFromInt(@intFromEnum(Attachment.color_attachment0) + c.index);
                if (loaded) gl.framebuffers.attachTexture2d(target, attachment, c.textarget, c.texture, c.level);
                if (c.index < 16) fb.color_attachments[c.index] = c.texture;
            }
            if (@constCast(self)._pending_color_layer) |c| {
                const attachment: Attachment = @enumFromInt(@intFromEnum(Attachment.color_attachment0) + c.index);
                if (loaded) gl.framebuffers.attachTextureLayer(target, attachment, c.texture, c.level, c.layer);
                if (c.index < 16) fb.color_attachments[c.index] = c.texture;
            }
            if (@constCast(self)._pending_depth) |d| {
                if (loaded) gl.framebuffers.attachTexture2d(target, .depth_attachment, d.textarget, d.texture, d.level);
                fb.depth_attachment = d.texture;
            }
            if (@constCast(self)._pending_stencil) |s| {
                if (loaded) gl.framebuffers.attachTexture2d(target, .stencil_attachment, s.textarget, s.texture, s.level);
                fb.stencil_attachment = s.texture;
            }
            if (@constCast(self)._pending_depth_stencil) |ds| {
                if (loaded) gl.framebuffers.attachTexture2d(target, .depth_stencil_attachment, ds.textarget, ds.texture, ds.level);
                fb.depth_stencil_attachment = ds.texture;
            }
            if (@constCast(self)._pending_depth_layer) |d| {
                if (loaded) gl.framebuffers.attachTextureLayer(target, .depth_attachment, d.texture, d.level, d.layer);
                fb.depth_attachment = d.texture;
            }
            if (@constCast(self)._pending_stencil_layer) |s| {
                if (loaded) gl.framebuffers.attachTextureLayer(target, .stencil_attachment, s.texture, s.level, s.layer);
                fb.stencil_attachment = s.texture;
            }
            if (@constCast(self)._pending_depth_stencil_layer) |ds| {
                if (loaded) gl.framebuffers.attachTextureLayer(target, .depth_stencil_attachment, ds.texture, ds.level, ds.layer);
                fb.depth_stencil_attachment = ds.texture;
            }
            if (@constCast(self)._pending_multiple_renderbuffers) |arr| for (arr) |r| {
                attachRenderbufferCached(fb, target, r.attachment, r.renderbuffer, loaded);
            };
            if (@constCast(self)._pending_renderbuffer) |r| {
                attachRenderbufferCached(fb, target, r.attachment, r.renderbuffer, loaded);
            }
            if (@constCast(self)._pending_draw_buffers) |bufs| {
                if (loaded) gl.framebuffers.drawBuffers(bufs);
                const n = @min(bufs.len, 16);
                @memcpy(fb.draw_buffers[0..n], bufs[0..n]);
                fb.draw_count = n;
            }
            if (@constCast(self)._pending_invalidate) |atts| if (loaded) gl.framebuffers.invalidate(target, atts);
            if (@constCast(self)._pending_invalidate_sub) |s| if (loaded) gl.framebuffers.invalidateSub(target, s.attachments, s.x, s.y, s.w, s.h);
            if (@constCast(self)._pending_read_buffer) |src| if (loaded) gl.pixels.readBuffer(src);
            @constCast(self).* = Editor.init(@constCast(self)._fb);
        }
    };
};
