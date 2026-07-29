# BadOdinStein Audit Report

Date: 2026-07-24
Project: BadOdinStein — Odin rewrite of BadApplestein (C), tiled video encoding via PDF/image library matching.

---

## 1. Feature Parity Matrix

Mapped against BadApplestein's CLI (README.md + man/badapplestein.1 + man page sub-pages).

### 1.1 Subcommand Parity

| BadApplestein Command | BadOdinStein Status | Notes |
|---|---|---|
| `build <sources_dir>` | **Present** (`main.odin:113-119`) | Accepts aliases `build` and `build-library` |
| `encode <input> <output>` | **Missing** — split across `arrange` and `render` | BadApplestein's single `encode` command combines arrange + render stages; BadOdinStein requires two separate commands |
| `build` subcommand options (--bits, --no-edges, --color, --scales, --multi-scale) | **Partial** | `--bits`, `--no-edges`, `--color`, `--scales` all present (`build_library.odin:89-100`). `--multi-scale` missing — no alias for `--scales 3` |

### 1.2 Global Option Parity

| BadApplestein Option | BadOdinStein Status | Notes |
|---|---|---|
| `--library <dir>` | **Missing** | Hardcoded to `features.bin`/`registry.bin` in cwd (`arrange.odin:519`, `render.odin:197-198`) |
| `--preset <name>` (8k/4k/1080p/720p) | **Missing** | No preset system; render uses hardcoded 7680x4320 when dims unknown |
| `--width <n>` | **Partial** (`render.odin:200`) | Render-only; no arrange-stage support, no preset-override system |
| `--height <n>` | **Partial** (`render.odin:201`) | Same caveats as `--width` |
| `--fps <n>` | **Partial** (`render.odin:202`) | Render-only; auto-detects from sidecar if omitted |
| `--codec <name>` (prores, h264) | **Missing** | `render.odin:332` hardcodes `"prores_ks"`; `video.odin:774-814` supports codec selection internally but no CLI flag |
| `--no-hw` | **Missing** | `video.odin:853-858` auto-detects hardware codecs (videotoolbox/vaapi/nvenc/amf) but no CLI flag to disable |
| `--max-frames <n>` | **Present** (`arrange.odin:522`, `render.odin:203`) | |
| `--threads <n>` | **Present** (`cli.odin:92-97`) | Global option used in arrange and render |
| `--verbose` | **Present** (`cli.odin:87`) | Sets `g_cli.verbose` |
| `--quiet` | **Present** (`cli.odin:89`) | Sets `g_cli.quiet` |
| `--json` | **Present but non-functional** (`cli.odin:90-91`) | Parser stores the flag; output helpers still emit human-readable prefixes (`[info]`, `[warn]`) — never actual JSON |
| `--keep-manifests` | **Missing** | Temp manifests unconditionally deleted after render (`render.odin` cleanup) |
| `--help` | **Present** (per-subcommand in `main.odin`) | |
| `--version` | **Present** (`main.odin:124-125`) | Not listed in help text |

### 1.3 Build-Subcommand Specific Options (BadApplestein man page only)

| BadApplestein Option | BadOdinStein Status | Notes |
|---|------|---|
| `--bits <n>` | **Present** (`build_library.odin:90`) | |
| `--no-edges` | **Present** (`build_library.odin:91`) | |
| `--color` | **Present** (`build_library.odin:92`) | |
| `--scales <n>` | **Present** (`build_library.odin:99-100`) | |
| `--multi-scale` (alias for `--scales 3`) | **Missing** | No alias; `--scales` must be explicit |

### 1.4 BadOdinStein Extras (Not in BadApplestein)

| Feature | Location | Notes |
|---|---|---|
| `--max-block <N>` (tile block size limit) | `arrange.odin:523` | Not in BadApplestein |
| `--hero-min <N>` (min hero block size) | `arrange.odin:524` | Not in BadApplestein |
| `--max-block-pct` / `--hero-min-pct` | `arrange.odin:523-524` | Undocumented; help text says `--max-block`/`--hero-min` but these names don't work |
| `--output <file>` | `render.odin:199` | Named output path for render stage |
| `--features <file>` / `--registry <file>` | `arrange.odin:519-520` | Explicit paths; BadApplestein derives from `--library` |
| `--manifests <dir>` | `arrange.odin:521`, `render.odin:197` | Explicit manifest directory |
| `--channels <N>` | `render.odin:204` | Grayscale (1) vs color (3) render mode |

### 1.5 Key Discrepancies

1. **`--max-block` / `--hero-min` naming bug**: Help text documents `--max-block` and `--hero-min`, but `arrange.odin:523-524` reads `--max-block-pct` and `--hero-min-pct`. The documented flags do not work.
2. **`--codec` entirely absent**: Despite `video.odin:774` and `render.odin:332` supporting codec selection, it's hardcoded to `"prores_ks"` with no CLI override.
3. **`--no-hw` absent**: Hardware codec detection exists (`video.odin:853-858`) but cannot be disabled by the user.
4. **`--keep-manifests` has no counterpart**: Temp manifests are unconditionally deleted after render.
5. **`--preset` absent**: No preset resolution system unlike BadApplestein.
6. **`--library` absent**: No mechanism to point at a custom feature library directory; always looks for `features.bin`/`registry.bin` in cwd.
7. **`--json` flag is a no-op**: Parser stores it but output still uses human-readable format.
8. **`encode` command merged differently**: BadApplestein's single `encode` (arrange+render combined) is split into two separate `arrange` and `render` commands in BadOdinStein, with no wrapper to run both.

---

## 2. Code Quality Findings

### HIGH Severity

| File | Line | Finding |
|---|---|---|
| `build_library.odin` | 97–109 | **Buffer overrun on `feat_scales`**: Array declared as `[3]int` but loop allows `n_feat_scales` up to 16. Writing past the array corrupts adjacent memory. (`feat_scales[n_feat_scales]` for `n_feat_scales >= 3`) — [FIXED] Array changed to `[16]int` |
| `build_library.odin` | 190 | **Slice past array end**: `feat_scales[:n_feat_scales]` creates a slice extending past the 3-element array when `n_feat_scales > 3`. Passed to `img_compute_feature_multires`, `write_features`, and elsewhere. — [FIXED] Array is now `[16]int`, safe for max 16 scales |
| `arrange.odin` | 386–412 | **`defer delete` inside loop**: `coarse_feat` allocated with `make([]u8, N*N)` per spec iteration inside `solve_full`. Odin defers to proc scope, not loop body — all deferred deletes reference the same variable, leaking intermediate allocations. — [FIXED] Restructured to allocate once per thread/managed explicitly |
| `system_detect.odin` | 20–25 | **Memory leak on `stdout`**: `delete(stdout)` only called in the success branch. If `os.process_exec` fails or the command fails, `stdout` leaks. On non-macOS systems where `sysctl` doesn't exist, `os.process_exec` fails and `stdout` leaks on every call. — [FIXED] Changed to `defer delete(stdout)` before error checks |

### MEDIUM Severity

| File | Line | Finding |
|---|---|---|
| `main.odin` | 13 | **Misleading CLI help**: Documents `--max-block` but actual code reads `--max-block-pct`. Users following help would pass a non-functional flag. `--hero-min` has the same issue (`--hero-min-pct`). |
| `cli.odin` | 12–14 | **`json_mode` non-functional**: `g_cli.json_mode` is set and checked, but output helpers still emit `[info]`, `[warn]`, etc. prefixes — never actual JSON. The flag is a no-op for structured consumption. |
| `cli.odin` | 20–23 | **Value truncation**: `g_opts` values capped at 255 chars; longer values silently truncated by `copy()`. |
| `arrange.odin` | 27–36 | **Strided sampling collision risk**: `full_feat_hash` samples at most 64 bytes using strided access. Different features colliding at sampled stride positions produce false cache hits and incorrect match results. |
| `arrange.odin` | 130–217 | **Unchecked raw pointer arithmetic**: `load_features` and `load_registry` perform extensive pointer casts on `buf` with minimal bounds validation. A malformed/truncated data file could cause out-of-bounds reads. |
| `render.odin` | 369–372 | **Grayscale canvas zero overflow**: `mem.zero_slice(canvas[dst_y * width + fill_x:])` zeroes from fill start to end of entire canvas (including subsequent rows), then rewrites `fill_w` bytes. Wasteful and confusing. |
| `render.odin` | 379 | **Silent data loss**: Out-of-bounds registry entries silently skipped (`continue`) — no warning. Affected region renders as black with no diagnosis. |
| `arrange.odin` | 449 | **Confusing variable name**: `feature_ch` (1=color, 0=grayscale) vs parameter `color` — naming inversion introduces risk. |
| `pdf.odin` | 43 | **Redundant `\|\|`**: `(end[0] == '.' \|\| end[0] == '.')` — both sides identical. Copy-paste smell. |
| `pdf.odin` | 43 | **False positive extension match**: Only checks last 4 chars, so `file.pdf.bak` or `file.pdf.exe` would match as PDFs. |
| `build_library.odin` | 9–12 | **Case-sensitive extension matching**: `has_ext` does case-sensitive suffix matching. `IMAGE.PNG` and `document.PDF` are silently skipped. Contrast with `pdf.odin`'s case-insensitive `has_pdf_ext`. |
| `build_library.odin` | 71 | **`defer delete` in loop**: `entry_buf` allocated per registry entry in loop; deferred deletes defer to proc scope, risking leaks of earlier allocations. |
| `build_library.odin` | 137–146 | **Duplicate directory scan**: Directory scanned twice — first to count, second to process. Should be a single pass. |
| `video.odin` | 756–769 | **Inconsistent field naming**: `sws_gray8` uses lowercase prefix matching C API, while `VideoDecoder` uses same `sws` field but with different naming convention. |
| `imgops.odin` | 26 | **Nearest-neighbor vs area-averaging quality difference**: Fast-path for exact integer downscale uses nearest-neighbor, producing different results from the area-averaging slow path for certain resize ratios. |
| `types.odin` | 47 | **Magic numbers for `op_id`**: -1=solid black, -2=solid white, >=0=registry index. Not self-documenting. |
| `types.odin` | 69 | **`int` vs `i64`**: `Timings.tiles` and `Timings.hits` use `int` (signed). For large frame counts on 64-bit, `i64` would be safer. |

### LOW Severity

| File | Line | Finding |
|---|---|---|
| `cli.odin` | 104 | **Edge case in short-flag parsing**: Bare `-` (single dash, no char) stores empty flag key `""`. |
| `cli.odin` | 150 | **Misleading return type**: `cli_die -> !` returns an error type, but calls `os.exit(1)` which never returns. |
| `cli.odin` | 171 | **Ignored return**: `os.flush(os.stderr)` return value discarded. |
| `match.odin` | 49 | **Variable shadowing**: `coarse_len :=` shadows the parameter in the same scope. Works but confusing. |
| `match.odin` | 53–63 | **Mixed signed/unsigned sentinels**: `merged_dist` uses `max(u32)` while `merged_best` uses `-1` as sentinel. Risk of type confusion on future edits. |
| `render.odin` | 136–193 | **Scale strategy not documented**: `load_manifest` uses "cover" scaling (fit larger dimension, crop smaller). Users may expect "contain". |
| `render.odin` | 462–469 | **Ignored return**: `video_encoder_write_frame` return value discarded — failed frames silently lost. |
| `video.odin` | 992 | **Redundant PTS read-modify-write**: `frame_set_pts(enc.frame, frame_pts(enc.frame) + 1)` reads PTS then increments, instead of using a counter in the encoder struct. |
| `match.odin` | 89 | **Temporary variable in swap**: Could use tuple assignment `kb[k], kb[k-1] = kb[k-1], kb[k]`. |
| `system_detect.odin` | 10–14 | **Duplicate `get_processor_core_count()` call**: Same syscall invoked twice; result should be cached. |
| `system_detect.odin` | 16 | **Hardcoded 16 GB default memory**: On non-macOS systems where `sysctl` fails, 16 GB is assumed, potentially over-requesting 4 GB cache on a system with far less RAM. |

### PDF Stub

| File | Line | Finding |
|---|---|---|
| `pdf.odin` | 11 | **PDF rendering is a stub**: Returns -1 with `TODO: Add mupdf FFI`. Any build using PDFs as sources will fail silently at matching time and be skipped during rendering. |

---

## 3. Security Findings

### HIGH Severity

| File | Line | Finding |
|---|---|---|
| `video.odin` | 43 | **Hardcoded FFmpeg struct offsets**: All offsets (e.g., `AV_CODECCTX_WIDTH :: uintptr(112)`, `AV_FMT_NB_STREAMS :: uintptr(44)`) are manually derived from FFmpeg 8.1.2 on macOS ARM64. A different FFmpeg version, platform, or build silently produces wrong memory accesses — no crash, just corruption. |
| `video.odin` | 23–31 | **All FFmpeg handles are `rawptr`**: `AVCodec`, `SwsContext`, `AVFormatContext`, `AVCodecContext`, `AVFrame`, `AVPacket`, `AVStream` — all untyped `rawptr`. Passing the wrong pointer type to any foreign function call produces undefined behavior with no compile-time check. |
| `video.odin` | 210–249, 291–320, etc. | **Direct pointer-arithmetic writes to FFmpeg struct fields**: Functions like `codecctx_set_width`, `stream_set_time_base`, `frame_set_pts` write to FFmpeg struct memory via `uintptr(ctx) + OFFSET)^ = value`. Wrong offsets corrupt adjacent struct fields including function pointers. |

### MEDIUM Severity

| File | Line | Finding |
|---|---|---|
| `ffmpeg_bridge.c` | 8–10 | **No NULL pointer validation**: Every `ff_*` function dereferences its `void*` argument without null checks. A NULL from a failed Odin allocation crashes the process. |
| `ffmpeg_bridge.c` | entire file | **Dead code — no build integration**: `ffmpeg_bridge.c` is never compiled or linked into the `badodin` binary. The build command compiles only Odin source files. The file is orphaned and provides no function. |
| `ffmpeg_bridge.c` | entire file | **Duplicates `video.odin` FFI logic**: All field accessor functions are independently re-implemented. Any FFmpeg version update requires updating two separate codebases, multiplying the risk of one falling out of sync. |
| `ffmpeg_bridge.c` | 175–205 | **Exposes raw internal FFmpeg handles**: Functions like `ff_fmtc_pb` and `ff_fmtc_pb_ptr` expose `AVIOContext` and `AVOutputFormat` directly to callers who should not manipulate them. |
| `video.odin` | 36 | **`AVRational` layout unverified**: Manually defined as `struct { num: c.int, den: c.int }` — Odin cannot verify this matches the C ABI layout used by FFmpeg. A layout change silently breaks `av_packet_rescale_ts` calls. |
| `video.odin` | 416–429 | **Hardcoded FFmpeg enum constants**: `AV_PIX_FMT_BGR24 :: c.int(3)`, `AV_PIX_FMT_GRAY8 :: c.int(8)`, etc. Reassignment in a newer FFmpeg version silently produces wrong behavior. |
| `video.odin` | 156–269 | **`foreign` blocks lack header cross-checks**: Odin's `foreign` block declarations are not validated against actual FFmpeg C headers. A mismatched signature silently corrupts the ABI. |
| `video.odin` | 635–749 | **Deep error paths with potential resource leaks**: `video_image_load` has multiple early-return error paths; while each currently calls cleanup, any future insertion that adds a new return without cleanup will leak file descriptors and memory. |
| `video.odin` | 433 | **`clone_to_cstr` — caller must `delete` buffer**: Returns both a `cstring` view and a `[]u8` buffer that the caller must free. Easy to forget and causes memory leaks. |
| `arrange.odin` | 130–217 | **Unchecked pointer casts in `load_features`/`load_registry`**: Truncated/malformed data files with valid header size but invalid data at later offsets cause out-of-bounds reads through unchecked raw pointer casts. |
| `arrange.odin` | 449 | **`feature_ch` naming inversion**: Variable named `feature_ch` is 1 for color and 0 for grayscale, opposite of what the name implies. This inversion risks incorrect channel selection at a security-relevant boundary (how user data is interpreted). |

### LOW Severity

| File | Line | Finding |
|---|---|---|
| `ffmpeg_bridge.c` | entire file | **No `#include` guard**: Not a header, but if it were ever `#include`d from another translation unit, duplicate symbols would result. |
| `ffmpeg_bridge.c` | entire file | **No version guards**: `#include` of FFmpeg headers without `#if` version checks. |
| `video.odin` | 624 | **`free()` after `new()`**: Inconsistent with codebase patterns — `new()` allocates, `free()` frees it, but error paths use `defer` cleanup inconsistently. |
| `render.odin` | 475 | **Integer division before float conversion**: `atlas.hits / (atlas.hits + atlas.misses)` performs integer division before `* 100.0`, so hit ratios below 100% show as 0% for the first few frames. |

---

## 4. Performance Findings

### HIGH Severity

| File | Line | Finding |
|---|---|---|
| `build_library.odin` | 26–32 | **O(n²) allocation in `feat_push`**: Every call allocates `old_len + len(feat)`, copies all old data, deletes old buffer, copies new feat. N calls = N allocations and N² bytes copied. Should use amortized doubling. |
| `arrange.odin` | 411 | **Per-spec `coarse_feat` allocation in hot loop**: `make([]u8, N*N)` with `defer delete` inside `solve_full`'s `n_specs` loop — hundreds of alloc/free cycles per frame in the compute-heavy matching path. |
| `render.odin` | 398–424 | **Full FFmpeg decode path on every cache miss**: Tile not in atlas? Re-runs video decode pipeline for a single image load — opens AVFormatContext, finds stream, allocates codec context, opens codec, creates SwsContext, allocates AVFrame. |
| `render.odin` | 410 | **Per-tile pixel allocation on cache miss**: `make([]u8, dw * dh * channels)` for every cache miss — potentially dozens/hundreds of allocations per frame. |
| `render.odin` | 421 | **Duplicate grayscale conversion allocation**: When channels!=3 but source is color, allocates full `w*h` grayscale buffer in addition to the `scaled.pixels` buffer — double allocation for same source data. |
| `video.odin` | 590 | **Full frame buffer per decode call**: `make([]u8, w * h * 3)` per `video_decoder_read_frame` call — ~6.2 MB per frame at 1080p, ~25 MB at 4K. In the core arrange loop. |
| `video.odin` | 43 | **Hardcoded FFmpeg offsets**: Wrong offsets = silent corruption of FFmpeg struct state, which on x86 could overwrite function pointers leading to arbitrary code execution. |

### MEDIUM Severity

| File | Line | Finding |
|---|---|---|
| `arrange.odin` | 254 | **Large integral image per frame**: `make([]i64, (w+1)*(h+1))` on 3840x2160 = ~264 MB. Re-allocated only on dimension change, but the commitment is significant. |
| `arrange.odin` | 620–628 | **Manifest/tiles reallocation every frame when capacity exceeded**: Copy-and-free cycle for both `manifest` and `tiles` arrays, with `tiles` being `db.feat_len * new_cap` bytes. |
| `cli.odin` | 43 | **`strings.clone` on every option lookup**: `cli_get` clones stored values on every call. Arrange and render call option lookups per frame for values that never change. |
| `match.odin` | 53–55 | **Per-call `match_batch_coarse` allocations**: `make([]u32, num_targets * K)` and `make([]int, num_targets * K)` on every call, proportional to `num_targets * 16`. |
| `imgops.odin` | 145, 150, 192 | **Three hot-path allocations per feature computation**: `tmp_buf`, `gray_buf`, `full_gray_buf` — all per call, each `w*h` or `N*N` bytes. |
| `render.odin` | 340 | **Full canvas zero per frame**: `mem.zero_slice(canvas)` zeroes entire `width*height*channels` buffer every frame even when only a portion is modified. ~83 MB for 4K color. |
| `render.odin` | 372 | **Per-pixel scalar fill loop**: Solid-color fills use per-pixel writes instead of `mem.set` or bulk `copy` — not vectorizable. |
| `render.odin` | 265 + 309 | **Double manifest loading**: Manifest[0] parsed into `tmp_insts` for dimension detection (line 265), then all manifests parsed again into `loaded_insts` (line 309). First manifest read from disk twice. |
| `render.odin` | 273 | **Wasted allocation on dimension detection**: `tmp_insts` allocated just to read source dimensions, then freed. Could read directly from binary header. |
| `video.odin` | 992 | **Read-modify-write PTS**: `frame_set_pts(enc.frame, frame_pts(enc.frame) + 1)` reads PTS then increments. Simple counter in encoder struct would be cheaper. |

### LOW Severity

| File | Line | Finding |
|---|---|---|
| `arrange.odin` | 499–500 | **Two `cache_put` calls per cache miss**: Both feature cache and coarse cache updated on miss; coarse uses short prefix hash adding extra call overhead on hot miss path. |
| `arrange.odin` | 558–565 | **Full hero scoring over all pages**: O(n_pages) scan for white/black page IDs at startup. Data is already in memory; could use pre-computed page hashes. |
| `system_detect.odin` | 10–14 | **`get_processor_core_count()` called twice**: Same syscall invoked at lines 10 and 13. |
| `build_library.odin` | 137–146 | **Duplicate directory scan**: Two passes over same directory — one to count, one to process. |
| `imgops.odin` | 26 | **Nearest-neighbor vs area-averaging quality difference**: Fast-path for exact integer downscale uses nearest-neighbor with different quality than area-averaging slow path. |
| `match.odin` | 89 | **Manual swap with temp variable**: Could use tuple assignment for clarity; no perf cost either way. |
| `video.odin` | 957 | **`MAX_VIDEO_PLANES :: 8` hardcoded**: FFmpeg implementation detail, not a guaranteed API contract. |
| `build_library.odin` | 16–18 | **`defer delete` in loop over registry entries**: Same pattern as other defer-in-loop issues — potential leaks of earlier allocations. |
| `render.odin` | 462–469 | **Ignored `video_encoder_write_frame` return**: Failed frames silently dropped with no indication. |

---

## Appendix A: Missing Toolchain

The `odin` compiler is not installed in this environment. The following checks could not be verified:

- Build succeeds without warnings or errors
- Runtime correctness of matching/rendering logic
- Memory safety under AddressSanitizer/UBSan
- Actual runtime performance of hot paths (benchmarks)
- Code formatting compliance (`odin fmt`)
- ODIN-specific lint checks (if any exist)

These items should be checked once `odin` is available.

---

## Appendix B: Source File Inventory

| File | Lines | Role |
|---|---|---|
| `main.odin` | ~130 | Entry point, CLI dispatch, help text |
| `cli.odin` | ~180 | CLI argument parsing, output helpers, progress display |
| `arrange.odin` | ~530 | Arrange pipeline: decode video, match tiles to library, write manifests |
| `render.odin` | ~500 | Render pipeline: assemble frames from manifests, encode output video |
| `build_library.odin` | ~150 | Build source library from PDFs/images |
| `video.odin` | ~1090 | FFmpeg FFI for decode/encode, video format handling |
| `ffmpeg_bridge.c` | ~205 | C helper functions for FFmpeg struct access (dead code) |
| `imgops.odin` | ~190 | Image operations: resize, Sobel, feature computation |
| `match.odin` | ~70 | Tile matching and distance computation |
| `pdf.odin` | ~30 | PDF rendering stub (mupdf FFI not yet implemented) |
| `types.odin` | ~80 | Core data types, constants |
| `system_detect.odin` | ~30 | Platform detection (CPU, memory) |
