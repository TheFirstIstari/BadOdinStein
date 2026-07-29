package main

// pdf_render_page renders a PDF page or loads an image file.
// For non-PDF files, loads via video_image_load (libav).
// For PDF files, would use mupdf (stub: returns error for now).
// scale: zoom factor (1.0 = original size)
pdf_render_page :: proc(path: string, page_idx: int, scale: f32, out: ^Img) -> int {
    // Check if PDF
    if has_pdf_ext(path) {
        // Without mupdf, we can't render PDFs
        // TODO: Add mupdf FFI for PDF rendering
        return -1
    }
    
    // Load as image via libav
    rc := video_image_load(path, out)
    if rc != 0 { return rc }
    
    // Upscale by scale factor if needed
    if scale > 1.0 && out.w > 0 && out.h > 0 {
        nw := int(f32(out.w) * scale + 0.5)
        nh := int(f32(out.h) * scale + 0.5)
        if nw > 0 && nh > 0 {
            upscaled: Img
            upscaled.w = nw
            upscaled.h = nh
            upscaled.channels = out.channels
            upscaled.stride = nw * out.channels
            upscaled.pixels = make([]u8, nw * nh * out.channels)
            img_resize_area(out, &upscaled, nw, nh)
            img_free(out)
            out^ = upscaled
        }
    }
    
    return 0
}

has_pdf_ext :: proc(path: string) -> bool {
    if len(path) < 4 { return false }
    // Case-insensitive .pdf check
    end := path[len(path)-4:]
    return (end[0] == '.') &&
           (end[1] == 'p' || end[1] == 'P') &&
           (end[2] == 'd' || end[2] == 'D') &&
           (end[3] == 'f' || end[3] == 'F')
}
