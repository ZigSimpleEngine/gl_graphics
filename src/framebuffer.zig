const std = @import("std");
const gl = @import("gl");

const Impl = struct {
    id: u32 = 0,
    target: gl.framebuffers.FramebufferTarget = .framebuffer,
    width: i32 = 0,
    height: i32 = 0,
    color_attachments: [16]?u32 = [_]?u32{null} ** 16,
    depth_attachment: ?u32 = null,
    stencil_attachment: ?u32 = null,
    depth_stencil_attachment: ?u32 = null,
    draw_buffers: [16]gl.framebuffers.DrawBuffer = [_]gl.framebuffers.DrawBuffer{.none} ** 16,
    draw_count: usize = 1,
};

pub const Framebuffer = opaque {
    inline fn impl(self: *Framebuffer) *Impl { return @ptrCast(@alignCast(self)); }
    inline fn implConst(self: *const Framebuffer) *const Impl { return @ptrCast(@alignCast(self)); }

    pub fn create(allocator: std.mem.Allocator) !*Framebuffer {
        const m = try allocator.create(Impl);
        m.* = .{};
        var id: u32 = 0;
        gl.framebuffers.gen(1, &id);
        m.id = id;
        return @ptrCast(m);
    }
    pub fn init(allocator: std.mem.Allocator) !*Framebuffer { return create(allocator); }
    pub fn destroy(self: *Framebuffer, allocator: std.mem.Allocator) void {
        const m = self.impl();
        if (m.id != 0) gl.framebuffers.delete(1, &m.id);
        allocator.destroy(m);
    }
    pub fn deinit(self: *Framebuffer, allocator: std.mem.Allocator) void { self.destroy(allocator); }
    pub fn isValid(self: *const Framebuffer) bool { const m = self.implConst(); return m.id != 0 and gl.framebuffers.isFramebuffer(m.id); }

    pub fn getId(self: *const Framebuffer) u32 { return self.implConst().id; }
    pub fn getTarget(self: *const Framebuffer) gl.framebuffers.FramebufferTarget { return self.implConst().target; }
    pub fn getWidth(self: *const Framebuffer) i32 { return self.implConst().width; }
    pub fn getHeight(self: *const Framebuffer) i32 { return self.implConst().height; }
    pub fn getColorAttachment(self: *const Framebuffer, index: usize) ?u32 { if (index >= 16) return null; return self.implConst().color_attachments[index]; }
    pub fn getDepthAttachment(self: *const Framebuffer) ?u32 { return self.implConst().depth_attachment; }
    pub fn getStencilAttachment(self: *const Framebuffer) ?u32 { return self.implConst().stencil_attachment; }
    pub fn getDepthStencilAttachment(self: *const Framebuffer) ?u32 { return self.implConst().depth_stencil_attachment; }
    pub fn getDrawBuffers(self: *const Framebuffer) []const gl.framebuffers.DrawBuffer { const m = self.implConst(); return m.draw_buffers[0..m.draw_count]; }
    pub fn getStatus(self: *const Framebuffer) gl.framebuffers.FramebufferStatus { self.bind(); return gl.framebuffers.checkStatus(self.implConst().target); }
    pub fn isComplete(self: *const Framebuffer) bool { return self.getStatus() == .framebuffer_complete; }
    pub fn getAttachmentParameter(self: *const Framebuffer, attachment: gl.framebuffers.Attachment, pname: gl.framebuffers.AttachmentParameter) i32 {
        self.bind(); var v: i32 = 0; gl.framebuffers.getAttachmentParameter(self.implConst().target, attachment, pname, &v); return v;
    }
    pub fn bind(self: *const Framebuffer) void { const m = self.implConst(); gl.framebuffers.bind(m.target, m.id); }
    pub fn bindTo(self: *const Framebuffer, target: gl.framebuffers.FramebufferTarget) void { gl.framebuffers.bind(target, self.implConst().id); }
    pub fn use(self: *const Framebuffer) void { self.bind(); }
    pub fn bindDefault(target: gl.framebuffers.FramebufferTarget) void { gl.framebuffers.bind(target, 0); }
    pub fn useDefault() void { bindDefault(.framebuffer); }

    pub fn edit(self: *Framebuffer) Editor { return Editor.init(self); }

    pub const Editor = struct {
        _fb: *Framebuffer,
        _pending_target: ?gl.framebuffers.FramebufferTarget = null,
        _pending_size: ?struct { w: i32, h: i32 } = null,
        _pending_color: ?struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        _pending_color_layer: ?struct { index: usize, texture: u32, level: i32, layer: i32 } = null,
        _pending_depth: ?struct { texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        _pending_stencil: ?struct { texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        _pending_depth_stencil: ?struct { texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,
        _pending_renderbuffer: ?struct { attachment: gl.framebuffers.Attachment, renderbuffer: u32 } = null,
        _pending_draw_buffers: ?[]const gl.framebuffers.DrawBuffer = null,
        _pending_invalidate: ?[]const u32 = null,
        _pending_invalidate_sub: ?struct { attachments: []const u32, x: i32, y: i32, w: i32, h: i32 } = null,
        _pending_read_buffer: ?u32 = null,
        _pending_multiple_colors: ?[]const struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 } = null,

        pub fn init(fb: *Framebuffer) Editor { return .{ ._fb = fb }; }
        pub fn setTarget(self: *Editor, target: gl.framebuffers.FramebufferTarget) *Editor { self._pending_target = target; return self; }
        pub fn setSize(self: *Editor, w: i32, h: i32) *Editor { self._pending_size = .{ .w = w, .h = h }; return self; }
        pub fn setColorAttachment(self: *Editor, index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor { self._pending_color = .{ .index = index, .texture = texture, .textarget = textarget, .level = level }; return self; }
        pub fn setColorAttachments(self: *Editor, attachments: []const struct { index: usize, texture: u32, textarget: gl.textures.TextureTarget, level: i32 }) *Editor { self._pending_multiple_colors = attachments; return self; }
        pub fn setColorAttachmentLayer(self: *Editor, index: usize, texture: u32, level: i32, layer: i32) *Editor { self._pending_color_layer = .{ .index = index, .texture = texture, .level = level, .layer = layer }; return self; }
        pub fn setDepthAttachment(self: *Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor { self._pending_depth = .{ .texture = texture, .textarget = textarget, .level = level }; return self; }
        pub fn setStencilAttachment(self: *Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor { self._pending_stencil = .{ .texture = texture, .textarget = textarget, .level = level }; return self; }
        pub fn setDepthStencilAttachment(self: *Editor, texture: u32, textarget: gl.textures.TextureTarget, level: i32) *Editor { self._pending_depth_stencil = .{ .texture = texture, .textarget = textarget, .level = level }; return self; }
        pub fn setRenderbuffer(self: *Editor, attachment: gl.framebuffers.Attachment, renderbuffer: u32) *Editor { self._pending_renderbuffer = .{ .attachment = attachment, .renderbuffer = renderbuffer }; return self; }
        pub fn setDrawBuffers(self: *Editor, bufs: []const gl.framebuffers.DrawBuffer) *Editor { self._pending_draw_buffers = bufs; return self; }
        pub fn setReadBuffer(self: *Editor, src: u32) *Editor { self._pending_read_buffer = src; return self; }
        pub fn setInvalidate(self: *Editor, attachments: []const u32) *Editor { self._pending_invalidate = attachments; return self; }
        pub fn setInvalidateSub(self: *Editor, attachments: []const u32, x: i32, y: i32, w: i32, h: i32) *Editor { self._pending_invalidate_sub = .{ .attachments = attachments, .x = x, .y = y, .w = w, .h = h }; return self; }
        pub fn apply(self: *Editor) void {
            const fb = self._fb.impl();
            const target = self._pending_target orelse fb.target;
            if (self._pending_target) |t| fb.target = t;
            if (self._pending_size) |s| { fb.width = s.w; fb.height = s.h; }
            gl.framebuffers.bind(target, fb.id);
            if (self._pending_multiple_colors) |arr| for (arr) |a| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + a.index);
                gl.framebuffers.attachTexture2d(target, attachment, a.textarget, a.texture, a.level);
                if (a.index < 16) fb.color_attachments[a.index] = a.texture;
            };
            if (self._pending_color) |c| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + c.index);
                gl.framebuffers.attachTexture2d(target, attachment, c.textarget, c.texture, c.level);
                if (c.index < 16) fb.color_attachments[c.index] = c.texture;
            }
            if (self._pending_color_layer) |c| {
                const attachment: gl.framebuffers.Attachment = @enumFromInt(@intFromEnum(gl.framebuffers.Attachment.color_attachment0) + c.index);
                gl.framebuffers.attachTextureLayer(target, attachment, c.texture, c.level, c.layer);
                if (c.index < 16) fb.color_attachments[c.index] = c.texture;
            }
            if (self._pending_depth) |d| { gl.framebuffers.attachTexture2d(target, .depth_attachment, d.textarget, d.texture, d.level); fb.depth_attachment = d.texture; }
            if (self._pending_stencil) |s| { gl.framebuffers.attachTexture2d(target, .stencil_attachment, s.textarget, s.texture, s.level); fb.stencil_attachment = s.texture; }
            if (self._pending_depth_stencil) |ds| { gl.framebuffers.attachTexture2d(target, .depth_stencil_attachment, ds.textarget, ds.texture, ds.level); fb.depth_stencil_attachment = ds.texture; }
            if (self._pending_renderbuffer) |r| {
                gl.framebuffers.attachRenderbuffer(target, r.attachment, r.renderbuffer);
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
            if (self._pending_draw_buffers) |bufs| {
                gl.framebuffers.drawBuffers(bufs);
                const n = @min(bufs.len, 16);
                @memcpy(fb.draw_buffers[0..n], bufs[0..n]);
                fb.draw_count = n;
            }
            if (self._pending_invalidate) |atts| gl.framebuffers.invalidate(target, atts);
            if (self._pending_invalidate_sub) |s| gl.framebuffers.invalidateSub(target, s.attachments, s.x, s.y, s.w, s.h);
            _ = self._pending_read_buffer;
            self.* = Editor.init(self._fb);
        }
    };
};
