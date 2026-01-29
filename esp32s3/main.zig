// Minimal bare-metal Zig for ESP32-S3
// No std lib, no imports

const GPIO_BASE: u32 = 0x6000_4000;

const GPIO_OUT_REG = GPIO_BASE + 0x0004;
const GPIO_ENABLE_REG = GPIO_BASE + 0x0020;

// ────────────────────────────────────────────────
fn write_reg32(addr: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

fn read_reg32(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

// Very naive busy-wait delay (depends on CPU frequency)
fn simple_delay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {}
}

// ────────────────────────────────────────────────
export fn app_main() callconv(.c) void {
    const led_pin = 48;

    // Enable GPIO48 as output
    const current_enable = read_reg32(GPIO_ENABLE_REG);
    write_reg32(GPIO_ENABLE_REG, current_enable | (1 << @as(u5, @intCast(led_pin & 0x1F))));

    var counter: u32 = 0;

    while (true) {
        // LED ON
        const current_out = read_reg32(GPIO_OUT_REG);
        write_reg32(GPIO_OUT_REG, current_out | (1 << @as(u5, @intCast(led_pin & 0x1F))));

        simple_delay(1_200_000);

        // LED OFF
        write_reg32(GPIO_OUT_REG, current_out & ~(@as(u32, 1) << @as(u5, @intCast(led_pin & 0x1F))));

        simple_delay(1_200_000);

        counter += 1;
    }
}

export fn call_start_cpu0() callconv(.naked) noreturn {
    unreachable;
}
