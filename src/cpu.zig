pub const std = @import("std");
pub const CpuError = error{ Unknown, InvalidRead, InvalidWrite };
pub const bus = @import("bus.zig");
pub const ram = @import("ram.zig");
pub const instr = @import("instr.zig");

const PC_START = 0;

fn shiftRight(n: u8) u8 {
    return (1 << n);
}

// CPU Flags
const CPU_F = enum(u8) {
    C = shiftRight(0), // Carry flag.
    Z = shiftRight(1), // Zero flag.
    I = shiftRight(2), // Interrupt Disable flag.
    D = shiftRight(3), // Decimal flag. (Unused)
    V = shiftRight(4), // Overflow flag.
    N = shiftRight(5), // Negative flag.
    B = shiftRight(6), // Bit branches.
    U = shiftRight(7), // Unused/Unknown flag.
};

// 6502 class.
pub const Cpu = struct {

    // Core registers
    a: u8 = 0, // Accumulator register
    x: u8 = 0, // Index register X
    y: u8 = 0, // Index register Y
    sp: u8 = 0, // Stack pointer
    pc: u16 = PC_START, // Program counter
    status: u8 = 0, // Status register

    cycles: u8 = 0, // The number of cycles the current instruction requires until completion
    fetched: u8 = 0, // The fetched operand

    addr_abs: u16 = 0x0, // Address to fetch data from
    addr_rel: u16 = 0x0, // Relative address to jump to (branch)
    opcode: u8 = 0, // The opcode of the current instruction

    bus: ?*bus.Bus = null, // Communication bus

    pub fn make() Cpu {
        return Cpu{};
    }

    // The data to be fetched can only be retrieved from two sources. It can either come from
    // some memory address, or it can be retrieved directly from the instruction itself.
    pub fn fetch(this: *Cpu) void {
        // TODO! Check the current instruction's addressing mode. If it isn't `implied` then we have to read.
        // Otherwise we can just return what has already been fetched, which should've been handled by the
        // `implied_address_mode` function.
        _ = this;
    }

    pub fn connectBus(this: *Cpu, _bus: ?*bus.Bus) CpuError!void {
        if (_bus) |b| {
            this.bus = b;
        } else {
            return CpuError.Unknown;
        }
    }

    // Write data to the address.
    pub fn write(this: *Cpu, addr: u16, data: u8) CpuError!void {
        if (this.bus) |b| {
            return b.write(addr, data);
        } else {
            return CpuError.InvalidWrite;
        }
    }

    // Read data at address. (byte)
    pub fn read(this: *Cpu, addr: u16) CpuError!u8 {
        if (this.bus) |b| {
            return b.read(addr);
        } else {
            return CpuError.InvalidRead;
        }
    }

    pub fn clock(this: *Cpu) void {
        if (this.cycles == 0) {
            this.opcode = this.read(this.pc);
            this.pc += 1;

            // Now reset the number of cycles to the number required by the instruction.
            this.cycles = LOOK_UP[this.opcode].cycles;
            var additional_cycles = LOOK_UP[this.opcode].operation(this);

            this.cycles += additional_cycles;
        }

        this.cycles -= 1;
    }

    //////////////////////////////////////////////////////////////////////////////
    // Addressing Modes
    //
    // Note & Remarks:
    // The 16-bit address space available to the 6502 is thought to be 256 `pages`
    // of 256 memory locations. The high order byte tells us the page number and
    // the low order byte tells us the location inside the specified page.

    // Address Mode - Implied
    // There is no additional data required. The accumulator needs to be fetched
    // in order to account for instructions which will implicitly require it.
    pub fn implied_address_mode(this: *Cpu) u8 {
        this.fetched = this.a;
        return 0;
    }

    // Address Mode - Immediate
    // The required data is taken from the byte following the opcode.
    pub fn immediate_address_mode(this: *Cpu) u8 {
        this.addr_abs = this.pc;
        this.pc += 1;
        return 0;
    }

    // Address Mode - Absolute
    // The address we want to locate the data from can be constructed by
    // combining the second and third byte of the instruction. The second
    // byte of the instruction specifies the 8 low order bits, the third
    // byte specifies the 8 high order bits.
    pub fn absolute_address_mode(this: *Cpu) u8 {
        var lo = this.read(this.pc);
        this.pc += 1;
        var hi = this.read(this.pc);
        this.pc += 1;
        this.addr_abs = (hi << 8) | lo;
        return 0;
    }

    // Address Mode - Zero page X
    // Similar to absolute address mode, the only difference is that this
    // requires the register content of X to be added as an offset.
    pub fn absolute_x_address_mode(this: *Cpu) u8 {
        var lo = this.read(this.pc);
        this.pc += 1;
        var hi = this.read(this.pc);
        this.pc += 1;
        var x_offset = this.x;
        this.addr_abs = ((hi << 8) | lo) + x_offset;

        // Stepped out of page.
        // Crossing the page boundary means that the high order byte
        // needs to be incremented and this takes an additional cycle.
        if ((this.addr_abs & 0xFF00) != (hi << 8)) {
            return 1;
        } else {
            return 0;
        }
    }

    // Address Mode - Zero page Y
    // Similar to absolute address mode, the only difference is that this
    // requires the register content of y to be added as an offset.
    pub fn absolute_y_address_mode(this: *Cpu) u8 {
        var lo = this.read(this.pc);
        this.pc += 1;
        var hi = this.read(this.pc);
        this.pc += 1;
        var y_offset = this.y;
        this.addr_abs = ((hi << 8) | lo) + y_offset;

        // Stepped out of page.
        // Crossing the page boundary means that the high order byte
        // needs to be incremented and this takes an additional cycle.
        if ((this.addr_abs & 0xFF00) != (hi << 8)) {
            return 1;
        } else {
            return 0;
        }
    }

    // Address Mode - Accumulator
    pub fn accumulator_address_mode(this: *Cpu) u8 {
        this.fetch = this.a;
        return 0;
    }

    // Address Mode - Zero page
    // This assumes that the high-byte is 0, we only need to read the second
    // byte and grab the low 8 order bits. This is very similar to the absolute
    // address mode, but since it only requires one less byte to fetch this
    // takes one cycle less to execute.
    pub fn zero_page_address_mode(this: *Cpu) u8 {
        this.addr_rel = read(this.pc) & 0x00FF;
        this.pc += 1;
        return 0;
    }

    // Address Mode - Zero page X
    // This is basically equivalent to the zero page address mode. The only
    // difference is that we add the content of register X as an offset.
    // Since this is zero page, the high order byte will always be 0, even
    // if we were to increment, we would simply wrap around. This means that
    // we will never have to worry about crossing any page boundary.
    pub fn zero_page_x_address_mode(this: *Cpu) u8 {
        this.addr_rel = (read(this.pc) + this.x) & 0x00FF;
        this.pc += 1;
        return 0;
    }

    // Address Mode - Zero page Y
    // Equivalent to zero page X, but uses Y register instead. Notably, this
    // is less used than the X alternative.
    pub fn zero_page_y_address_mode(this: *Cpu) u8 {
        this.addr_rel = (read(this.pc) + this.y) & 0x00FF;
        this.pc += 1;
        return 0;
    }

    //////////////////////////////////////////////////////////////////////////////
    // Instuctions

    fn ADC(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn AND(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn ANS(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BCC(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BCS(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn BEQ(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BIT(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BMI(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BNE(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BPL(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn BRK(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn BVC(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn BVS(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn CLC(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn CLD(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn CLI(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn CLV(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn CMP(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn CPX(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn CPY(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn DEC(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn DEX(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn DEY(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn EOR(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn INC(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn INX(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn INY(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn JMP(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn JSR(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
    fn LDA(this: *Cpu) u8 {
        _ = this;
        return 0;
    }

    fn NOP(this: *Cpu) u8 {
        _ = this;
        return 0;
    }
};

const LOOK_UP = [_]instr.Instruction{
    instr.Instruction{ .name = "BRK", .operation = Cpu.BRK, .cycles = 7 },
};

test "CPU can read, but hub not connected." {
    var _bus = bus.Bus{ .cpu = Cpu.make(), .ram = ram.Ram.make() };
    try std.testing.expectError(CpuError.InvalidRead, _bus.cpu.read(0xFFFF));
}

test "CPU can write, but hub not connected." {
    var _bus = bus.Bus{ .cpu = Cpu.make(), .ram = ram.Ram.make() };
    try std.testing.expectError(CpuError.InvalidWrite, _bus.cpu.write(0xFFFF, 0xab));
}
