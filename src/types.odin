package main

// ── Core image type ──
// A simple RGB/BGR image buffer (what libav/mupdf produce and the solver consumes).
Img :: struct {
	w, h:         int,
	stride:       int,         // bytes per row
	pixels:       []u8,        // contiguous w*h*3 BGR (or w*h gray if channels==1)
	channels:     int,         // 1 or 3
}

img_free :: proc(im: ^Img) {
	if len(im.pixels) > 0 {
		delete(im.pixels)
	}
	im.pixels = nil
	im.w, im.h = 0, 0
}

// ── Feature database (features.bin) ──
FeatureDB :: struct {
	n_pages:    int,
	feat_len:   int,        // total bytes per feature (sum of all scale levels)
	G:          int,        // bits per cell (1..8)
	n_scales:   int,        // number of scale levels
	scales:     [16]int,    // grid sizes per level (e.g., {32, 64, 128})
	has_edges:  int,        // 1 if edge features included per scale
	channels:   int,        // 1 = grayscale features, 3 = color features
	data:       []u8,       // n_pages * feat_len bytes
}

// ── Registry (registry.bin) ──
RegEntry :: struct {
	pdf_path:   string,
	page_idx:   i32,
}

Registry :: struct {
	n:          int,
	entries:    [dynamic]RegEntry,
}

// ── Manifest instruction ──
// A single instruction in the manifest: tells render where to blit what.
Inst :: struct {
	x, y, w, h: i32,
	op_id:      i32,   // -1=solid black, -2=solid white, >=0=registry index
	page_idx:   i32,
}

// ── Tile specification (used during arrange) ──
TileSpec :: struct {
	x, y, w, h: int,
	manifest_idx: int,
}

// ── System configuration ──
SystemConfig :: struct {
	total_memory_bytes: u64,
	cpu_cores:          int,
	num_threads:        int,
	cache_budget_bytes: u64,
	cache_enabled:      bool,
}

// ── Timings ──
Timings :: struct {
	read, gray, solve, feat, match, write: f64,
	tiles, hits:                           int,
}
