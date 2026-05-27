// Stand-in for a precompiled vendor library (e.g. an esp-wifi `.a` member):
// plain C with the Xtensa C ABI, compiled to an object by build.zig and linked
// into the firmware. Demonstrates that external/precompiled objects link and run
// on this target — the mechanism real vendor RF/BT blobs would need, in both
// directions (the firmware calls in; the blob calls back through a callback,
// like the OSI shim a WiFi blob drives).

int blob_transform(int x) { return x * 3 + 7; }

unsigned blob_checksum(const unsigned char *p, unsigned n) {
    unsigned s = 0;
    for (unsigned i = 0; i < n; i++) s += p[i];
    return s;
}

// Blob calls back into a firmware-supplied callback (the OSI-shim direction).
void blob_run(int x, void (*cb)(int)) { cb(x * 2); }
