package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import "core:math"
import "core:time"
import "core:thread"
import "core:sync"

MAX_INSTS :: 65536
FRAME_QUEUE_SIZE :: 4

// ── Atlas cache (tile-level caching) ──
Atlas_Entry :: struct {
    op_id, tile_w, tile_h: int,
    pixels: []u8,
    channels, stride: int,
    bytes: u64,
    valid: int,    // 0=empty, 1=occupied, 2=tombstone
    lru: u32,
}

Atlas_Cache :: struct {
    entries:          []Atlas_Entry,
    capacity, count:  int,
    total_bytes:      u64,
    budget:           u64,
    tick:             u32,
    enabled:          bool,
    hits, misses:     int,
}

atlas_init :: proc(atlas: ^Atlas_Cache, budget: u64) {
    atlas.capacity = 256
    atlas.entries = make([]Atlas_Entry, atlas.capacity)
    atlas.budget = budget
    atlas.enabled = budget > 0
}

atlas_free :: proc(atlas: ^Atlas_Cache) {
    for i in 0 ..< atlas.capacity {
        if atlas.entries[i].valid == 1 {
            delete(atlas.entries[i].pixels)
        }
    }
    delete(atlas.entries)
}

atlas_hash :: proc(op_id, tw, th: int) -> u32 {
    h := u32(op_id) * 2654435761
    h ~= u32(tw) * 374761393
    h ~= u32(th) * 668265263
    if h == 0 { h = 1 }
    return h
}

atlas_lookup :: proc(atlas: ^Atlas_Cache, op_id, tw, th: int) -> ^Atlas_Entry {
    if !atlas.enabled { return nil }
    h := atlas_hash(op_id, tw, th)
    for probe in 0 ..< atlas.capacity {
        idx := int((h + u32(probe)) % u32(atlas.capacity))
        if atlas.entries[idx].valid == 0 { return nil }
        if atlas.entries[idx].valid == 2 { continue }
        if atlas.entries[idx].op_id == op_id &&
           atlas.entries[idx].tile_w == tw &&
           atlas.entries[idx].tile_h == th {
            atlas.entries[idx].lru = atlas.tick
            atlas.tick += 1
            atlas.hits += 1
            return &atlas.entries[idx]
        }
    }
    atlas.misses += 1
    return nil
}

atlas_evict_lru :: proc(atlas: ^Atlas_Cache) {
    oldest_idx := -1
    oldest_tick: u32 = max(u32)
    for i in 0 ..< atlas.capacity {
        if atlas.entries[i].valid == 1 && atlas.entries[i].lru < oldest_tick {
            oldest_tick = atlas.entries[i].lru
            oldest_idx = i
        }
    }
    if oldest_idx >= 0 {
        atlas.total_bytes -= atlas.entries[oldest_idx].bytes
        delete(atlas.entries[oldest_idx].pixels)
        atlas.entries[oldest_idx].valid = 2
        atlas.count -= 1
    }
}

atlas_insert :: proc(atlas: ^Atlas_Cache, op_id, tw, th: int, src_pixels: []u8, src_channels, src_stride: int) {
    if !atlas.enabled { return }
    
    entry_bytes := u64(tw * th * src_channels)
    for atlas.total_bytes + entry_bytes > atlas.budget && atlas.count > 0 {
        atlas_evict_lru(atlas)
    }
    
    // Find insertion slot
    h := atlas_hash(op_id, tw, th)
    tombstone_idx := -1
    for probe in 0 ..< atlas.capacity {
        idx := int((h + u32(probe)) % u32(atlas.capacity))
        if atlas.entries[idx].valid == 0 || atlas.entries[idx].valid == 2 {
            use_idx := idx if tombstone_idx < 0 else tombstone_idx
            atlas.entries[use_idx].op_id = op_id
            atlas.entries[use_idx].tile_w = tw
            atlas.entries[use_idx].tile_h = th
            atlas.entries[use_idx].channels = src_channels
            atlas.entries[use_idx].stride = tw * src_channels
            atlas.entries[use_idx].pixels = make([]u8, tw * th * src_channels)
            row_bytes := tw * src_channels
            for y in 0 ..< th {
                copy(atlas.entries[use_idx].pixels[y * atlas.entries[use_idx].stride:],
                     src_pixels[y * src_stride:])
            }
            atlas.entries[use_idx].bytes = entry_bytes
            atlas.entries[use_idx].valid = 1
            atlas.entries[use_idx].lru = atlas.tick
            atlas.tick += 1
            atlas.total_bytes += entry_bytes
            atlas.count += 1
            return
        }
        if atlas.entries[idx].valid == 2 && tombstone_idx < 0 {
            tombstone_idx = idx
        }
        _ = probe
    }
}

// ── Encode pipeline (producer-consumer) ──
Frame_Slot :: struct {
    pixels: []u8,
    filled: bool,
}

Encode_Pipeline :: struct {
    slots:          [FRAME_QUEUE_SIZE]Frame_Slot,
    write_idx:      int,
    read_idx:       int,
    count:          int,
    encoder:        ^VideoEncoder,
    enc_width:      int,
    enc_height:     int,
    enc_channels:   int,
    mutex:          sync.Mutex,
    can_write:      sync.Cond,
    can_read:       sync.Cond,
    done:           bool,
    frames_written: int,
}

pipeline_init :: proc(p: ^Encode_Pipeline, enc: ^VideoEncoder, width, height, channels: int) {
    p.encoder = enc
    p.enc_width = width
    p.enc_height = height
    p.enc_channels = channels
    p.write_idx = 0
    p.read_idx = 0
    p.count = 0
    p.done = false
    p.frames_written = 0
    // Mutex and Cond zero values are valid in Odin — no init needed
    for i in 0 ..< FRAME_QUEUE_SIZE {
        p.slots[i].pixels = make([]u8, width * height * channels)
        p.slots[i].filled = false
    }
}

pipeline_push :: proc(p: ^Encode_Pipeline, canvas: []u8) {
    sync.mutex_lock(&p.mutex)
    for p.count >= FRAME_QUEUE_SIZE {
        sync.cond_wait(&p.can_write, &p.mutex)
    }
    slot := &p.slots[p.write_idx]
    copy(slot.pixels, canvas)
    slot.filled = true
    p.write_idx = (p.write_idx + 1) % FRAME_QUEUE_SIZE
    p.count += 1
    sync.cond_signal(&p.can_read)
    sync.mutex_unlock(&p.mutex)
}

encoder_thread_proc :: proc(t: ^thread.Thread) {
    p := (^Encode_Pipeline)(t.data)
    for {
        sync.mutex_lock(&p.mutex)
        for p.count == 0 && !p.done {
            sync.cond_wait(&p.can_read, &p.mutex)
        }
        if p.count == 0 && p.done {
            sync.mutex_unlock(&p.mutex)
            break
        }
        slot := &p.slots[p.read_idx]
        p.read_idx = (p.read_idx + 1) % FRAME_QUEUE_SIZE
        p.count -= 1
        sync.cond_signal(&p.can_write)
        sync.mutex_unlock(&p.mutex)

        // Encode outside the lock
        enc_frame: Img
        enc_frame.w = p.enc_width
        enc_frame.h = p.enc_height
        enc_frame.channels = p.enc_channels
        enc_frame.stride = p.enc_width * p.enc_channels
        enc_frame.pixels = slot.pixels
        video_encoder_write_frame(p.encoder, &enc_frame)
        slot.filled = false

        sync.mutex_lock(&p.mutex)
        p.frames_written += 1
        sync.mutex_unlock(&p.mutex)
    }
}

pipeline_close :: proc(p: ^Encode_Pipeline) {
    sync.mutex_lock(&p.mutex)
    p.done = true
    sync.cond_broadcast(&p.can_read)
    sync.mutex_unlock(&p.mutex)
    // Wait for encoder thread to finish — caller joins the thread
}

pipeline_destroy :: proc(p: ^Encode_Pipeline) {
    for i in 0 ..< FRAME_QUEUE_SIZE {
        delete(p.slots[i].pixels)
    }
}

// ── Manifest loading ──
load_manifest :: proc(path: string, out_insts: ^[]Inst, out_n: ^int, target_w, target_h: int) -> int {
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil { return -1 }
    defer delete(data)
    
    if len(data) < 12 { return -1 }
    
    src_w := int((^u32)(&data[0])^)
    src_h := int((^u32)(&data[4])^)
    n := int((^u32)(&data[8])^)
    if n > MAX_INSTS { return -1 }
    
    // Compute scale
    scale: f64 = 1.0
    ox: f64 = 0
    oy: f64 = 0
    if src_w > 0 && src_h > 0 && (src_w != target_w || src_h != target_h) {
        sx := f64(target_w) / f64(src_w)
        sy := f64(target_h) / f64(src_h)
        scale = max(sx, sy)
        ox = (f64(target_w) - f64(src_w) * scale) * 0.5
        oy = (f64(target_h) - f64(src_h) * scale) * 0.5
    }
    
    insts := make([]Inst, n)
    off := 12
    for i in 0 ..< n {
        if off + 24 > len(data) { delete(insts); return -1 }
        bx := (^i32)(&data[off])^
        by := (^i32)(&data[off + 4])^
        bw := (^i32)(&data[off + 8])^
        bh := (^i32)(&data[off + 12])^
        op_id := (^i32)(&data[off + 16])^
        page_idx := (^i32)(&data[off + 20])^
        off += 24
        
        if scale != 1.0 {
            nx := f64(bx) * scale + ox
            ny := f64(by) * scale + oy
            nw := f64(bw) * scale
            nh := f64(bh) * scale
            insts[i].x = i32(nx + 0.5)
            insts[i].y = i32(ny + 0.5)
            insts[i].w = i32(nw + 0.5)
            insts[i].h = i32(nh + 0.5)
            if insts[i].x < 0 { insts[i].x = 0 }
            if insts[i].y < 0 { insts[i].y = 0 }
            if int(insts[i].x + insts[i].w) > target_w { insts[i].w = i32(target_w) - insts[i].x }
            if int(insts[i].y + insts[i].h) > target_h { insts[i].h = i32(target_h) - insts[i].y }
        } else {
            insts[i] = Inst{bx, by, bw, bh, op_id, page_idx}
        }
    }
    
    out_insts^ = insts
    out_n^ = n
    return 0
}

// ── Main render entry point ──
render_main :: proc() {
    man_dir := cli_opt_str("manifests", "manifests_greedy")
    reg_path := cli_opt_str("registry", "registry.bin")
    output := cli_opt_str("output", "output.mov")
    width := cli_opt_int("width", 0)
    height := cli_opt_int("height", 0)
    fps_val := cli_opt_f64("fps", 0.0)
    max_frames := cli_opt_int("max-frames", 0)
    channels := cli_opt_int("channels", 1)
    if channels != 1 && channels != 3 { channels = 1 }
    
    // System detect
    sys := system_detect()
    if g_cli.threads > 0 { sys.num_threads = g_cli.threads }
    
    // Apply preset
    preset := cli_opt_str("preset", "")
    if preset == "8k" {
        width = 7680; height = 4320; fps_val = 60.0
    } else if preset == "4k" {
        width = 3840; height = 2160; fps_val = 60.0
    } else if preset == "1080p" {
        width = 1920; height = 1080; fps_val = 30.0
    } else if preset == "720p" {
        width = 1280; height = 720; fps_val = 30.0
    }
    
    cli_info("system: %d cores | %d MB RAM | %d threads",
             sys.cpu_cores, sys.total_memory_bytes / (1024 * 1024), sys.num_threads)
    
    // Load registry
    reg: Registry
    if load_registry(reg_path, &reg) != 0 {
        cli_die("cannot load registry: %s", reg_path)
    }
    defer {
        for e in reg.entries { delete(e.pdf_path) }
        delete(reg.entries)
    }
    cli_info("registry: %d entries", reg.n)
    
    // Scan manifests
    dir_handle, derr := os.open(man_dir)
    if derr != nil { return }
    defer os.close(dir_handle)
    
    manifest_paths: [dynamic]string
    defer delete(manifest_paths)
    
    entries, dir_err := os.read_dir(dir_handle, -1, context.allocator)
    if dir_err != nil { os.close(dir_handle); return }
    
    for entry in entries {
        name := entry.name
        if !strings.has_suffix(name, ".bin") { continue }
        if name == "fps.bin" { continue }
        full := fmt.tprintf("%s/%s", man_dir, name)
        append(&manifest_paths, full)
    }
    
    if len(manifest_paths) == 0 {
        cli_die("no manifests found in: %s", man_dir)
    }
    cli_info("manifests: %d frames", len(manifest_paths))
    
    // Sort manifest paths by frame number (extract number from filename)
    // Use insertion sort — fast enough for typical frame counts
    for i in 1 ..< len(manifest_paths) {
        key := manifest_paths[i]
        j := i - 1
        for j >= 0 && manifest_paths[j] > key {
            manifest_paths[j + 1] = manifest_paths[j]
            j -= 1
        }
        manifest_paths[j + 1] = key
    }
    
    // Auto-detect dimensions from first manifest header (src_w/src_h at bytes 0-7)
    if width <= 0 && height <= 0 {
        data, data_err := os.read_entire_file_from_path(manifest_paths[0], context.allocator)
        if data_err == nil && len(data) >= 8 {
            width = int((^u32)(&data[0])^)
            height = int((^u32)(&data[4])^)
        }
        if data_err == nil { delete(data) }
    }
    if width <= 0 { width = 7680 }
    if height <= 0 { height = 4320 }
    
    // Auto-detect fps from sidecar
    if fps_val <= 0.0 {
        fps_path := fmt.tprintf("%s/fps.bin", man_dir)
        fps_data, fps_err := os.read_entire_file_from_path(fps_path, context.allocator)
        if fps_err == nil {
            if len(fps_data) >= 8 {
                fps_val = (^f64)(&fps_data[0])^
            }
            delete(fps_data)
        }
    }
    if fps_val <= 0.0 { fps_val = 30.0 }
    
    mode_str := "(color)" if channels == 3 else "(grayscale)"
    cli_info("render: %d frames %dx%d %s %.1f fps -> %s", len(manifest_paths), width, height, mode_str, fps_val, output)
    
    // Pre-load all manifests
    loaded_insts := make([][]Inst, len(manifest_paths))
    loaded_n := make([]int, len(manifest_paths))
    defer {
        for i in 0 ..< len(manifest_paths) {
            if loaded_insts[i] != nil { delete(loaded_insts[i]) }
            // NOTE: manifest_paths[i] strings are from fmt.tprintf (temporary allocator),
            // so we must NOT delete them with the heap allocator.
        }
        delete(loaded_insts)
        delete(loaded_n)
    }
    
    loaded_count := 0
    for i in 0 ..< len(manifest_paths) {
        if load_manifest(manifest_paths[i], &loaded_insts[i], &loaded_n[i], width, height) == 0 {
            loaded_count += 1
        } else {
            cli_warn("skip bad manifest: %s", manifest_paths[i])
        }
    }
    cli_info("loaded: %d manifests (%d frames)", loaded_count, len(manifest_paths))
    
    // Atlas cache
    atlas: Atlas_Cache
    atlas_init(&atlas, sys.cache_budget_bytes)
    defer atlas_free(&atlas)
    
    // Canvas
    canvas_bytes := width * height * channels
    canvas := make([]u8, canvas_bytes)
    defer delete(canvas)

    // Gray scratch buffer — pre-allocated and reused across all tiles
    // to avoid per-tile malloc/free overhead.
    gray_scratch: []u8
    gray_scratch_cap: int
    gray_scratch_img: Img
    defer delete(gray_scratch)
    
    // Process frames
    max_frames_actual := len(manifest_paths)
    if max_frames > 0 && max_frames < max_frames_actual { max_frames_actual = max_frames }
    
    // Open video encoder
    enc := video_encoder_open(output, width, height, int(fps_val), "prores_ks", 0)
    if enc == nil { cli_die("cannot open encoder: %s", output) }
    defer video_encoder_close(enc)

    // Start encode pipeline (producer-consumer)
    pipeline: Encode_Pipeline
    pipeline_init(&pipeline, enc, width, height, channels)
    defer pipeline_destroy(&pipeline)

    enc_thread := thread.create(encoder_thread_proc)
    enc_thread.data = rawptr(&pipeline)
    thread.start(enc_thread)
    defer {
        pipeline_close(&pipeline)
        thread.join(enc_thread)
    }
    
    frames_done := 0
    start := time.tick_now()
    
    for fi in 0 ..< max_frames_actual {
        mem.zero_slice(canvas)
        
        n := loaded_n[fi]
        insts := loaded_insts[fi]
        
        // Pre-populate atlas cache for all tiles needed in this frame so the
        // blit loop encounters only cache hits (no repeated FFmpeg decode on
        // per-tile cache misses).
        if n > 0 && insts != nil {
            for i in 0 ..< n {
                if insts[i].op_id < 0 { continue }
                if int(insts[i].op_id) >= reg.n { continue }
                dw := int(insts[i].w)
                dh := int(insts[i].h)
                if dw <= 0 || dh <= 0 { continue }
                if atlas_lookup(&atlas, int(insts[i].op_id), dw, dh) != nil { continue }

                pdf_path := reg.entries[int(insts[i].op_id)].pdf_path
                page_idx := int(reg.entries[int(insts[i].op_id)].page_idx)

                src_img: Img
                if pdf_render_page(pdf_path, page_idx, 1.0, &src_img) != 0 { continue }

                scaled: Img
                scaled.w = dw
                scaled.h = dh
                scaled.channels = channels
                scaled.stride = dw * channels
                scaled.pixels = make([]u8, dw * dh * channels)

                if channels == 3 && src_img.channels == 3 {
                    img_resize_area(&src_img, &scaled, dw, dh)
                } else {
                    gray_needed := src_img.w * src_img.h
                    if gray_needed > gray_scratch_cap {
                        delete(gray_scratch)
                        gray_scratch = make([]u8, gray_needed)
                        gray_scratch_cap = gray_needed
                    }
                    gray_scratch_img.w = src_img.w
                    gray_scratch_img.h = src_img.h
                    gray_scratch_img.stride = src_img.w
                    gray_scratch_img.channels = 1
                    gray_scratch_img.pixels = gray_scratch[:gray_needed]
                    img_to_gray(&src_img, &gray_scratch_img)
                    img_resize_area(&gray_scratch_img, &scaled, dw, dh)
                }
                img_free(&src_img)
                atlas_insert(&atlas, int(insts[i].op_id), dw, dh, scaled.pixels, channels, scaled.stride)
                delete(scaled.pixels)
            }
        }

        if n > 0 && insts != nil {
            for i in 0 ..< n {
                if insts[i].op_id < 0 {
                    // Solid fill
                    val: u8 = 0
                    if insts[i].op_id == -2 { val = 255 }
                    sy0 := int(insts[i].y)
                    sx0 := int(insts[i].x)
                    for yy in 0 ..< int(insts[i].h) {
                        dst_y := sy0 + yy
                        if dst_y < 0 || dst_y >= height { continue }
                        fill_x := sx0
                        fill_w := int(insts[i].w)
                        if fill_x < 0 { fill_w += fill_x; fill_x = 0 }
                        if fill_x + fill_w > width { fill_w = width - fill_x }
                        if fill_w > 0 {
                            if channels == 3 {
                                mem.set(raw_data(canvas[(dst_y * width + fill_x) * 3 : (dst_y * width + fill_x + fill_w) * 3]), val, fill_w * 3)
                            } else {
                                                            mem.set(raw_data(canvas[dst_y * width + fill_x : dst_y * width + fill_x + fill_w]), val, fill_w)
                            }
                        }
                    }
                    continue
                }
                
                if int(insts[i].op_id) >= reg.n { continue }
                
                dw := int(insts[i].w)
                dh := int(insts[i].h)
                if dw <= 0 || dh <= 0 { continue }
                
                // Check atlas cache
                cached := atlas_lookup(&atlas, int(insts[i].op_id), dw, dh)
                
                tile_pixels: []u8 = nil
                tile_channels := channels
                tile_stride := dw * channels
                need_free := false
                
                if cached != nil {
                    tile_pixels = cached.pixels
                    tile_stride = cached.stride
                } else {
                    // Render source page (via pdf_render_page)
                    pdf_path := reg.entries[int(insts[i].op_id)].pdf_path
                    page_idx := int(reg.entries[int(insts[i].op_id)].page_idx)
                    
                    src_img: Img
                    if pdf_render_page(pdf_path, page_idx, 1.0, &src_img) != 0 { continue }
                    
                    // Scale to tile size
                    scaled: Img
                    scaled.w = dw
                    scaled.h = dh
                    scaled.channels = channels
                    scaled.stride = dw * channels
                    scaled.pixels = make([]u8, dw * dh * channels)
                    
                    if channels == 3 && src_img.channels == 3 {
                        img_resize_area(&src_img, &scaled, dw, dh)
                    } else {
                        gray_needed := src_img.w * src_img.h
                        if gray_needed > gray_scratch_cap {
                            delete(gray_scratch)
                            gray_scratch = make([]u8, gray_needed)
                            gray_scratch_cap = gray_needed
                        }
                        gray_scratch_img.w = src_img.w
                        gray_scratch_img.h = src_img.h
                        gray_scratch_img.stride = src_img.w
                        gray_scratch_img.channels = 1
                        gray_scratch_img.pixels = gray_scratch[:gray_needed]
                        img_to_gray(&src_img, &gray_scratch_img)
                        img_resize_area(&gray_scratch_img, &scaled, dw, dh)
                    }
                    img_free(&src_img)
                    
                    // Cache the tile
                    atlas_insert(&atlas, int(insts[i].op_id), dw, dh, scaled.pixels, channels, scaled.stride)
                    
                    tile_pixels = scaled.pixels
                    tile_stride = scaled.stride
                    need_free = true
                }
                
                // Blit to canvas
                sy0 := int(insts[i].y)
                sx0 := int(insts[i].x)
                for yy in 0 ..< dh {
                    dst_y := sy0 + yy
                    if dst_y < 0 || dst_y >= height { continue }
                    copy_x := sx0
                    copy_src_x := 0
                    copy_w := dw
                    if copy_x < 0 { copy_src_x = -copy_x; copy_w += copy_x; copy_x = 0 }
                    if copy_x + copy_w > width { copy_w = width - copy_x }
                    if copy_w > 0 {
                        copy_bytes := copy_w * tile_channels
                        canvas_off := (dst_y * width + copy_x) * channels
                        tile_off := yy * tile_stride + copy_src_x * tile_channels
                        if canvas_off + copy_bytes <= len(canvas) && tile_off + copy_bytes <= len(tile_pixels) {
                            copy(canvas[canvas_off:], tile_pixels[tile_off:])
                        }
                    }
                }
                
                if need_free { delete(tile_pixels) }
            }
        }
        
        frames_done += 1

        // Push frame to encode pipeline (non-blocking)
        pipeline_push(&pipeline, canvas)
        
        if !g_cli.quiet && frames_done % 30 == 0 {
            elapsed := time.duration_seconds(time.tick_since(start))
            fps_out := f64(frames_done) / max(elapsed, 0.001)
            cache_pct := 0.0
            if atlas.hits + atlas.misses > 0 {
                cache_pct = f64(atlas.hits) / f64(atlas.hits + atlas.misses) * 100.0
            }
            cli_progress_frame("render", frames_done, len(manifest_paths), fps_out, cache_pct)
        }
    }
    
    // Encoder is wired — output written via video_encoder_open/write/close above
    cli_info("rendered %d frames", frames_done)
    
    elapsed := time.duration_seconds(time.tick_since(start))
    fps_out := f64(frames_done) / max(elapsed, 0.001)
    cli_progress_done(fmt.tprintf("render complete in %.2fs | %.2f fps | %d frames", elapsed, fps_out, frames_done))
}
