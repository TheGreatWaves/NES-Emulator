const cpu = @import("cpu.zig");
const ram = @import("ram.zig");
pub const std = @import("std");
pub const BusError = error{InvalidMake};

// The bus holds the whole system. It is nothing more than a series of components connected.
pub const Bus = struct {

    // Devices on the bus.
    cpu: cpu.Cpu,
    ram: ram.Ram,

    // Create the bus and initialize all the components on it.
    pub fn make() BusError!Bus {
        var bus = Bus{ .cpu = cpu.Cpu.make(), .ram = ram.Ram.make() };
        bus.cpu.connectBus(&bus) catch return BusError.InvalidMake;
        return bus;
    }

    // Write data to the address.
    pub fn write(this: *Bus, addr: u16, data: u8) void {
        this.ram.mem[addr] = data;
    }

    // Read data at address.
    pub fn read(this: *Bus, addr: u16) BusError!u8 {
        return this.ram.mem[addr];
    }
};

test "CPU failed to connect to bus." {
    var bus = Bus{ .cpu = cpu.Cpu.make(), .ram = ram.Ram.make() };
    try bus.cpu.connectBus(&bus);
    try std.testing.expect(&bus == bus.cpu.bus.?);
}
