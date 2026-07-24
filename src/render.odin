package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import "core:math"

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
    h ^= u32(tw) * 374761393
    h ^= u32(th) * 668265263
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
                     src_pixels[y * src_stride:], row_bytes)
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

// ── Manifest loading ──
load_manifest :: proc(path: string, out_insts: ^[^]Inst, out_n: ^int, target_w, target_h: int) -> int {
    data, ok := os.read_entire_file_from_path(path)
    if !ok { return -1 }
    defer delete(data)
    
    if len(data) < 12 { return -1 }
    
    src_w := int(*(*u32)(&data[0]))
    src_h := int(*(*u32)(&data[4]))
    n := int(*(*u32)(&data[8]))
    if n > MAX_INSTS { return -1 }
    
    // Compute scale
    scale: f64 = 1.0
    ox, oy: f64 = 0.0
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
        bx := *(*i32)(&data[off])
        by := *(*i32)(&data[off + 4])
        bw := *(*i32)(&data[off + 8])
        bh := *(*i32)(&data[off + 12])
        op_id := *(*i32)(&data[off + 16])
        page_idx := *(*i32)(&data[off + 20])
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
    dir_handle, ok := os.open(man_dir)
    if !ok { return }
    defer os.close(dir_handle)
    
    manifest_paths: [dynamic]string
    defer delete(manifest_paths)
    
    for entry in os.read_dir(dir_handle) {
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
    
    // TODO: Sort manifest paths by frame number
    
    // Auto-detect dimensions from first manifest
    if width <= 0 && height <= 0 {
        tmp_insts: ^Inst
        tmp_n: int
        if load_manifest(manifest_paths[0], &tmp_insts, &tmp_n, 99999, 99999) == 0 {
            // Read src_w/src_h from raw file instead
            data, data_ok := os.read_entire_file_from_path(manifest_paths[0])
            if data_ok && len(data) >= 8 {
                width = int(*(*u32)(&data[0]))
                height = int(*(*u32)(&data[4]))
            }
            if data_ok { delete(data) }
            delete(tmp_insts)
        }
    }
    if width <= 0 { width = 7680 }
    if height <= 0 { height = 4320 }
    
    // Auto-detect fps from sidecar
    if fps_val <= 0.0 {
        fps_path := fmt.tprintf("%s/fps.bin", man_dir)
        fps_data, fps_ok := os.read_entire_file_from_path(fps_path)
        if fps_ok {
            if len(fps_data) >= 8 {
                fps_val = *(*f64)(&fps_data[0])
            }
            delete(fps_data)
        }
    }
    if fps_val <= 0.0 { fps_val = 30.0 }
    
    mode_str := "(color)" if channels == 3 else "(grayscale)"
    cli_info("render: %d frames %dx%d %s %.1f fps -> %s", len(manifest_paths), width, height, mode_str, fps_val, output)
    
    // Pre-load all manifests
    loaded_insts := make([]^Inst, len(manifest_paths))
    loaded_n := make([]int, len(manifest_paths))
    defer {
        for i in 0 ..< len(manifest_paths) {
            if loaded_insts[i] != nil { delete(loaded_insts[i]) }
            delete(manifest_paths[i])
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
    
    // Process frames
    max_frames_actual := len(manifest_paths)
    if max_frames > 0 && max_frames < max_frames_actual { max_frames_actual = max_frames }
    
    frames_done := 0
    start := time.ticks()
    
    for fi in 0 ..< max_frames_actual {
        mem.clear(canvas)
        
        n := loaded_n[fi]
        insts := loaded_insts[fi]
        
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
                                for px in 0 ..< fill_w {
                                    off := (dst_y * width + fill_x + px) * 3
                                    canvas[off] = val
                                    canvas[off+1] = val
                                    canvas[off+2] = val
                                }
                            } else {
                                mem.clear(canvas[dst_y * width + fill_x:])
                                canvas[dst_y * width + fill_x] = val
                                // Actually need fill_w bytes
                                for px in 0 ..< fill_w { canvas[dst_y * width + fill_x + px] = val }
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
                        gray_img: Img
                        gray_img.w = src_img.w
                        gray_img.h = src_img.h
                        gray_img.stride = src_img.w
                        gray_img.channels = 1
                        gray_img.pixels = make([]u8, src_img.w * src_img.h)
                        img_to_gray(&src_img, &gray_img)
                        img_resize_area(&gray_img, &scaled, dw, dh)
                        delete(gray_img.pixels)
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
                            copy(canvas[canvas_off:], tile_pixels[tile_off:], copy_bytes)
                        }
                    }
                }
                
                if need_free { delete(tile_pixels) }
            }
        }
        
        frames_done += 1
        if !g_cli.quiet && frames_done % 30 == 0 {
            elapsed := f64(time.ticks() - start) / f64(time.SECOND)
            fps_out := f64(frames_done) / max(elapsed, 0.001)
            cache_pct := 0.0
            if atlas.hits + atlas.misses > 0 {
                cache_pct = f64(atlas.hits) / f64(atlas.hits + atlas.misses) * 100.0
            }
            cli_progress_frame("render", frames_done, len(manifest_paths), fps_out, cache_pct)
        }
    }
    
    // TODO: Encode canvas frames to output video via video_encoder_open/write/close
    cli_info("rendered %d frames (encode not yet wired)", frames_done)
    
    elapsed := f64(time.ticks() - start) / f64(time.SECOND)
    fps_out := f64(frames_done) / max(elapsed, 0.001)
    cli_progress_done(fmt.tprintf("render complete in %.2fs | %.2f fps | %d frames", elapsed, fps_out, frames_done))
}
