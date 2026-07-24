package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import "core:strconv"

has_ext :: proc(path, ext: string) -> bool {
    if len(path) < len(ext) + 1 { return false }
    return strings.has_suffix(path, ext)
}

is_pdf_file :: proc(p: string) -> bool { return has_ext(p, ".pdf") }
is_img_file :: proc(p: string) -> bool {
    return has_ext(p, ".png") || has_ext(p, ".jpg") || has_ext(p, ".jpeg") ||
           has_ext(p, ".bmp") || has_ext(p, ".gif") || has_ext(p, ".tif") || has_ext(p, ".tiff")
}

Feat_Buf :: struct {
    data: []u8,
    n:    int,
}

feat_push :: proc(fb: ^Feat_Buf, feat: []u8) {
    old_len := len(fb.data)
    new_data := make([]u8, old_len + len(feat))
    if old_len > 0 { copy(new_data, fb.data); delete(fb.data) }
    copy(new_data[old_len:], feat)
    fb.data = new_data
    fb.n += 1
}

write_features :: proc(path: string, fb: ^Feat_Buf, nreg, feat_len, G, n_scales: int, scales: []int, has_edges, channels: int) {
    f, ferr := os.create(path)
    if ferr != os.ERROR_NONE { return }
    defer os.close(f)
    
    buf := make([]u8, 16 + n_scales * 4 + 4 + 4)
    defer delete(buf)
    
    (^u32)(&buf[0])^ = u32(nreg)
    (^u32)(&buf[4])^ = u32(feat_len)
    (^u32)(&buf[8])^ = u32(G)
    (^u32)(&buf[12])^ = u32(n_scales)
    off := 16
    for i in 0 ..< n_scales {
        (^u32)(&buf[off])^ = u32(scales[i])
        off += 4
    }
    (^u32)(&buf[off])^ = u32(has_edges)
    off += 4
    (^u32)(&buf[off])^ = u32(channels)
    
    os.write(f, buf)
    os.write(f, fb.data)
}

write_registry :: proc(path: string, paths: []string, page_idxs: []int, nreg: int) {
    f, ferr := os.create(path)
    if ferr != os.ERROR_NONE { return }
    defer os.close(f)
    
    header := make([]u8, 4)
    defer delete(header)
    (^u32)(&header[0])^ = u32(nreg)
    os.write(f, header)
    
    for i in 0 ..< nreg {
        entry_buf := make([]u8, 8 + len(paths[i]))
        defer delete(entry_buf)
        (^i32)(&entry_buf[0])^ = i32(page_idxs[i])
        (^u32)(&entry_buf[4])^ = u32(len(paths[i]))
        copy(entry_buf[8:], paths[i])
        os.write(f, entry_buf)
    }
}

build_main :: proc() {
    args := os.args
    src := ""
    if len(args) >= 2 {
        src = args[1]
    }
    
    if cli_has("help") || cli_has("h") || len(src) == 0 {
        cli_die("usage: badodin build <sources_dir> [--bits N] [--color] [--out file]")
    }
    
    G := cli_opt_int("bits", 1)
    has_edges := 0 if cli_has("no-edges") else 1
    color := 1 if cli_has("color") else 0
    feat_out := cli_opt_str("out", "features.bin")
    reg_out := "registry.bin"
    
    feat_scales := [3]int{32, 64, 128}
    n_feat_scales := 3
    
    if cli_has("scales") {
        sstr := cli_opt_str("scales", "32,64,128")
        n_feat_scales = 0
        parts := strings.split(sstr, ",")
        defer delete(parts)
        for p in parts {
            if n_feat_scales >= 16 { break }
            v, _ := strconv.parse_int(strings.trim_space(p))
            feat_scales[n_feat_scales] = v
            n_feat_scales += 1
        }
    }
    
    // Compute feature length
    feat_len := 0
    for i in 0 ..< n_feat_scales {
        N := feat_scales[i]
        feat_len += N * N
        if has_edges != 0 { feat_len += N * N }
        if color != 0 { feat_len += N * N * 3 }
    }
    
    // Scan directory
    dir_handle, ok := os.open(src)
    if !ok { return }
    defer os.close(dir_handle)
    
    paths: [dynamic]string
    page_idxs: [dynamic]int
    defer {
        for p in paths { delete(p) }
        delete(paths)
        delete(page_idxs)
    }
    
    fb: Feat_Buf
    defer delete(fb.data)
    
    total_sources := 0
    entries, dir_err := os.read_dir(dir_handle)
    if dir_err != nil { os.close(dir_handle); return }
    for entry in entries {
        if entry.name[0] == '.' { continue }
        full := fmt.tprintf("%s/%s", src, entry.name)
        if is_pdf_file(full) || is_img_file(full) {
            total_sources += 1
        }
    }
    
    if total_sources == 0 {
        cli_die("no sources found in: %s", src)
    }
    
    cli_info("sources: %d | G=%d edges=%d color=%d | feat_len=%d",
             total_sources, G, has_edges, color, feat_len)
    
    // Re-scan and process
    dir_handle2, ok := os.open(src)
    if !ok { return }
    defer os.close(dir_handle2)
    
    processed := 0
    entries2, dir_err2 := os.read_dir(dir_handle2)
    if dir_err2 != nil { os.close(dir_handle2); return }
    for entry in entries2 {
        if entry.name[0] == '.' { continue }
        full := fmt.tprintf("%s/%s", src, entry.name)
        
        if is_img_file(full) {
            img: Img
            if video_image_load(full, &img) != 0 { continue }
            
            feat := make([]u8, feat_len)
            img_compute_feature_multires(&img, feat_scales[:n_feat_scales], G, has_edges, color, feat)
            feat_push(&fb, feat)
            delete(feat)
            
            append(&paths, strings.clone(full))
            append(&page_idxs, -1)
            img_free(&img)
            processed += 1
        }
        // PDF processing would require mupdf - skip for now
    }
    
    if len(paths) == 0 {
        cli_die("no sources processed")
    }
    
    // Write outputs
    channels_val := 3 if color != 0 else 1
    write_features(feat_out, &fb, len(paths), feat_len, G, n_feat_scales, feat_scales[:n_feat_scales], has_edges, channels_val)
    write_registry(reg_out, paths[:], page_idxs[:], len(paths))
    
    cli_info("output: %s (%d entries, %d bytes/feature)", feat_out, len(paths), feat_len)
    cli_info("registry: %s (%d entries)", reg_out, len(paths))
}
