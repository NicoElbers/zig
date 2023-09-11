/// Path is owned by Module and lives as long as *Module.
path: []const u8,
index: File.Index,

elf_local_symbols: std.ArrayListUnmanaged(elf.Elf64_Sym) = .{},
local_symbols: std.AutoArrayHashMapUnmanaged(Symbol.Index, void) = .{},

elf_global_symbols: std.ArrayListUnmanaged(elf.Elf64_Sym) = .{},
global_symbols: std.AutoArrayHashMapUnmanaged(Symbol.Index, void) = .{},

atoms: std.AutoArrayHashMapUnmanaged(Atom.Index, void) = .{},
relocs: std.ArrayListUnmanaged(std.ArrayListUnmanaged(elf.Elf64_Rela)) = .{},

output_symtab_size: Elf.SymtabSize = .{},

pub fn deinit(self: *ZigModule, allocator: Allocator) void {
    self.elf_local_symbols.deinit(allocator);
    self.local_symbols.deinit(allocator);
    self.elf_global_symbols.deinit(allocator);
    self.global_symbols.deinit(allocator);
    self.atoms.deinit(allocator);
    for (self.relocs.items) |*list| {
        list.deinit(allocator);
    }
    self.relocs.deinit(allocator);
}

pub fn createAtom(self: *ZigModule, output_section_index: u16, elf_file: *Elf) !Symbol.Index {
    const gpa = elf_file.base.allocator;
    const atom_index = try elf_file.addAtom();
    const symbol_index = try self.addLocal(elf_file);
    const atom_ptr = elf_file.atom(atom_index).?;
    atom_ptr.file_index = self.index;
    atom_ptr.output_section_index = output_section_index;
    const symbol_ptr = elf_file.symbol(symbol_index);
    symbol_ptr.atom_index = atom_index;
    symbol_ptr.output_section_index = output_section_index;
    const local_esym = self.sourceSymbol(symbol_ptr.index, elf_file);
    local_esym.st_shndx = output_section_index;
    const relocs_index = @as(Atom.Index, @intCast(self.relocs.items.len));
    const relocs = try self.relocs.addOne(gpa);
    relocs.* = .{};
    atom_ptr.relocs_section_index = relocs_index;
    try self.atoms.putNoClobber(gpa, atom_index, {});
    return symbol_index;
}

pub fn addLocal(self: *ZigModule, elf_file: *Elf) !Symbol.Index {
    const gpa = elf_file.base.allocator;
    const symbol_index = try elf_file.addSymbol();
    const symbol_ptr = elf_file.symbol(symbol_index);
    symbol_ptr.file_index = self.index;
    symbol_ptr.esym_index = @as(Symbol.Index, @intCast(self.elf_local_symbols.items.len));
    const local_esym = try self.elf_local_symbols.addOne(gpa);
    local_esym.* = Elf.null_sym;
    local_esym.st_info = elf.STB_LOCAL << 4;
    try self.local_symbols.putNoClobber(gpa, symbol_index, {});
    return symbol_index;
}

pub fn addGlobal(self: *ZigModule, name: []const u8, elf_file: *Elf) !Symbol.Index {
    const gpa = elf_file.base.allocator;
    try self.elf_global_symbols.ensureUnusedCapacity(gpa, 1);
    try self.global_symbols.ensureUnusedCapacity(gpa, 1);
    const off = try elf_file.strtab.insert(gpa, name);
    const esym_index = @as(Symbol.Index, @intCast(self.elf_global_symbols.items.len));
    const esym = self.elf_global_symbols.addOneAssumeCapacity();
    esym.* = Elf.null_sym;
    esym.st_name = off;
    esym.st_info = elf.STB_GLOBAL << 4;
    const gop = try elf_file.getOrPutGlobal(off);
    if (!gop.found_existing) {
        try elf_file.unresolved.putNoClobber(gpa, gop.index, {});
    }
    const sym = elf_file.symbol(gop.index);
    sym.file_index = self.index;
    sym.esym_index = esym_index;
    self.global_symbols.putAssumeCapacityNoClobber(gop.index, {});
    return gop.index;
}

pub fn updateSymtabSize(self: *ZigModule, elf_file: *Elf) void {
    for (self.locals()) |local_index| {
        const local = elf_file.symbol(local_index);
        const esym = local.sourceSymbol(elf_file);
        switch (esym.st_type()) {
            elf.STT_SECTION, elf.STT_NOTYPE => {
                local.flags.output_symtab = false;
                continue;
            },
            else => {},
        }
        local.flags.output_symtab = true;
        self.output_symtab_size.nlocals += 1;
    }

    for (self.globals()) |global_index| {
        const global = elf_file.symbol(global_index);
        if (global.file(elf_file)) |file| if (file.index() != self.index) {
            global.flags.output_symtab = false;
            continue;
        };
        global.flags.output_symtab = true;
        if (global.isLocal()) {
            self.output_symtab_size.nlocals += 1;
        } else {
            self.output_symtab_size.nglobals += 1;
        }
    }
}

pub fn writeSymtab(self: *ZigModule, elf_file: *Elf, ctx: anytype) void {
    var ilocal = ctx.ilocal;
    for (self.locals()) |local_index| {
        const local = elf_file.symbol(local_index);
        if (!local.flags.output_symtab) continue;
        local.setOutputSym(elf_file, &ctx.symtab[ilocal]);
        ilocal += 1;
    }

    var iglobal = ctx.iglobal;
    for (self.globals()) |global_index| {
        const global = elf_file.symbol(global_index);
        if (global.file(elf_file)) |file| if (file.index() != self.index) continue;
        if (!global.flags.output_symtab) continue;
        if (global.isLocal()) {
            global.setOutputSym(elf_file, &ctx.symtab[ilocal]);
            ilocal += 1;
        } else {
            global.setOutputSym(elf_file, &ctx.symtab[iglobal]);
            iglobal += 1;
        }
    }
}

pub fn sourceSymbol(self: *ZigModule, symbol_index: Symbol.Index, elf_file: *Elf) *elf.Elf64_Sym {
    const sym = elf_file.symbol(symbol_index);
    if (self.local_symbols.get(symbol_index)) |_| return &self.elf_local_symbols.items[sym.esym_index];
    assert(self.global_symbols.get(symbol_index) != null);
    return &self.elf_global_symbols.items[sym.esym_index];
}

pub fn locals(self: *ZigModule) []const Symbol.Index {
    return self.local_symbols.keys();
}

pub fn globals(self: *ZigModule) []const Symbol.Index {
    return self.global_symbols.keys();
}

pub fn asFile(self: *ZigModule) File {
    return .{ .zig_module = self };
}

pub fn fmtSymtab(self: *ZigModule, elf_file: *Elf) std.fmt.Formatter(formatSymtab) {
    return .{ .data = .{
        .self = self,
        .elf_file = elf_file,
    } };
}

const FormatContext = struct {
    self: *ZigModule,
    elf_file: *Elf,
};

fn formatSymtab(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    try writer.writeAll("  locals\n");
    for (ctx.self.locals()) |index| {
        const local = ctx.elf_file.symbol(index);
        try writer.print("    {}\n", .{local.fmt(ctx.elf_file)});
    }
    try writer.writeAll("  globals\n");
    for (ctx.self.globals()) |index| {
        const global = ctx.elf_file.symbol(index);
        try writer.print("    {}\n", .{global.fmt(ctx.elf_file)});
    }
}

pub fn fmtAtoms(self: *ZigModule, elf_file: *Elf) std.fmt.Formatter(formatAtoms) {
    return .{ .data = .{
        .self = self,
        .elf_file = elf_file,
    } };
}

fn formatAtoms(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    try writer.writeAll("  atoms\n");
    for (ctx.self.atoms.keys()) |atom_index| {
        const atom = ctx.elf_file.atom(atom_index) orelse continue;
        try writer.print("    {}\n", .{atom.fmt(ctx.elf_file)});
    }
}

const assert = std.debug.assert;
const std = @import("std");
const elf = std.elf;

const Allocator = std.mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("../Elf.zig");
const File = @import("file.zig").File;
const Module = @import("../../Module.zig");
const Symbol = @import("Symbol.zig");
const ZigModule = @This();
