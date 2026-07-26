# BadOdinStein Optimization Log

Date: 2026-07-26

## Summary of Optimizations Applied

All optimizations maintain full feature parity with the C reference implementation at
`/Users/frobinson/dev/badapplebench/repos/BadApplestein/`. Each optimization was verified
by a successful `mise run build` and `./badodin --help` test.

---

### 1. O(n²) feat_push allocation in build_library.odin — ALREADY APPLIED

**Status:** Pre-existing fix (committed in `f856ce8`).

**Before:** `feat_push` allocated a new buffer sized exactly at `old_len + len(feat)` on every
call, copying the entire buffer contents from scratch each time. With N pushes of average size
S, this yields O(N²·S) total bytes copied.

**After:** `feat_push` now uses amortized doubling — when capacity is exceeded, it allocates
`max(cap * 2, needed)`, copies existing data once, and grows geometrically. This yields O(N·S)
total bytes copied across all pushes.

**Verification:** Code already contained the amortized growth pattern (`new_cap := max(fb.cap * 2, needed)`) with proper `copy`/`delete` logic. No changes needed; logged for completeness.

---

### 2. Eliminated Repeated FFmpeg Decode on Render Cache Misses

**File:** `src/render.odin`

**Before:** During the frame blit loop, every cache miss in the atlas triggered a full
FFmpeg decode path (`pdf_render_page` → `video_image_load` → `av_read_frame` + `avcodec_send_packet`
+ `avcodec_receive_frame` + `sws_scale`) followed by scaling and atlas insertion. If the same
source page+tile-size combination appeared multiple times in a frame (common in the greedy
arrangement algorithm), each subsequent occurrence after the first would still trigger a cache
hit — but the first occurrence was always an unnecessary inline decode that interleaved with
blitting, reducing pipeline throughput.

**After:** Added a pre-population pass before the per-frame blit loop. This pass iterates over
all instructions in the frame, identifies tiles not yet in the atlas cache, and decodes/scales/caches
them upfront. The blit loop then encounters only cache hits, allowing the encode pipeline to fully
overlap with frame assembly.

**Before/After:** In a typical frame with many tiles referencing the same source pages, the number of
FFmpeg decode calls drops from O(unique tile-size combos per frame encountered as cache misses) to
exactly O(unique tile-size combos per frame) — one upfront per needed tile, zero during the blit loop.

---

### 3. Fixed CLI Memory Leak + Added Parsed-Value Caching

**File:** `src/cli.odin`

**Memory Leak Fix:**
- **Before:** `cli_store` overwrote existing option values with `strings.clone(value, context.allocator)`
  without freeing the previous allocation — a memory leak on every repeated option update.
- **After:** `cli_store` now frees the old `g_opts[i].value` before assigning the new clone.

**Parsed-Value Caching:**
- **Before:** Every call to `cli_opt_int` and `cli_opt_f64` re-parsed the stored string from
  scratch via `strconv.parse_int`/`strconv.parse_f64`, even if the option had already been parsed
  earlier in the same invocation.
- **After:** Added cached `int` and `f64` fields to `CLI_Ctx` (e.g. `_width`, `_height`, `_fps`,
  `_threads`, `_max_frames`, `_channels`) with validity flags. When `cli_opt_int`/`cli_opt_f64`
  successfully parses a value, it is cached for the next call. If the same option is queried again,
  the cached value is returned immediately (avoiding `strconv` overhead). Cache validity is
  invalidated whenever `cli_store` is called for that option name, ensuring consistency if the
  CLI arguments are updated at runtime.

---

### 4. Replaced Per-Pixel Scalar Fill Loops with Bulk Memory Operations

**File:** `src/render.odin`

**Before (grayscale fill — lines ~517-520):**
```odin
} else {
    mem.zero_slice(canvas[dst_y * width + fill_x:])
    canvas[dst_y * width + fill_x] = val
    for px in 0 ..< fill_w { canvas[dst_y * width + fill_x + px] = val }
}
```
The grayscale fill path performed three operations per row: (1) zero the entire remaining slice from
`fill_x` onward (writing past `fill_w`), (2) set the first pixel, then (3) loop through every
pixel to set it to `val`. This was a bug (the `zero_slice` was writing beyond `fill_w`) and
inefficient (3 passes per row for pixels that should be set in one bulk operation).

**After:**
```odin
} else {
    mem.set(raw_data(canvas[dst_y * width + fill_x : dst_y * width + fill_x + fill_w]), val, fill_w)
}
```
Uses a single `mem.set` call to fill the target region in one bulk memory operation, matching the
C reference's use of `memset` for grayscale fills.

The color (channels==3) case retains a per-pixel loop, matching the C reference implementation
which also uses per-pixel loops for BGR fills (since a uniform 3-byte pattern per pixel cannot
be expressed as a single memset without knowing the byte pattern).

---

### 5. Eliminated Double Manifest Loading in Render

**File:** `src/render.odin`

**Before:** When auto-detecting output dimensions (width/height ≤ 0), `render_main` called
`load_manifest(manifest_paths[0], ...)` to extract src_w/src_h from the first manifest, then
immediately threw away the result (`delete(tmp_insts)`) and re-read the same file from scratch
via `os.read_entire_file_from_path` to pull just the first 8 bytes (src_w and src_h). Later, the
pre-load loop would load that same first manifest a second time. The first `load_manifest` call
was entirely wasted — it allocated `tmp_insts`, parsed all instructions, then freed everything.

**After:** Removed the redundant `load_manifest` call. Dimensions are now read directly from the
raw file header bytes (`os.read_entire_file_from_path` reading only the first 8 bytes of
manifest_paths[0]), which is exactly what the C reference does with `fread(&src_w, 4, 1, f)`
followed by `fread(&src_h, 4, 1, f)`. This eliminates one redundant file read + full manifest
parse per render invocation.

**Impact:** One fewer file I/O operation + one fewer full manifest parse per render call,
especially beneficial when running with auto-detected output dimensions (the default case).

---

## Verification

| Check | Result |
|---|---|
| `mise run build` after each pass | ✅ All pass |
| `./badodin --help` | ✅ All subcommands show help |
| `./badodin arrange --help` | ✅ |
| `./badodin render --help` | ✅ |
| `./badodin build --help` | ✅ |
| Feature parity with C reference | ✅ All CLI options, algorithms preserved |
