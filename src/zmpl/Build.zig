const std = @import("std");
const zmpl = @import("../zmpl.zig");

build: *std.Build,
step: *std.Build.Step.Compile,
manifest_path: []const u8,
templates_path: []const u8,

const Self = @This();

const TemplateDef = struct {
    path: []const u8,
    relpath: []const u8,
    name: []const u8,
};

pub fn init(
    build: *std.Build,
    step: *std.Build.Step.Compile,
    manifest_path: []const u8,
    templates_path: []const u8,
) Self {
    return .{
        .build = build,
        .step = step,
        .manifest_path = manifest_path,
        .templates_path = templates_path,
    };
}

pub fn compile(self: *Self) !void {
    var templates = std.ArrayList(TemplateDef).init(self.build.allocator);

    self.compileTemplates(&templates) catch |err| {
        switch (err) {
            error.TemplateDirectoryNotFound => {
                std.debug.print(
                    "[zmpl] Template directory `{s}` not found, skipping rendering.\n",
                    .{self.templates_path},
                );
                return;
            },
            else => return err,
        }
    };

    var dir = std.fs.cwd();
    var file = try dir.createFile(self.manifest_path, .{ .truncate = true });
    try file.writeAll("pub const templates = struct {\n");
    for (templates.items) |template| {
        const module = self.build.createModule(.{ .source_file = .{ .path = template.path } });
        self.step.addModule(template.name, module);
        try file.writeAll(try std.fmt.allocPrint(
            self.build.allocator,
            "  pub const {s} = @import(\"{s}\");\n",
            .{ template.name, template.relpath },
        ));
    }
    try file.writeAll("};\n");
    file.close();
}

fn compileTemplates(self: *Self, array: *std.ArrayList(TemplateDef)) !void {
    const paths = try self.findTemplates();
    const dir = try std.fs.cwd().openDir(self.templates_path, .{});
    for (paths.items) |path| {
        const output_path = try std.fs.path.join(
            self.build.allocator,
            &[_][]const u8{
                std.fs.path.dirname(path) orelse "",
                try std.mem.concat(self.build.allocator, u8, &[_][]const u8{
                    ".",
                    std.fs.path.basename(path),
                    ".compiled.zig",
                }),
            },
        );
        var file = try dir.openFile(path, .{});
        const size = (try file.stat()).size;
        const buffer = try self.build.allocator.alloc(u8, size);
        const content = try dir.readFile(path, buffer);
        var template = zmpl.Template.init(self.build.allocator, path, content);
        const output = try template.compile();

        const output_file = try dir.createFile(output_path, .{ .truncate = true });
        try output_file.writeAll(output);
        output_file.close();
        try array.append(.{
            .path = try dir.realpathAlloc(self.build.allocator, output_path),
            .relpath = output_path,
            .name = try template.identifier(),
        });

        std.debug.print("[zmpl] Compiled template: {s}\n", .{path});
    }
}

fn findTemplates(self: *Self) !std.ArrayList([]const u8) {
    var array = std.ArrayList([]const u8).init(self.build.allocator);
    const dir = std.fs.cwd().openIterableDir(self.templates_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return error.TemplateDirectoryNotFound,
            else => return err,
        }
    };

    var walker = try dir.walk(self.build.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const extension = std.fs.path.extension(entry.path);
        const basename = std.fs.path.basename(entry.path);
        if (std.mem.eql(u8, basename, "manifest.zig")) continue;
        if (std.mem.startsWith(u8, basename, ".")) continue;
        if (!std.mem.eql(u8, extension, ".zmpl")) continue;
        try array.append(try self.build.allocator.dupe(u8, entry.path));
    }
    return array;
}
