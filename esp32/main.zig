export fn Reset() callconv(.c) void {
    main();
}
export fn main() callconv(.c) noreturn {
    while (true) {
        asm volatile ("nop");
    }
}
