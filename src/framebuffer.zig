/// Standard library import.
const std = @import("std");
/// OpenGL bindings import.
const gl = @import("gl");

/// Internal implementation storage for an opaque Framebuffer handle.
/// Holds OpenGL object state and cached attachments.
const Impl = struct {
    /// OpenGL framebuffer object identifier.
    id: u32 = 0,
    /// Target binding point for this framebuffer.
    target: gl.framebuffers.FramebufferTarget = .framebuffer,
    /// Width of the framebuffer in pixels.
    width: i32 = 0,
    /// Height of the framebuffer in pixels.
    height: i32 = 0,
    /// Cached color attachment identifiers indexed by attachment index.
    color_attachments: [16]?u32 = [_]?u32{null} ** 16,
    /// Cached depth attachment identifier if present.
    depth_attachment: ?u32 = null,
    /// Cached stencil attachment identifier if present.
    stencil_attachment: ?u32 = null,
    /// Cached combined depth-stencil attachment identifier if present.
    depth_stencil_attachment: ?u32 = null,
    /// Cached draw buffer configuration for multiple render targets.
    draw_buffers: [16]gl.framebuffers.DrawBuffer = [_]gl.framebuffers.DrawBuffer{.none} ** 16,
    /// Number of active draw buffers in use.
    draw_count: usize = 1,
};

/// Opaque framebuffer object with builder-style editing.
pub const Framebuffer = opaque {
    /// Returns mutable implementation pointer for this handle.
    /// Parameters:
    /// - self: mutable opaque framebuffer pointer.
    /// Returns: pointer to internal Impl.
    inline fn impl(self: *Framebuffer) *Impl {
        return @ptrCast(@alignCast(self));
    }
    /// Returns immutable implementation pointer for this handle.
    /// Parameters:
    /// - self: const opaque framebuffer pointer.
    /// Returns: pointer to const Impl.
    inline fn implConst(self: *const Framebuffer) *const Impl {
        return @ptrCast(@alignCast(self));
    }

    /// Creates a new framebuffer object.
    /// Parameters:
    /// - allocator: allocator used to allocate Impl storage.
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
    /// Alias for create that provides conventional init naming.
    /// Parameters:
    /// - allocator: allocator used to allocate Impl storage.
    /// Returns: pointer to created Framebuffer.
    pub fn init(allocator: std.mem.Allocator) !*Framebuffer {
        return create(allocator);
    }
    /// Destroys the framebuffer and frees Impl storage.
    /// Parameters:
    /// - self: framebuffer to destroy.
    /// - allocator: allocator that was used for creation.
    /// Returns: void.
    pub fn destroy(self: *Framebuffer, allocator: std.mem.Allocator) void {
        const m = self.impl();
        if (gl.loader.loaded() and m.id != 0) gl.framebuffers.delete(1, @ptrCast(&m.id));
        allocator.destroy(m);
    }
    /// Alias for destroy with conventional deinit naming.
    /// Parameters:
    /// - self: framebuffer to deinitialize.
    /// - allocator: allocator that was used for creation.
    /// Returns: void.
    pub fn deinit(self: *Framebuffer, allocator: std.mem.Allocator) void {
        self.destroy(allocator);
    }
    /// Checks whether the underlying OpenGL framebuffer object is valid.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: true if the framebuffer exists.
    pub fn isValid(self: *const Framebuffer) bool {
        const m = self.implConst();
        return m.id != 0 and gl.framebuffers.isFramebuffer(m.id);
    }

    /// Returns the OpenGL identifier for this framebuffer.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: OpenGL framebuffer id.
    pub fn getId(self: *const Framebuffer) u32 {
        return self.implConst().id;
    }
    /// Returns the current binding target.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: framebuffer target enum.
    pub fn getTarget(self: *const Framebuffer) gl.framebuffers.FramebufferTarget {
        return self.implConst().target;
    }
    /// Returns the cached width.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: width in pixels.
    pub fn getWidth(self: *const Framebuffer) i32 {
        return self.implConst().width;
    }
    /// Returns the cached height.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: height in pixels.
    pub fn getHeight(self: *const Framebuffer) i32 {
        return self.implConst().height;
    }
    /// Returns the color attachment at the given index.
    /// Parameters:
    /// - self: framebuffer to query.
    /// - index: color attachment index.
    /// Returns: texture or renderbuffer id or null if out of bounds or unset.
    pub fn getColorAttachment(self: *const Framebuffer, index: usize) ?u32 {
        if (index >= 16) return null;
        return self.implConst().color_attachments[index];
    }
    /// Returns the depth attachment identifier if present.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: optional depth attachment id.
    pub fn getDepthAttachment(self: *const Framebuffer) ?u32 {
        return self.implConst().depth_attachment;
    }
    /// Returns the stencil attachment identifier if present.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: optional stencil attachment id.
    pub fn getStencilAttachment(self: *const Framebuffer) ?u32 {
        return self.implConst().stencil_attachment;
    }
    /// Returns the combined depth-stencil attachment identifier if present.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: optional depth-stencil attachment id.
    pub fn getDepthStencilAttachment(self: *const Framebuffer) ?u32 {
        return self.implConst().depth_stencil_attachment;
    }
    /// Returns the active draw buffer list.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: slice of draw buffers currently configured.
    pub fn getDrawBuffers(self: *const Framebuffer) []const gl.framebuffers.DrawBuffer {
        const m = self.implConst();
        return m.draw_buffers[0..m.draw_count];
    }
    /// Checks and returns framebuffer completeness status.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: framebuffer status enum.
    pub fn getStatus(self: *const Framebuffer) gl.framebuffers.FramebufferStatus {
        self.bind();
        return gl.framebuffers.checkStatus(self.implConst().target);
    }
    /// Returns true if the framebuffer is complete.
    /// Parameters:
    /// - self: framebuffer to query.
    /// Returns: true when status is framebuffer_complete.
    pub fn isComplete(self: *const Framebuffer) bool {
        return self.getStatus() == .framebuffer_complete;
    }
    /// Queries a framebuffer attachment parameter.
    /// Parameters:
    /// - self: framebuffer to query.
    /// - attachment: attachment point to query.
    /// - pname: parameter name to query.
    /// Returns: integer value of the parameter.
    pub fn getAttachmentParameter(self: *const Framebuffer, attachment: gl.framebuffers.Attachment, pname: gl.framebuffers.AttachmentParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.framebuffers.getAttachmentParameter(self.implConst().target, attachment, pname, @ptrCast(&v));
        return v;
    }
    /// Binds this framebuffer to its stored target.
    /// Parameters:
    /// - self: framebuffer to bind.
    /// Returns: void.
    pub fn bind(self: *const Framebuffer) void {
        const m = self.implConst();
        gl.framebuffers.bind(m.target, m.id);
    }
    /// Binds this framebuffer to an explicit target.
    /// Parameters:
    /// - self: framebuffer to bind.
    /// - target: framebuffer target to bind to.
    /// Returns: void.
    pub fn bindTo(self: *const Framebuffer, target: gl.framebuffers.FramebufferTarget) void {
        gl.framebuffers.bind(target, self.implConst().id);
    }
    /// Binds this framebuffer for use as current framebuffer.
    /// Parameters:
    /// - self: framebuffer to use.
    /// Returns: void.
    pub fn use(self: *const Framebuffer) void {
        self.bind();
    }
    /// Binds the default framebuffer for a given target.
    /// Parameters:
    /// - target: target to bind default framebuffer to.
    /// Returns: void.
    pub fn bindDefault(target: gl.framebuffers.FramebufferTarget) void {
        gl.framebuffers.bind(target, 0);
    }
    /// Binds the default framebuffer to the generic framebuffer target.
    /// Parameters: none.
    /// Returns: void.
    pub fn useDefault() void {
        bindDefault(.framebuffer);
    }

    /// Returns an editor for batched framebuffer mutation.
    /// Parameters:
    /// - self: framebuffer to edit.
    /// Returns: Editor instance referencing this framebuffer.
    pub fn edit(self: *Framebuffer) Editor {
        return Editor.init(self);
    }

    /// Builder for deferred framebuffer state changes.
    pub const Editor = struct {
        /// Reference to the framebuffer being edited.
        _fb: *Framebuffer,
        /// Pending target change if any.
        _pending_target: ?gl.framebuffers.FramebufferTarget = null,
        /// Pending size change if any.
        _pending_size: ?struct { w: i32, h: i32 } = null,
        /// Pending single color attachment change.
        _pending_color: ?struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        /// Pending layered color attachment change.
        _pending_color_layer: ?struct { index: usize, texture: u32, level: i32, layer: i32 } = null,
        /// Pending depth attachment change.
        _pending_depth: ?struct { texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        /// Pending stencil attachment change.
        _pending_stencil: ?struct { texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        /// Pending depth-stencil attachment change.
        _pending_depth_stencil: ?struct { texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        /// Pending renderbuffer attachment change.
        _pending_renderbuffer: ?struct { attachment: gl.framebuffers.Attachment, renderbuffer: u32 } = null,
        /// Pending draw buffers change.
        _pending_draw_buffers: ?[]const gl.framebuffers.DrawBuffer = null,
        /// Pending invalidate attachments list.
        _pending_invalidate: ?[]const u32 = null,
        /// Pending invalidate sub-rectangle operation.
        _pending_invalidate_sub: ?struct { attachments: []const u32, x: i32, y: i32, w: i32, h: i32 } = null,
        /// Pending read buffer selection.
        _pending_read_buffer: ?u32 = null,
        /// Pending batch of color attachments.
        _pending_multiple_colors: ?[]const struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,

        /// Creates an editor bound to a framebuffer.
        /// Parameters:
        /// - fb: framebuffer to edit.
        /// Returns: initialized Editor.
        pub fn init(fb: *Framebuffer) Editor {
            return .{ ._fb = fb };
        }
        /// Queues a target change.
        /// Parameters:
        /// - self: editor instance.
        /// - target: new framebuffer target.
        /// Returns: self for chaining.
        pub fn setTarget(self: *const Editor, target: gl.framebuffers.FramebufferTarget) *const Editor {
            @constCast(self)._pending_target = target;
            return @constCast(self);
        }
        /// Queues a size change.
        /// Parameters:
        /// - self: editor instance.
        /// - w: new width.
        /// - h: new height.
        /// Returns: self for chaining.
        pub fn setSize(self: *const Editor, w: i32, h: i32) *const Editor {
            @constCast(self)._pending_size = .{ .w = w, .h = h };
            return @constCast(self);
        }
        /// Queues a color attachment assignment.
        /// Parameters:
        /// - self: editor instance.
        /// - index: color attachment index.
        /// - texture: texture identifier.
        /// - textarget: texture target.
        /// - level: mipmap level.
        /// Returns: self for chaining.
        pub fn setColorAttachment(self: *const Editor, index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_color = .{ .index = index, .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Queues multiple color attachments at once.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of color attachment descriptors.
        /// Returns: self for chaining.
        pub fn setColorAttachments(self: *const Editor, attachments: []const struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 }) *const Editor {
            @constCast(self)._pending_multiple_colors = attachments;
            return @constCast(self);
        }
        /// Queues a layered color attachment assignment.
        /// Parameters:
        /// - self: editor instance.
        /// - index: color attachment index.
        /// - texture: texture identifier.
        /// - level: mipmap level.
        /// - layer: layer index.
        /// Returns: self for chaining.
        pub fn setColorAttachmentLayer(self: *const Editor, index: usize, texture: u32, level: i32, layer: i32) *const Editor {
            @constCast(self)._pending_color_layer = .{ .index = index, .texture = texture, .level = level, .layer = layer };
            return @constCast(self);
        }
        /// Queues a depth attachment assignment.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier.
        /// - textarget: texture target.
        /// - level: mipmap level.
        /// Returns: self for chaining.
        pub fn setDepthAttachment(self: *const Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_depth = .{ .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Queues a stencil attachment assignment.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier.
        /// - textarget: texture target.
        /// - level: mipmap level.
        /// Returns: self for chaining.
        pub fn setStencilAttachment(self: *const Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_stencil = .{ .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Queues a depth-stencil attachment assignment.
        /// Parameters:
        /// - self: editor instance.
        /// - texture: texture identifier.
        /// - textarget: texture target.
        /// - level: mipmap level.
        /// Returns: self for chaining.
        pub fn setDepthStencilAttachment(self: *const Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *const Editor {
            @constCast(self)._pending_depth_stencil = .{ .texture = texture, .textarget = textarget, .level = level };
            return @constCast(self);
        }
        /// Queues a renderbuffer attachment assignment.
        /// Parameters:
        /// - self: editor instance.
        /// - attachment: attachment point.
        /// - renderbuffer: renderbuffer identifier.
        /// Returns: self for chaining.
        pub fn setRenderbuffer(self: *const Editor, attachment: gl.framebuffers.Attachment, renderbuffer: u32) *const Editor {
            @constCast(self)._pending_renderbuffer = .{ .attachment = attachment, .renderbuffer = renderbuffer };
            return @constCast(self);
        }
        /// Queues draw buffers configuration.
        /// Parameters:
        /// - self: editor instance.
        /// - bufs: slice of draw buffer enums.
        /// Returns: self for chaining.
        pub fn setDrawBuffers(self: *const Editor, bufs: []const gl.framebuffers.DrawBuffer) *const Editor {
            @constCast(self)._pending_draw_buffers = bufs;
            return @constCast(self);
        }
        /// Queues read buffer selection.
        /// Parameters:
        /// - self: editor instance.
        /// - src: read buffer identifier.
        /// Returns: self for chaining.
        pub fn setReadBuffer(self: *const Editor, src: u32) *const Editor {
            @constCast(self)._pending_read_buffer = src;
            return @constCast(self);
        }
        /// Queues framebuffer invalidate operation.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of attachment identifiers to invalidate.
        /// Returns: self for chaining.
        pub fn setInvalidate(self: *const Editor, attachments: []const u32) *const Editor {
            @constCast(self)._pending_invalidate = attachments;
            return @constCast(self);
        }
        /// Queues framebuffer invalidate sub-rectangle operation.
        /// Parameters:
        /// - self: editor instance.
        /// - attachments: slice of attachments to invalidate.
        /// - x: rectangle x origin.
        /// - y: rectangle y origin.
        /// - w: rectangle width.
        /// - h: rectangle height.
        /// Returns: self for chaining.
        pub fn setInvalidateSub(self: *const Editor, attachments: []const u32, x: i32, y: i32, w: i32, h: i32) *const Editor {
            @constCast(self)._pending_invalidate_sub = .{ .attachments = attachments, .x = x, .y = y, .w = w, .h = h };
            return @constCast(self);
        }
        /// Applies all queued changes to the framebuffer.
        /// Parameters:
        /// - self: editor instance.
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
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + a.index);
                if (loaded) gl.framebuffers.attachTexture2d(target, attachment, a.textarget, a.texture, a.level);
                if (a.index < 16) fb.color_attachments[a.index] = a.texture;
            };
            if (@constCast(self)._pending_color) |c| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + c.index);
                if (loaded) gl.framebuffers.attachTexture2d(target, attachment, c.textarget, c.texture, c.level);
                if (c.index < 16) fb.color_attachments[c.index] = c.texture;
            }
            if (@constCast(self)._pending_color_layer) |c| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + c.index);
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
            if (@constCast(self)._pending_renderbuffer) |r| {
                if (loaded) gl.framebuffers.attachRenderbuffer(target, r.attachment, r.renderbuffer);
                switch (r.attachment) {
                    .depth_attachment => fb.depth_attachment = r.renderbuffer,
                    .stencil_attachment => fb.stencil_attachment = r.renderbuffer,
                    .depth_stencil_attachment => fb.depth_stencil_attachment = r.renderbuffer,
                    else => {
                        const idx = @intFromEnum(r.attachment) - @intFromEnum(gl.framebuffers.Attachment.color_attachment0);
                        if (idx >= 0 and idx < 16) fb.color_attachments[@intCast(idx)] = r.renderbuffer;
                    },
                }
            }
            if (@constCast(self)._pending_draw_buffers) |bufs| {
                if (loaded) gl.framebuffers.drawBuffers(bufs);
                const n = @min(bufs.len, 16);
                @memcpy(fb.draw_buffers[0..n], bufs[0..n]);
                fb.draw_count = n;
            }
            if (@constCast(self)._pending_invalidate) |atts| if (loaded) gl.framebuffers.invalidate(target, atts);
            if (@constCast(self)._pending_invalidate_sub) |s| if (loaded) gl.framebuffers.invalidateSub(target, s.attachments, s.x, s.y, s.w, s.h);
            _ = @constCast(self)._pending_read_buffer;
            @constCast(self).* = Editor.init(@constCast(self)._fb);
        }
    };
};
