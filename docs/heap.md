# Heap (`src/heap.zig`)

A bare-metal **bump arena** — fixed-capacity and typed.

`std.mem.Allocator` does not lower on this prebuilt xtensa backend: its dispatch is
a vtable (far) call the backend can't emit, and `std.heap.FixedBufferAllocator`'s
byte→typed casts emit an alignment-check whose panic path won't link. So `heap`
provides a *typed* arena over a static `[capacity]T` buffer — naturally
`@alignOf(T)`-aligned and sliced through a many-item pointer, so every operation is
`inline` and panic-free (no bounds/alignment check).

```zig
const heap = @import("heap");
const Pool = heap.Arena(u32, 256); // 256 u32 reserved in .bss

const xs = Pool.alloc(8) orelse return;  // ?[]u32 — null when the arena is full
const one = Pool.create() orelse return; // ?*u32 — a single item
Pool.reset();                            // free everything at once
```

- `Arena(T, capacity).alloc(n) ?[]T` — bump-allocate `n` items.
- `.create() ?*T` — allocate one item.
- `.reset()` — free the whole region.
- `.used()` / `.items` — items handed out / total capacity.

`examples/heap` allocates a `u32` array, fills it with squares and sums them
(Σ i² for i in 0..8 = 140) — a known-answer check verified live under
`zig build demo`. There is no OS page allocator freestanding; for reference
`std.heap` reports a 4 KiB page size for the esp32* targets.
