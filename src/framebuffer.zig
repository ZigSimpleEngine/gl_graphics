const std = @import("std");
const gl = @import("gl");

pub const Framebuffer = struct {
    // ---- opaque ----
    _id: u32 = 0,
    _target: gl.framebuffers.FramebufferTarget = .framebuffer,
    _width: i32 = 0,
    _height: i32 = 0,
    _color_attachments: [16]?u32 = [_]?u32{null} ** 16, // texture ids or renderbuffer ids
    _depth_attachment: ?u32 = null,
    _stencil_attachment: ?u32 = null,
    _depth_stencil_attachment: ?u32 = null,
    _draw_buffers: [16]gl.framebuffers.DrawBuffer = [_]gl.framebuffers.DrawBuffer{.none} ** 16,
    _draw_count: usize = 1,

    // ------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------
    pub fn init() Framebuffer {
        var id: u32 = 0;
        gl.framebuffers.gen(1, &id);
        return .{ ._id = id };
    }

    pub fn deinit(self: *Framebuffer) void {
        if (self._id != 0) {
            gl.framebuffers.delete(1, &self._id);
            self._id = 0;
        }
    }

    pub fn isValid(self: *const Framebuffer) bool {
        return self._id != 0 and gl.framebuffers.isFramebuffer(self._id);
    }

    // ------------------------------------------------------------
    // Getters
    // ------------------------------------------------------------
    pub fn getId(self: *const Framebuffer) u32 { return self._id; }
    pub fn getTarget(self: *const Framebuffer) gl.framebuffers.FramebufferTarget { return self._target; }
    pub fn getWidth(self: *const Framebuffer) i32 { return self._width; }
    pub fn getHeight(self: *const Framebuffer) i32 { return self._height; }
    pub fn getColorAttachment(self: *const Framebuffer, index: usize) ?u32 {
        if (index >= 16) return null;
        return self._color_attachments[index];
    }
    pub fn getDepthAttachment(self: *const Framebuffer) ?u32 { return self._depth_attachment; }
    pub fn getStencilAttachment(self: *const Framebuffer) ?u32 { return self._stencil_attachment; }
    pub fn getDepthStencilAttachment(self: *const Framebuffer) ?u32 { return self._depth_stencil_attachment; }
    pub fn getDrawBuffers(self: *const Framebuffer) []const gl.framebuffers.DrawBuffer {
        return self._draw_buffers[0..self._draw_count];
    }

    pub fn getStatus(self: *const Framebuffer) gl.framebuffers.FramebufferStatus {
        self.bind();
        return gl.framebuffers.checkStatus(self._target);
    }

    pub fn isComplete(self: *const Framebuffer) bool {
        return self.getStatus() == .framebuffer_complete;
    }

    pub fn getAttachmentParameter(self: *const Framebuffer, attachment: gl.framebuffers.Attachment, pname: gl.framebuffers.AttachmentParameter) i32 {
        self.bind();
        var v: i32 = 0;
        gl.framebuffers.getAttachmentParameter(self._target, attachment, pname, &v);
        return v;
    }

    pub fn bind(self: *const Framebuffer) void {
        gl.framebuffers.bind(self._target, self._id);
    }
    pub fn bindTo(self: *const Framebuffer, target: gl.framebuffers.FramebufferTarget) void {
        gl.framebuffers.bind(target, self._id);
    }
    pub fn use(self: *const Framebuffer) void { self.bind(); }

    pub fn bindDefault(target: gl.framebuffers.FramebufferTarget) void {
        gl.framebuffers.bind(target, 0);
    }
    pub fn useDefault() void { bindDefault(.framebuffer); }

    // ------------------------------------------------------------
    // Editor
    // ------------------------------------------------------------
    pub fn edit(self: *Framebuffer) Editor {
        return Editor.init(self);
    }

    pub const Editor = struct {
        _fb: *Framebuffer,

        _pending_target: ?gl.framebuffers.FramebufferTarget = null,
        _pending_size: ?struct { w: i32, h: i32 } = null,
        _pending_color: ?struct {
            index: usize,
            texture: u32,
            textarget: gl.textures.TextureTarget,
            level: i32,
        } = null,
        _pending_color_layer: ?struct {
            index: usize,
            texture: u32,
            level: i32,
            layer: i32,
        } = null,
        _pending_depth: ?struct {
            texture: u32,
            textarget: gl.textures.TextureTarget,
            level: i32,
        } = null,
        _pending_stencil: ?struct {
            texture: u32,
            textarget: gl.textures.TextureTarget,
            level: i32,
        } = null,
        _pending_depth_stencil: ?struct {
            texture: u32,
            textarget: gl.textures.TextureTarget,
            level: i32,
        } = null,
        _pending_renderbuffer: ?struct {
            attachment: gl.framebuffers.Attachment,
            renderbuffer: u32,
        } = null,
        _pending_draw_buffers: ?[]const gl.framebuffers.DrawBuffer = null,
        _pending_invalidate: ?[]const u32 = null,
        _pending_invalidate_sub: ?struct {
            attachments: []const u32,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
        } = null,
        _pending_read_buffer: ?u32 = null,

        // Multiple color attachments batch
        _pending_multiple_colors: ?[]const struct {
            index: usize,
            texture: u32,
            textarget: gl.textures.TextureTarget,
            level: i32,
        } = null,

        pub fn init(fb: *Framebuffer) Editor {
            return .{ ._fb = fb };
        }

        pub fn setTarget(self: *Editor, target: gl.framebuffers.FramebufferTarget) *Editor {
            self._pending_target = target;
            return self;
        }
        pub fn setSize(self: *Editor, w: i32, h: i32) *Editor {
            self._pending_size = .{ .w = w, .h = h };
            return self;
        }
        pub fn setColorAttachment(self: *Editor, index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor {
            self._pending_color = .{ .index = index, .texture = texture, .textarget = textarget, .level = level };
            return self;
        }
        pub fn setColorAttachments(self: *Editor, attachments: []const struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 }) *Editor {
            self._pending_multiple_colors = attachments;
            return self;
        }
        pub fn setColorAttachmentLayer(self: *Editor, index: usize, texture: u32, level: i32, layer: i32) *Editor {
            self._pending_color_layer = .{ .index = index, .texture = texture, .level = level, .layer = layer };
            return self;
        }
        pub fn setDepthAttachment(self: *Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor {
            self._pending_depth = .{ .texture = texture, .textarget = textarget, .level = level };
            return self;
        }
        pub fn setStencilAttachment(self: *Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor {
            self._pending_stencil = .{ .texture = texture, .textarget = textarget, .level = level };
            return self;
        }
        pub fn setDepthStencilAttachment(self: *Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor {
            self._pending_depth_stencil = .{ .texture = texture, .textarget = textarget, .level = level };
            return self;
        }
        pub fn setRenderbuffer(self: *Editor, attachment: gl.framebuffers.Attachment, renderbuffer: u32) *Editor {
            self._pending_renderbuffer = .{ .attachment = attachment, .renderbuffer = renderbuffer };
            return self;
        }
        pub fn setDrawBuffers(self: *Editor, bufs: []const gl.framebuffers.DrawBuffer) *Editor {
            self._pending_draw_buffers = bufs;
            return self;
        }
        pub fn setReadBuffer(self: *Editor, src: u32) *Editor {
            self._pending_read_buffer = src;
            return self;
        }
        pub fn setInvalidate(self: *Editor, attachments: []const u32) *Editor {
            self._pending_invalidate = attachments;
            return self;
        }
        pub fn setInvalidateSub(self: *Editor, attachments: []const u32, x: i32, y: i32, w: i32, h: i32) *Editor {
            self._pending_invalidate_sub = .{ .attachments = attachments, .x = x, .y = y, .w = w, .h = h };
            return self;
        }
        pub fn apply(self: *Editor) void {
            const fb = self._fb;
            const target = self._pending_target orelse fb._target;
            if (self._pending_target) |t| fb._target = t;
            if (self._pending_size) |s| {
                fb._width = s.w;
                fb._height = s.h;
            }
            gl.framebuffers.bind(target, fb._id);

            if (self._pending_multiple_colors) |arr| {
                for (arr) |a| {
                    const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + a.index);
                    gl.framebuffers.attachTexture2d(target, attachment, a.textarget, a.texture, a.level);
                    if (a.index < 16) fb._color_attachments[a.index] = a.texture;
                }
            }
            if (self._pending_color) |c| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + c.index);
                gl.framebuffers.attachTexture2d(target, attachment, c.textarget, c.texture, c.level);
                if (c.index < 16) fb._color_attachments[c.index] = c.texture;
            }
            if (self._pending_color_layer) |c| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + c.index);
                gl.framebuffers.attachTextureLayer(target, attachment, c.texture, c.level, c.layer);
                if (c.index < 16) fb._color_attachments[c.index] = c.texture;
            }
            if (self._pending_depth) |d| {
                gl.framebuffers.attachTexture2d(target, .depth_attachment, d.textarget, d.texture, d.level);
                fb._depth_attachment = d.texture;
            }
            if (self._pending_stencil) |s| {
                gl.framebuffers.attachTexture2d(target, .stencil_attachment, s.textarget, s.texture, s.level);
                fb._stencil_attachment = s.texture;
            }
            if (self._pending_depth_stencil) |ds| {
                gl.framebuffers.attachTexture2d(target, .depth_stencil_attachment, ds.textarget, ds.texture, ds.level);
                fb._depth_stencil_attachment = ds.texture;
            }
            if (self._pending_renderbuffer) |r| {
                gl.framebuffers.attachRenderbuffer(target, r.attachment, r.renderbuffer);
                // Update cache for non-color attachments
                switch (r.attachment) {
                    .depth_attachment => fb._depth_attachment = r.renderbuffer,
                    .stencil_attachment => fb._stencil_attachment = r.renderbuffer,
                    .depth_stencil_attachment => fb._depth_stencil_attachment = r.renderbuffer,
                    else => {
                        const idx = @intFromEnum(r.attachment) - @intFromEnum(gl.framebuffers.Attachment.color_attachment0);
                        if (idx >= 0 and idx < 16) fb._color_attachments[@intCast(idx)] = r.renderbuffer;
                    },
                }
            }
            if (self._pending_draw_buffers) |bufs| {
                gl.framebuffers.drawBuffers(bufs);
                const n = @min(bufs.len, 16);
                @memcpy(fb._draw_buffers[0..n], bufs[0..n]);
                fb._draw_count = n;
            }
            if (self._pending_invalidate) |atts| {
                gl.framebuffers.invalidate(target, atts);
            }
            if (self._pending_invalidate_sub) |s| {
                gl.framebuffers.invalidateSub(target, s.attachments, s.x, s.y, s.w, s.h);
            }
            if (self._pending_read_buffer) |src| {
                // gl.readBuffer is not in framebuffers namespace but in state? Use raw loader
                // For now expose via gl.loader?
                _ = src;
                // gl.loader.context.readBuffer(src); // not wrapped
            }

            self.* = Editor.init(fb);
        }
    };
};
