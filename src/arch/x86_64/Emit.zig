//! This file contains the functionality for lowering x86_64 MIR into
//! machine code

const Emit = @This();

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("bits.zig");
const abi = @import("abi.zig");
const encoder = @import("encoder.zig");
const link = @import("../../link.zig");
const log = std.log.scoped(.codegen);
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const Air = @import("../../Air.zig");
const Allocator = mem.Allocator;
const CodeGen = @import("CodeGen.zig");
const DebugInfoOutput = @import("../../codegen.zig").DebugInfoOutput;
const Encoder = bits.Encoder;
const ErrorMsg = Module.ErrorMsg;
const Immediate = bits.Immediate;
const Instruction = encoder.Instruction;
const MCValue = @import("CodeGen.zig").MCValue;
const Memory = bits.Memory;
const Mir = @import("Mir.zig");
const Module = @import("../../Module.zig");
const Register = bits.Register;
const Type = @import("../../type.zig").Type;

mir: Mir,
bin_file: *link.File,
debug_output: DebugInfoOutput,
target: *const std.Target,
err_msg: ?*ErrorMsg = null,
src_loc: Module.SrcLoc,
code: *std.ArrayList(u8),

prev_di_line: u32,
prev_di_column: u32,
/// Relative to the beginning of `code`.
prev_di_pc: usize,

code_offset_mapping: std.AutoHashMapUnmanaged(Mir.Inst.Index, usize) = .{},
relocs: std.ArrayListUnmanaged(Reloc) = .{},

const InnerError = error{
    OutOfMemory,
    EmitFail,
    InvalidInstruction,
    CannotEncode,
};

const Reloc = struct {
    /// Offset of the instruction.
    source: usize,
    /// Target of the relocation.
    target: Mir.Inst.Index,
    /// Offset of the relocation within the instruction.
    offset: usize,
    /// Length of the instruction.
    length: u5,
};

pub fn lowerMir(emit: *Emit) InnerError!void {
    const mir_tags = emit.mir.instructions.items(.tag);

    for (mir_tags, 0..) |tag, index| {
        const inst = @intCast(u32, index);
        try emit.code_offset_mapping.putNoClobber(emit.bin_file.allocator, inst, emit.code.items.len);
        switch (tag) {
            .adc,
            .add,
            .@"and",
            .call,
            .cbw,
            .cwde,
            .cdqe,
            .cwd,
            .cdq,
            .cqo,
            .cmp,
            .div,
            .fisttp,
            .fld,
            .idiv,
            .imul,
            .int3,
            .jmp,
            .lea,
            .mov,
            .movzx,
            .mul,
            .nop,
            .@"or",
            .pop,
            .push,
            .ret,
            .sal,
            .sar,
            .sbb,
            .shl,
            .shr,
            .sub,
            .syscall,
            .@"test",
            .ud2,
            .xor,

            .addss,
            .cmpss,
            .movss,
            .ucomiss,
            .addsd,
            .cmpsd,
            .movsd,
            .ucomisd,
            => try emit.mirEncodeGeneric(tag, inst),

            .jmp_reloc => try emit.mirJmpReloc(inst),

            .mov_moffs => try emit.mirMovMoffs(inst),

            .movsx => try emit.mirMovsx(inst),
            .cmovcc => try emit.mirCmovcc(inst),
            .setcc => try emit.mirSetcc(inst),
            .jcc => try emit.mirJcc(inst),

            .dbg_line => try emit.mirDbgLine(inst),
            .dbg_prologue_end => try emit.mirDbgPrologueEnd(inst),
            .dbg_epilogue_begin => try emit.mirDbgEpilogueBegin(inst),

            .push_regs => try emit.mirPushPopRegisterList(.push, inst),
            .pop_regs => try emit.mirPushPopRegisterList(.pop, inst),
        }
    }

    try emit.fixupRelocs();
}

pub fn deinit(emit: *Emit) void {
    emit.relocs.deinit(emit.bin_file.allocator);
    emit.code_offset_mapping.deinit(emit.bin_file.allocator);
    emit.* = undefined;
}

fn fail(emit: *Emit, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(emit.err_msg == null);
    emit.err_msg = try ErrorMsg.create(emit.bin_file.allocator, emit.src_loc, format, args);
    return error.EmitFail;
}

fn fixupRelocs(emit: *Emit) InnerError!void {
    // TODO this function currently assumes all relocs via JMP/CALL instructions are 32bit in size.
    // This should be reversed like it is done in aarch64 MIR emit code: start with the smallest
    // possible resolution, i.e., 8bit, and iteratively converge on the minimum required resolution
    // until the entire decl is correctly emitted with all JMP/CALL instructions within range.
    for (emit.relocs.items) |reloc| {
        const target = emit.code_offset_mapping.get(reloc.target) orelse
            return emit.fail("JMP/CALL relocation target not found!", .{});
        const disp = @intCast(i32, @intCast(i64, target) - @intCast(i64, reloc.source + reloc.length));
        mem.writeIntLittle(i32, emit.code.items[reloc.offset..][0..4], disp);
    }
}

fn encode(emit: *Emit, mnemonic: Instruction.Mnemonic, ops: struct {
    op1: Instruction.Operand = .none,
    op2: Instruction.Operand = .none,
    op3: Instruction.Operand = .none,
    op4: Instruction.Operand = .none,
}) InnerError!void {
    const inst = Instruction.new(mnemonic, .{
        .op1 = ops.op1,
        .op2 = ops.op2,
        .op3 = ops.op3,
        .op4 = ops.op4,
    }) catch unreachable;
    return inst.encode(emit.code.writer());
}

fn mirEncodeGeneric(emit: *Emit, tag: Mir.Inst.Tag, inst: Mir.Inst.Index) InnerError!void {
    const mnemonic = inline for (@typeInfo(Instruction.Mnemonic).Enum.fields) |field| {
        if (mem.eql(u8, field.name, @tagName(tag))) break @field(Instruction.Mnemonic, field.name);
    } else unreachable;

    const ops = emit.mir.instructions.items(.ops)[inst];
    const data = emit.mir.instructions.items(.data)[inst];

    var operands = [4]Instruction.Operand{ .none, .none, .none, .none };
    switch (ops) {
        .none => {},
        .imm_s => operands[0] = .{ .imm = Immediate.s(data.imm_s) },
        .imm_u => operands[0] = .{ .imm = Immediate.u(data.imm_u) },
        .r => operands[0] = .{ .reg = data.r },
        .rr => operands[0..2].* = .{
            .{ .reg = data.rr.r1 },
            .{ .reg = data.rr.r2 },
        },
        .ri_s => operands[0..2].* = .{
            .{ .reg = data.ri_s.r1 },
            .{ .imm = Immediate.s(data.ri_s.imm) },
        },
        .ri_u => operands[0..2].* = .{
            .{ .reg = data.ri_u.r1 },
            .{ .imm = Immediate.u(data.ri_u.imm) },
        },
        .ri64 => {
            const imm64 = emit.mir.extraData(Mir.Imm64, data.rx.payload).data;
            operands[0..2].* = .{
                .{ .reg = data.rx.r1 },
                .{ .imm = Immediate.u(Mir.Imm64.decode(imm64)) },
            };
        },
        .m_sib => {
            const msib = emit.mir.extraData(Mir.MemorySib, data.payload).data;
            operands[0] = .{ .mem = Mir.MemorySib.decode(msib) };
        },
        .m_rip => {
            const mrip = emit.mir.extraData(Mir.MemoryRip, data.payload).data;
            operands[0] = .{ .mem = Mir.MemoryRip.decode(mrip) };
        },
        .mi_u_sib => {
            const msib = emit.mir.extraData(Mir.MemorySib, data.xi_u.payload).data;
            operands[0..2].* = .{
                .{ .mem = Mir.MemorySib.decode(msib) },
                .{ .imm = Immediate.u(data.xi_u.imm) },
            };
        },
        .mi_s_sib => {
            const msib = emit.mir.extraData(Mir.MemorySib, data.xi_s.payload).data;
            operands[0..2].* = .{
                .{ .mem = Mir.MemorySib.decode(msib) },
                .{ .imm = Immediate.s(data.xi_s.imm) },
            };
        },
        .mi_u_rip => {
            const mrip = emit.mir.extraData(Mir.MemoryRip, data.xi_u.payload).data;
            operands[0..2].* = .{
                .{ .mem = Mir.MemoryRip.decode(mrip) },
                .{ .imm = Immediate.u(data.xi_u.imm) },
            };
        },
        .mi_s_rip => {
            const mrip = emit.mir.extraData(Mir.MemoryRip, data.xi_s.payload).data;
            operands[0..2].* = .{
                .{ .mem = Mir.MemoryRip.decode(mrip) },
                .{ .imm = Immediate.s(data.xi_s.imm) },
            };
        },
        .rm_sib, .mr_sib => {
            const msib = emit.mir.extraData(Mir.MemorySib, data.rx.payload).data;
            const op1 = .{ .reg = data.rx.r1 };
            const op2 = .{ .mem = Mir.MemorySib.decode(msib) };
            switch (ops) {
                .rm_sib => operands[0..2].* = .{ op1, op2 },
                .mr_sib => operands[0..2].* = .{ op2, op1 },
                else => unreachable,
            }
        },
        .rm_rip, .mr_rip => {
            const mrip = emit.mir.extraData(Mir.MemoryRip, data.rx.payload).data;
            const op1 = .{ .reg = data.rx.r1 };
            const op2 = .{ .mem = Mir.MemoryRip.decode(mrip) };
            switch (ops) {
                .rm_rip => operands[0..2].* = .{ op1, op2 },
                .mr_rip => operands[0..2].* = .{ op2, op1 },
                else => unreachable,
            }
        },
        else => unreachable, // TODO
    }

    return emit.encode(mnemonic, .{
        .op1 = operands[0],
        .op2 = operands[1],
        .op3 = operands[2],
        .op4 = operands[3],
    });
}

fn mirMovMoffs(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const ops = emit.mir.instructions.items(.ops)[inst];
    const payload = emit.mir.instructions.items(.data)[inst].payload;
    const moffs = emit.mir.extraData(Mir.MemoryMoffs, payload).data;
    const seg = @intToEnum(Register, moffs.seg);
    const offset = moffs.decodeOffset();
    switch (ops) {
        .rax_moffs => {
            try emit.encode(.mov, .{
                .op1 = .{ .reg = .rax },
                .op2 = .{ .mem = Memory.moffs(seg, offset) },
            });
        },
        .moffs_rax => {
            try emit.encode(.mov, .{
                .op1 = .{ .mem = Memory.moffs(seg, offset) },
                .op2 = .{ .reg = .rax },
            });
        },
        else => unreachable,
    }
}

fn mirMovsx(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const ops = emit.mir.instructions.items(.ops)[inst];
    const data = emit.mir.instructions.items(.data)[inst];

    var op1: Instruction.Operand = .none;
    var op2: Instruction.Operand = .none;
    switch (ops) {
        .rr => {
            op1 = .{ .reg = data.rr.r1 };
            op2 = .{ .reg = data.rr.r2 };
        },
        else => unreachable, // TODO
    }

    const mnemonic: Instruction.Mnemonic = if (op1.bitSize() == 64 and op2.bitSize() == 32) .movsxd else .movsx;

    return emit.encode(mnemonic, .{
        .op1 = op1,
        .op2 = op2,
    });
}

fn mnemonicFromConditionCode(comptime basename: []const u8, cc: bits.Condition) Instruction.Mnemonic {
    inline for (@typeInfo(bits.Condition).Enum.fields) |field| {
        if (mem.eql(u8, field.name, @tagName(cc)))
            return @field(Instruction.Mnemonic, basename ++ field.name);
    } else unreachable;
}

fn mirCmovcc(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const ops = emit.mir.instructions.items(.ops)[inst];
    switch (ops) {
        .rr_c => {
            const data = emit.mir.instructions.items(.data)[inst].rr_c;
            const mnemonic = mnemonicFromConditionCode("cmov", data.cc);
            return emit.encode(mnemonic, .{
                .op1 = .{ .reg = data.r1 },
                .op2 = .{ .reg = data.r2 },
            });
        },
        else => unreachable, // TODO
    }
}

fn mirSetcc(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const ops = emit.mir.instructions.items(.ops)[inst];
    switch (ops) {
        .r_c => {
            const data = emit.mir.instructions.items(.data)[inst].r_c;
            const mnemonic = mnemonicFromConditionCode("set", data.cc);
            return emit.encode(mnemonic, .{
                .op1 = .{ .reg = data.r1 },
            });
        },
        else => unreachable, // TODO
    }
}

fn mirJcc(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const ops = emit.mir.instructions.items(.ops)[inst];
    switch (ops) {
        .inst_cc => {
            const data = emit.mir.instructions.items(.data)[inst].inst_cc;
            const mnemonic = mnemonicFromConditionCode("j", data.cc);
            const source = emit.code.items.len;
            try emit.encode(mnemonic, .{
                .op1 = .{ .imm = Immediate.s(0) },
            });
            try emit.relocs.append(emit.bin_file.allocator, .{
                .source = source,
                .target = data.inst,
                .offset = emit.code.items.len - 4,
                .length = 6,
            });
        },
        else => unreachable, // TODO
    }
}

fn mirJmpReloc(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const ops = emit.mir.instructions.items(.ops)[inst];
    switch (ops) {
        .inst => {
            const target = emit.mir.instructions.items(.data)[inst].inst;
            const source = emit.code.items.len;
            try emit.encode(.jmp, .{
                .op1 = .{ .imm = Immediate.s(0) },
            });
            try emit.relocs.append(emit.bin_file.allocator, .{
                .source = source,
                .target = target,
                .offset = emit.code.items.len - 4,
                .length = 5,
            });
        },
        else => unreachable,
    }
}

// fn mirCallExtern(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
//     const tag = emit.mir.instructions.items(.tag)[inst];
//     assert(tag == .call_extern);
//     const relocation = emit.mir.instructions.items(.data)[inst].relocation;

//     const offset = blk: {
//         // callq
//         try emit.encode(.call, .{
//             .op1 = .{ .imm = Immediate.s(0) },
//         });
//         break :blk @intCast(u32, emit.code.items.len) - 4;
//     };

//     if (emit.bin_file.cast(link.File.MachO)) |macho_file| {
//         // Add relocation to the decl.
//         const atom_index = macho_file.getAtomIndexForSymbol(.{ .sym_index = relocation.atom_index, .file = null }).?;
//         const target = macho_file.getGlobalByIndex(relocation.sym_index);
//         try link.File.MachO.Atom.addRelocation(macho_file, atom_index, .{
//             .type = @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH),
//             .target = target,
//             .offset = offset,
//             .addend = 0,
//             .pcrel = true,
//             .length = 2,
//         });
//     } else if (emit.bin_file.cast(link.File.Coff)) |coff_file| {
//         // Add relocation to the decl.
//         const atom_index = coff_file.getAtomIndexForSymbol(.{ .sym_index = relocation.atom_index, .file = null }).?;
//         const target = coff_file.getGlobalByIndex(relocation.sym_index);
//         try link.File.Coff.Atom.addRelocation(coff_file, atom_index, .{
//             .type = .direct,
//             .target = target,
//             .offset = offset,
//             .addend = 0,
//             .pcrel = true,
//             .length = 2,
//         });
//     } else {
//         return emit.fail("TODO implement call_extern for linking backends different than MachO and COFF", .{});
//     }
// }

fn mirPushPopRegisterList(emit: *Emit, tag: Mir.Inst.Tag, inst: Mir.Inst.Index) InnerError!void {
    const payload = emit.mir.instructions.items(.data)[inst].payload;
    const save_reg_list = emit.mir.extraData(Mir.SaveRegisterList, payload).data;
    const base = @intToEnum(Register, save_reg_list.base_reg);
    var disp: i32 = -@intCast(i32, save_reg_list.stack_end);
    const reg_list = Mir.RegisterList.fromInt(save_reg_list.register_list);
    const callee_preserved_regs = abi.getCalleePreservedRegs(emit.target.*);
    for (callee_preserved_regs) |reg| {
        if (reg_list.isSet(callee_preserved_regs, reg)) {
            const op1: Instruction.Operand = .{ .mem = Memory.sib(.qword, .{
                .base = base,
                .disp = disp,
            }) };
            const op2: Instruction.Operand = .{ .reg = reg };
            switch (tag) {
                .push => try emit.encode(.mov, .{
                    .op1 = op1,
                    .op2 = op2,
                }),
                .pop => try emit.encode(.mov, .{
                    .op1 = op2,
                    .op2 = op1,
                }),
                else => unreachable,
            }
            disp += 8;
        }
    }
}

// fn mirJmpCall(emit: *Emit, mnemonic: Instruction.Mnemonic, inst: Mir.Inst.Index) InnerError!void {
//     const ops = emit.mir.instructions.items(.ops)[inst].decode();
//     switch (ops.flags) {
//         0b00 => {
//             const target = emit.mir.instructions.items(.data)[inst].inst;
//             const source = emit.code.items.len;
//             try emit.encode(mnemonic, .{
//                 .op1 = .{ .imm = Immediate.s(0) },
//             });
//             try emit.relocs.append(emit.bin_file.allocator, .{
//                 .source = source,
//                 .target = target,
//                 .offset = emit.code.items.len - 4,
//                 .length = 5,
//             });
//         },
//         0b01 => {
//             if (ops.reg1 == .none) {
//                 const disp = emit.mir.instructions.items(.data)[inst].disp;
//                 return emit.encode(mnemonic, .{
//                     .op1 = .{ .mem = Memory.sib(.qword, .{ .disp = disp }) },
//                 });
//             }
//             return emit.encode(mnemonic, .{
//                 .op1 = .{ .reg = ops.reg1 },
//             });
//         },
//         0b10 => {
//             const disp = emit.mir.instructions.items(.data)[inst].disp;
//             return emit.encode(mnemonic, .{
//                 .op1 = .{ .mem = Memory.sib(.qword, .{
//                     .base = ops.reg1,
//                     .disp = disp,
//                 }) },
//             });
//         },
//         0b11 => return emit.fail("TODO unused variant jmp/call 0b11", .{}),
//     }
// }

// fn mirLea(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
//     const tag = emit.mir.instructions.items(.tag)[inst];
//     assert(tag == .lea);
//     const ops = emit.mir.instructions.items(.ops)[inst].decode();
//     switch (ops.flags) {
//         0b00 => {
//             const disp = emit.mir.instructions.items(.data)[inst].disp;
//             const src_reg: ?Register = if (ops.reg2 != .none) ops.reg2 else null;
//             return emit.encode(.lea, .{
//                 .op1 = .{ .reg = ops.reg1 },
//                 .op2 = .{ .mem = Memory.sib(Memory.PtrSize.fromBitSize(ops.reg1.bitSize()), .{
//                     .base = src_reg,
//                     .disp = disp,
//                 }) },
//             });
//         },
//         0b01 => {
//             const start_offset = emit.code.items.len;
//             try emit.encode(.lea, .{
//                 .op1 = .{ .reg = ops.reg1 },
//                 .op2 = .{ .mem = Memory.rip(Memory.PtrSize.fromBitSize(ops.reg1.bitSize()), 0) },
//             });
//             const end_offset = emit.code.items.len;
//             // Backpatch the displacement
//             const payload = emit.mir.instructions.items(.data)[inst].payload;
//             const imm = emit.mir.extraData(Mir.Imm64, payload).data.decode();
//             const disp = @intCast(i32, @intCast(i64, imm) - @intCast(i64, end_offset - start_offset));
//             mem.writeIntLittle(i32, emit.code.items[end_offset - 4 ..][0..4], disp);
//         },
//         0b10 => {
//             const payload = emit.mir.instructions.items(.data)[inst].payload;
//             const index_reg_disp = emit.mir.extraData(Mir.IndexRegisterDisp, payload).data.decode();
//             const src_reg: ?Register = if (ops.reg2 != .none) ops.reg2 else null;
//             const scale_index = Memory.ScaleIndex{
//                 .scale = 1,
//                 .index = index_reg_disp.index,
//             };
//             return emit.encode(.lea, .{
//                 .op1 = .{ .reg = ops.reg1 },
//                 .op2 = .{ .mem = Memory.sib(Memory.PtrSize.fromBitSize(ops.reg1.bitSize()), .{
//                     .base = src_reg,
//                     .scale_index = scale_index,
//                     .disp = index_reg_disp.disp,
//                 }) },
//             });
//         },
//         0b11 => return emit.fail("TODO unused LEA variant 0b11", .{}),
//     }
// }

// fn mirLeaPic(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
//     const tag = emit.mir.instructions.items(.tag)[inst];
//     assert(tag == .lea_pic);
//     const ops = emit.mir.instructions.items(.ops)[inst].decode();
//     const relocation = emit.mir.instructions.items(.data)[inst].relocation;

//     switch (ops.flags) {
//         0b00, 0b01, 0b10 => {},
//         else => return emit.fail("TODO unused LEA PIC variant 0b11", .{}),
//     }

//     try emit.encode(.lea, .{
//         .op1 = .{ .reg = ops.reg1 },
//         .op2 = .{ .mem = Memory.rip(Memory.PtrSize.fromBitSize(ops.reg1.bitSize()), 0) },
//     });

//     const end_offset = emit.code.items.len;

//     if (emit.bin_file.cast(link.File.MachO)) |macho_file| {
//         const reloc_type = switch (ops.flags) {
//             0b00 => @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_GOT),
//             0b01 => @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_SIGNED),
//             else => unreachable,
//         };
//         const atom_index = macho_file.getAtomIndexForSymbol(.{ .sym_index = relocation.atom_index, .file = null }).?;
//         try link.File.MachO.Atom.addRelocation(macho_file, atom_index, .{
//             .type = reloc_type,
//             .target = .{ .sym_index = relocation.sym_index, .file = null },
//             .offset = @intCast(u32, end_offset - 4),
//             .addend = 0,
//             .pcrel = true,
//             .length = 2,
//         });
//     } else if (emit.bin_file.cast(link.File.Coff)) |coff_file| {
//         const atom_index = coff_file.getAtomIndexForSymbol(.{ .sym_index = relocation.atom_index, .file = null }).?;
//         try link.File.Coff.Atom.addRelocation(coff_file, atom_index, .{
//             .type = switch (ops.flags) {
//                 0b00 => .got,
//                 0b01 => .direct,
//                 0b10 => .import,
//                 else => unreachable,
//             },
//             .target = switch (ops.flags) {
//                 0b00, 0b01 => .{ .sym_index = relocation.sym_index, .file = null },
//                 0b10 => coff_file.getGlobalByIndex(relocation.sym_index),
//                 else => unreachable,
//             },
//             .offset = @intCast(u32, end_offset - 4),
//             .addend = 0,
//             .pcrel = true,
//             .length = 2,
//         });
//     } else {
//         return emit.fail("TODO implement lea reg, [rip + reloc] for linking backends different than MachO", .{});
//     }
// }

// fn mirCallExtern(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
//     const tag = emit.mir.instructions.items(.tag)[inst];
//     assert(tag == .call_extern);
//     const relocation = emit.mir.instructions.items(.data)[inst].relocation;

//     const offset = blk: {
//         // callq
//         try emit.encode(.call, .{
//             .op1 = .{ .imm = Immediate.s(0) },
//         });
//         break :blk @intCast(u32, emit.code.items.len) - 4;
//     };

//     if (emit.bin_file.cast(link.File.MachO)) |macho_file| {
//         // Add relocation to the decl.
//         const atom_index = macho_file.getAtomIndexForSymbol(.{ .sym_index = relocation.atom_index, .file = null }).?;
//         const target = macho_file.getGlobalByIndex(relocation.sym_index);
//         try link.File.MachO.Atom.addRelocation(macho_file, atom_index, .{
//             .type = @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH),
//             .target = target,
//             .offset = offset,
//             .addend = 0,
//             .pcrel = true,
//             .length = 2,
//         });
//     } else if (emit.bin_file.cast(link.File.Coff)) |coff_file| {
//         // Add relocation to the decl.
//         const atom_index = coff_file.getAtomIndexForSymbol(.{ .sym_index = relocation.atom_index, .file = null }).?;
//         const target = coff_file.getGlobalByIndex(relocation.sym_index);
//         try link.File.Coff.Atom.addRelocation(coff_file, atom_index, .{
//             .type = .direct,
//             .target = target,
//             .offset = offset,
//             .addend = 0,
//             .pcrel = true,
//             .length = 2,
//         });
//     } else {
//         return emit.fail("TODO implement call_extern for linking backends different than MachO and COFF", .{});
//     }
// }

fn mirDbgLine(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const payload = emit.mir.instructions.items(.data)[inst].payload;
    const dbg_line_column = emit.mir.extraData(Mir.DbgLineColumn, payload).data;
    log.debug("mirDbgLine", .{});
    try emit.dbgAdvancePCAndLine(dbg_line_column.line, dbg_line_column.column);
}

fn dbgAdvancePCAndLine(emit: *Emit, line: u32, column: u32) InnerError!void {
    const delta_line = @intCast(i32, line) - @intCast(i32, emit.prev_di_line);
    const delta_pc: usize = emit.code.items.len - emit.prev_di_pc;
    log.debug("  (advance pc={d} and line={d})", .{ delta_line, delta_pc });
    switch (emit.debug_output) {
        .dwarf => |dw| {
            try dw.advancePCAndLine(delta_line, delta_pc);
            emit.prev_di_line = line;
            emit.prev_di_column = column;
            emit.prev_di_pc = emit.code.items.len;
        },
        .plan9 => |dbg_out| {
            if (delta_pc <= 0) return; // only do this when the pc changes
            // we have already checked the target in the linker to make sure it is compatable
            const quant = @import("../../link/Plan9/aout.zig").getPCQuant(emit.target.cpu.arch) catch unreachable;

            // increasing the line number
            try @import("../../link/Plan9.zig").changeLine(dbg_out.dbg_line, delta_line);
            // increasing the pc
            const d_pc_p9 = @intCast(i64, delta_pc) - quant;
            if (d_pc_p9 > 0) {
                // minus one because if its the last one, we want to leave space to change the line which is one quanta
                var diff = @divExact(d_pc_p9, quant) - quant;
                while (diff > 0) {
                    if (diff < 64) {
                        try dbg_out.dbg_line.append(@intCast(u8, diff + 128));
                        diff = 0;
                    } else {
                        try dbg_out.dbg_line.append(@intCast(u8, 64 + 128));
                        diff -= 64;
                    }
                }
                if (dbg_out.pcop_change_index.*) |pci|
                    dbg_out.dbg_line.items[pci] += 1;
                dbg_out.pcop_change_index.* = @intCast(u32, dbg_out.dbg_line.items.len - 1);
            } else if (d_pc_p9 == 0) {
                // we don't need to do anything, because adding the quant does it for us
            } else unreachable;
            if (dbg_out.start_line.* == null)
                dbg_out.start_line.* = emit.prev_di_line;
            dbg_out.end_line.* = line;
            // only do this if the pc changed
            emit.prev_di_line = line;
            emit.prev_di_column = column;
            emit.prev_di_pc = emit.code.items.len;
        },
        .none => {},
    }
}

fn mirDbgPrologueEnd(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    _ = inst;
    switch (emit.debug_output) {
        .dwarf => |dw| {
            try dw.setPrologueEnd();
            log.debug("mirDbgPrologueEnd (line={d}, col={d})", .{
                emit.prev_di_line,
                emit.prev_di_column,
            });
            try emit.dbgAdvancePCAndLine(emit.prev_di_line, emit.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirDbgEpilogueBegin(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    _ = inst;
    switch (emit.debug_output) {
        .dwarf => |dw| {
            try dw.setEpilogueBegin();
            log.debug("mirDbgEpilogueBegin (line={d}, col={d})", .{
                emit.prev_di_line,
                emit.prev_di_column,
            });
            try emit.dbgAdvancePCAndLine(emit.prev_di_line, emit.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}
