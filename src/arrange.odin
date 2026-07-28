package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import "core:time"
import "core:math"
import "core:simd"

CELL :: 8
CACHE_PROBE_MAX :: 32

Cache_Slot :: struct {
	hash: u64,
	pid:  i32,
}

fnv1a_64 :: proc(data: []u8) -> u64 {
	h: u64 = 14695981039346656037
	for b in data {
		h ~= u64(b)
		h *= 1099511628211
	}
	return h | 1
}

full_feat_hash :: proc(feat: []u8, feat_len: int) -> u64 {
	h: u64 = 14695981039346656037
	n := min(feat_len, 64)
	step := max(feat_len / n, 1)
	for i in 0 ..< n {
		h ~= u64(feat[i * step])
		h *= 1099511628211
	}
	return h | 1
}

cache_lookup :: proc(tab: []Cache_Slot, cap: int, h: u64) -> (bool, i32) {
	if cap == 0 { return false, -1 }
	mask := u64(cap - 1)
	idx := u64(h) & mask
	for _ in 0 ..< min(CACHE_PROBE_MAX, cap) {
		if tab[idx].hash == 0 { return false, -1 }
		if tab[idx].hash == h { return true, tab[idx].pid }
		idx = (idx + 1) & mask
	}
	return false, -1
}

cache_grow :: proc(tab: ^[]Cache_Slot, cap: ^int) {
	ncap := 2048
	if cap^ > 0 { ncap = cap^ * 2 }
	nt := make([]Cache_Slot, ncap)
	if len(tab^) > 0 {
		mask := u64(ncap - 1)
		for i in 0 ..< cap^ {
			if tab^[i].hash != 0 {
				idx := u64(tab^[i].hash) & mask
				for nt[idx].hash != 0 { idx = (idx + 1) & mask }
				nt[idx] = tab^[i]
			}
		}
		delete(tab^)
	}
	tab^ = nt
	cap^ = ncap
}

cache_put :: proc(tab: ^[]Cache_Slot, cap, n: ^int, h: u64, pid: i32) {
	if n^ + 1 > cap^ * 3 / 4 {
		cache_grow(tab, cap)
	}
	mask := u64(cap^ - 1)
	idx := u64(h) & mask
	for tab^[idx].hash != 0 { idx = (idx + 1) & mask }
	tab^[idx].hash = h
	tab^[idx].pid = pid
	n^ += 1
}

Arrange_State :: struct {
	g_G, g_has_edges, g_feat_len: int,
	g_scales: [16]int,
	g_n_scales: int,
	g_max_block_pct, g_hero_min_pct: f64,
	ccache: []Cache_Slot,
	ccache_cap, ccache_n: int,
	fcache: []Cache_Slot,
	fcache_cap, fcache_n: int,
	sum:      []i64,
	visited:  []u8,
	specs:    []TileSpec,
	coarse_hit: []int,
	crop_bufs: []u8,
	miss_idx:  []int,
	results:   []int,
	cap_w, cap_h: int,
	spec_cap, coarse_cap, miss_cap, result_cap: int,
	crop_cap: int,
}

arrange_init :: proc(s: ^Arrange_State) {
	s.g_G = 1
	s.g_has_edges = 1
	s.g_n_scales = 3
	s.g_scales[0] = 32
	s.g_scales[1] = 64
	s.g_scales[2] = 128
	s.g_max_block_pct = 0.5
	s.g_hero_min_pct = 0.0833
}

arrange_cleanup :: proc(s: ^Arrange_State) {
	delete(s.ccache)
	delete(s.fcache)
	delete(s.sum)
	delete(s.visited)
	delete(s.specs)
	delete(s.coarse_hit)
	delete(s.crop_bufs)
	delete(s.miss_idx)
	delete(s.results)
}

// ── Shared coarse average (N×N grid) ──────────────────────────────
coarse_average :: proc(crop: []u8, sw, sh, N, channels, G, maxv: int, coarse_out: []u8) {
	for dy in 0 ..< N {
		sy0 := dy * sh / N
		sy1 := min((dy + 1) * sh / N, sh)
		for dx in 0 ..< N {
			sx0 := dx * sw / N
			sx1 := min((dx + 1) * sw / N, sw)
			psum: u64 = 0
			for sy in sy0 ..< sy1 {
				for sx in sx0 ..< sx1 {
					if channels == 3 {
						poff := sy * sw * 3 + sx * 3
						psum += u64((29 * u32(crop[poff+0]) + 150 * u32(crop[poff+1]) + 77 * u32(crop[poff+2])) >> 8)
					} else {
						psum += u64(crop[sy * sw + sx])
					}
				}
			}
			area := (sy1 - sy0) * (sx1 - sx0)
			v := int(psum / u64(area)) if area > 0 else 0
			q := v if G >= 8 else (v * maxv + 127) / 255
			if q > maxv { q = maxv }
			coarse_out[dy * N + dx] = u8(q)
		}
	}
}

crop_copy_color :: proc(my_crop: []u8, color_pixels: []u8, color_stride: int, sp_x, sp_y, sp_w, sp_h: int) {
	for yy in 0 ..< sp_h {
		src_off := (sp_y + yy) * color_stride + sp_x * 3
		dst_off := yy * sp_w * 3
		copy(my_crop[dst_off:], color_pixels[src_off:src_off + sp_w * 3])
	}
}

crop_copy_gray :: proc(my_crop: []u8, gray: []u8, gray_width, sp_x, sp_y, sp_w, sp_h: int) {
	for yy in 0 ..< sp_h {
		src_off := (sp_y + yy) * gray_width + sp_x
		copy(my_crop[yy * sp_w:], gray[src_off:src_off + sp_w])
	}
}

load_features :: proc(path: string, db: ^FeatureDB) -> int {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return -1 }
	defer delete(data)

	if len(data) < 24 { return -1 }
	buf := data

	n := (^u32)(&buf[0])^
	feat_len := (^u32)(&buf[4])^
	G := (^u32)(&buf[8])^
	n_scales := (^u32)(&buf[12])^

	if G == 0 || G > 8 || n_scales == 0 || n_scales > 16 { return -1 }

	header_len := 16 + int(n_scales) * 4 + 4
	if len(data) < header_len { return -1 }

	for i in 0 ..< int(n_scales) {
		s := (^u32)(&buf[16 + i * 4])^
		if s == 0 || s > 256 { return -1 }
		db.scales[i] = int(s)
	}

	has_edges := (^u32)(&buf[16 + int(n_scales) * 4])^

	gray_feat_len: u64 = 0
	for i in 0 ..< int(n_scales) {
		gray_feat_len += u64(db.scales[i] * db.scales[i])
	}
	gray_mult: u64 = 2 if has_edges != 0 else 1
	edge_mult: u64 = 1 if has_edges != 0 else 0
	expected_gray := gray_feat_len * gray_mult
	expected_color := gray_feat_len * (1 + edge_mult + 3)

	detected_channels := 0
	if u64(feat_len) == expected_gray {
		detected_channels = 1
	} else if u64(feat_len) == expected_color {
		detected_channels = 3
		if len(data) >= header_len + 4 {
			ch := (^u32)(&buf[header_len])^
			if ch == 3 { header_len += 4 }
		}
	} else {
		return -1
	}

	if len(data) < header_len { return -1 }
	if u64(n) * u64(feat_len) > 1 << 40 { return -1 }

	need := header_len + int(n) * int(feat_len)
	if need < header_len || need > len(data) { return -1 }

	db.n_pages = int(n)
	db.feat_len = int(feat_len)
	db.G = int(G)
	db.n_scales = int(n_scales)
	db.has_edges = int(has_edges)
	db.channels = detected_channels
	db.data = make([]u8, need - header_len)
	copy(db.data, buf[header_len:])

	return 0
}

load_registry :: proc(path: string, reg: ^Registry) -> int {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return -1 }
	defer delete(data)

	if len(data) < 4 { return -1 }
	buf := data
	n := (^u32)(&buf[0])^
	if u32(n) > u32(len(data)) / 5 { return -1 }

	off := 4
	for i in 0 ..< int(n) {
		if off + 8 > len(data) { return -1 }
		page_idx := (^i32)(&buf[off])^
		off += 4
		plen := (^u32)(&buf[off])^
		off += 4
		if page_idx < 0 { return -1 }
		if off + int(plen) > len(data) { return -1 }
		entry: RegEntry
		entry.pdf_path = strings.clone(string(buf[off:off + int(plen)]))
		entry.page_idx = page_idx
		off += int(plen)
		append(&reg.entries, entry)
	}
	reg.n = len(reg.entries)
	return 0
}

write_manifest :: proc(path: string, fw, fh: int, manifest: []Inst, n: int) {
	total := 3 * 4 + n * 6 * 4
	mbuf := make([]u8, total)
	defer delete(mbuf)

	(^u32)(&mbuf[0])^ = u32(fw)
	(^u32)(&mbuf[4])^ = u32(fh)
	(^u32)(&mbuf[8])^ = u32(n)

	rp := 12
	for k in 0 ..< n {
		(^i32)(&mbuf[rp + 0])^  = manifest[k].x
		(^i32)(&mbuf[rp + 4])^  = manifest[k].y
		(^i32)(&mbuf[rp + 8])^  = manifest[k].w
		(^i32)(&mbuf[rp + 12])^ = manifest[k].h
		(^i32)(&mbuf[rp + 16])^ = manifest[k].op_id
		(^i32)(&mbuf[rp + 20])^ = manifest[k].page_idx
		rp += 24
	}

	f, ferr := os.create(path)
	if ferr != nil { return }
	defer os.close(f)
	os.write(f, mbuf)
}

// Thread pool task for parallel feature extraction
Feat_Work :: struct {
	specs:        []TileSpec,
	gray:         []u8,
	gray_width:   int,
	color_pixels: []u8,
	color_stride: int,
	channels:     int,
	feat_len:     int,
	N:            int,
	G:            int,
	has_edges:    int,
	maxv:         int,
	ch_mult:      int,
	spec_start:   int,
	spec_end:     int,
	db_data:      []u8,
	n_pages:      int,
	coarse_len:   int,
	scales:       []int,
	n_scales:     int,
	// Per-thread buffers (allocated once per thread)
	crop_buf:     []u8,
	coarse_feat:  []u8,
	feat_bufs:    Feature_Buffers,
	// Shared output arrays (each thread writes to distinct indices)
	coarse_hit:   []int,
	out_feat_bufs: []u8,
	// Cache (read-only during parallel phase)
	ccache:       []Cache_Slot,
	ccache_cap:   int,
}

feat_thread_proc :: proc(data: rawptr) {
	w := cast(^Feat_Work)data

	for i in w.spec_start ..< w.spec_end {
		sp := w.specs[i]
		my_crop := w.crop_buf[:sp.w * sp.h * w.ch_mult]

		if w.channels == 3 {
			crop_copy_color(my_crop, w.color_pixels, w.color_stride, sp.x, sp.y, sp.w, sp.h)
		} else {
			crop_copy_gray(my_crop, w.gray, w.gray_width, sp.x, sp.y, sp.w, sp.h)
		}

		// Compute coarse feature (N×N average)
		coarse_average(my_crop, sp.w, sp.h, w.N, w.channels, w.G, w.maxv, w.coarse_feat)

		// Check coarse cache (read-only)
		ch := fnv1a_64(w.coarse_feat)
		found, pid := cache_lookup(w.ccache, w.ccache_cap, ch)
		if found {
			w.coarse_hit[i] = int(pid)
			continue
		}

		// Compute full feature using pre-allocated buffers
		crop_img := Img{w = sp.w, h = sp.h, stride = sp.w * w.channels, pixels = my_crop, channels = w.channels}
		out_slice := w.out_feat_bufs[i * w.feat_len:]
		feature_ch: int = 1 if w.channels == 3 else 0
		img_compute_feature_multires(&crop_img, w.scales[:w.n_scales], w.G, w.has_edges, feature_ch, out_slice, &w.feat_bufs)
	}
}

solve_full :: proc(s: ^Arrange_State, gray, color_pixels: []u8, color_stride, color_channels, w, h: int,
                   db: ^FeatureDB, reg: ^Registry, pid_white, pid_black, max_block, hero_min: int,
                   manifest: []Inst, nout: ^int, tiles: []u8, ntiles: ^int, t: ^Timings, pool: ^ThreadPool) {
	CELL_SIZE :: 8

	if s.cap_w < w || s.cap_h < h {
		s.cap_w = w
		s.cap_h = h
		s.sum = make([]i64, (w + 1) * (h + 1))
		s.visited = make([]u8, ((h + 7) / 8) * ((w + 7) / 8))
	}
	sum_stride := w + 1

	mem.zero_slice(s.sum)
	for y in 0 ..< h {
		row_sum: i64 = 0
		for x in 0 ..< w {
			val: i64 = 1 if gray[y * w + x] > 127 else 0
			row_sum += val
			s.sum[(y + 1) * sum_stride + (x + 1)] = row_sum + s.sum[y * sum_stride + (x + 1)]
		}
	}

	gh := (h + CELL_SIZE - 1) / CELL_SIZE
	gw := (w + CELL_SIZE - 1) / CELL_SIZE
	mem.zero_slice(s.visited[:gh * gw])

	feat_len := db.feat_len
	max_cells := max_block / CELL_SIZE
	n: int = 0
	nt: int = 0
	n_specs: int = 0
	spec_cap := max(512, len(s.specs))

	if len(s.specs) < spec_cap {
		s.specs = make([]TileSpec, spec_cap)
	}

	t0 := time.tick_now()

	for cy in 0 ..< gh {
		y := cy * CELL_SIZE
		row := s.visited[cy * gw:]
		for cx in 0 ..< gw {
			x := cx * CELL_SIZE
			if row[cx] != 0 { continue }

			cell_color := 1 if gray[y * w + x] > 127 else 0
			mcw, mch := 1, 1

			for cx + mcw + 1 <= gw && mcw + 1 <= max_cells {
				any_visited := false
				for yy in cy ..< cy + mch {
					if s.visited[yy * gw + (cx + mcw)] != 0 {
						any_visited = true
						break
					}
				}
				if any_visited { break }

				x0 := cx * CELL_SIZE
				y0 := cy * CELL_SIZE
				x1 := min((cx + mcw + 1) * CELL_SIZE, w)
				y1 := min((cy + mch) * CELL_SIZE, h)
				cnt := s.sum[y1 * sum_stride + x1] - s.sum[y0 * sum_stride + x1] -
				       s.sum[y1 * sum_stride + x0] + s.sum[y0 * sum_stride + x0]
				area := (x1 - x0) * (y1 - y0)
				pure := (cnt == i64(area)) if cell_color == 1 else (cnt == 0)
				if pure { mcw += 1 } else { break }
			}

			for cy + mch + 1 <= gh && mch + 1 <= max_cells {
				any_visited := false
				next_row_off := (cy + mch) * gw
				for xx in cx ..< cx + mcw {
					if s.visited[next_row_off + xx] != 0 {
						any_visited = true
						break
					}
				}
				if any_visited { break }

				x0 := cx * CELL_SIZE
				y0 := cy * CELL_SIZE
				x1 := min((cx + mcw) * CELL_SIZE, w)
				y1 := min((cy + mch + 1) * CELL_SIZE, h)
				cnt := s.sum[y1 * sum_stride + x1] - s.sum[y0 * sum_stride + x1] -
				       s.sum[y1 * sum_stride + x0] + s.sum[y0 * sum_stride + x0]
				area := (x1 - x0) * (y1 - y0)
				pure := (cnt == i64(area)) if cell_color == 1 else (cnt == 0)
				if pure { mch += 1 } else { break }
			}

			mw := mcw * CELL_SIZE
			mh := mch * CELL_SIZE
			if x + mw > w { mw = w - x }
			if y + mh > h { mh = h - y }

			for ccy in cy ..< cy + mch {
				base := ccy * gw
				for ccx in cx ..< cx + mcw {
					s.visited[base + ccx] = 1
				}
			}

			if mw >= hero_min && mh >= hero_min {
				solid_op: i32 = -2 if cell_color == 1 else -1
				manifest[n] = Inst{i32(x), i32(y), i32(mw), i32(mh), solid_op, -1}
				n += 1
			} else {
				if n_specs >= spec_cap {
					spec_cap *= 2
					new_specs := make([]TileSpec, spec_cap)
					copy(new_specs, s.specs[:n_specs])
					delete(s.specs)
					s.specs = new_specs
				}
				s.specs[n_specs] = TileSpec{x, y, mw, mh, n}
				n_specs += 1
				manifest[n] = Inst{i32(x), i32(y), i32(mw), i32(mh), -1, -1}
				n += 1
			}
		}
	}

	match_block: {
		if n_specs > 0 {
			coarse_len := s.g_scales[0] * s.g_scales[0]

			if n_specs > s.coarse_cap {
				s.coarse_hit = make([]int, n_specs)
				s.coarse_cap = n_specs
			}
			for i in 0 ..< n_specs { s.coarse_hit[i] = -1 }

			ch_mult: int = 3 if db.channels == 3 else 1
			crop_sz := max_block * max_block * ch_mult
			if crop_sz > s.crop_cap {
				s.crop_bufs = make([]u8, crop_sz)
				s.crop_cap = crop_sz
			}

			feat_bufs := make([]u8, n_specs * feat_len)
			defer delete(feat_bufs)

			tf := time.tick_now()

			N := s.g_scales[0]
			maxv := (1 << u32(db.G)) - 1

			// Parallel feature extraction using thread pool
			num_cores := os.get_processor_core_count()
			if num_cores <= 0 { num_cores = 1 }
			num_feat_threads := min(num_cores, n_specs / 32)

			if num_feat_threads > 1 {
				specs_per_thread := n_specs / num_feat_threads
				feat_work := make([]Feat_Work, num_feat_threads)

				for ti in 0 ..< num_feat_threads {
					start := ti * specs_per_thread
					end := start + specs_per_thread
					if ti == num_feat_threads - 1 {
						end = n_specs
					}

					// Each thread gets its own crop buffer, coarse_feat buffer, and feature buffers
					thread_crop := make([]u8, crop_sz)
					thread_coarse := make([]u8, N * N)
					thread_feat_bufs := feature_bufs_init(max_block, crop_sz)

					feat_work[ti] = Feat_Work {
						specs = s.specs[:n_specs],
						gray = gray,
						gray_width = w,
						color_pixels = color_pixels,
						color_stride = color_stride,
						channels = db.channels,
						feat_len = feat_len,
						N = N,
						G = db.G,
						has_edges = db.has_edges,
						maxv = maxv,
						ch_mult = ch_mult,
						spec_start = start,
						spec_end = end,
						db_data = db.data,
						n_pages = db.n_pages,
						coarse_len = coarse_len,
						scales = s.g_scales[:s.g_n_scales],
						n_scales = s.g_n_scales,
						crop_buf = thread_crop,
						coarse_feat = thread_coarse,
						feat_bufs = thread_feat_bufs,
						coarse_hit = s.coarse_hit,
						out_feat_bufs = feat_bufs,
						ccache = s.ccache,
						ccache_cap = s.ccache_cap,
					}

					thread_pool_submit(pool, feat_thread_proc, &feat_work[ti])
				}

				// Wait for all feature extraction threads to finish
				thread_pool_wait(pool)

				for ti in 0 ..< num_feat_threads {
					delete(feat_work[ti].crop_buf)
					delete(feat_work[ti].coarse_feat)
					feature_bufs_cleanup(&feat_work[ti].feat_bufs)
				}

				delete(feat_work)
			} else {
				// Single-threaded fallback
				coarse_feat := make([]u8, N * N)
				defer delete(coarse_feat)
				local_feat_bufs := feature_bufs_init(max_block, crop_sz)
				defer feature_bufs_cleanup(&local_feat_bufs)

				for i in 0 ..< n_specs {
					sp := s.specs[i]
					my_crop := s.crop_bufs[:sp.w * sp.h * ch_mult]

					if db.channels == 3 {
						crop_copy_color(my_crop, color_pixels, color_stride, sp.x, sp.y, sp.w, sp.h)
					} else {
						crop_copy_gray(my_crop, gray, w, sp.x, sp.y, sp.w, sp.h)
					}

					coarse_average(my_crop, sp.w, sp.h, N, db.channels, db.G, maxv, coarse_feat)

					ch := fnv1a_64(coarse_feat)
					found, pid := cache_lookup(s.ccache, s.ccache_cap, ch)
					if found {
						s.coarse_hit[i] = int(pid)
						continue
					}

					crop_img := Img{w = sp.w, h = sp.h, stride = sp.w * db.channels, pixels = my_crop, channels = db.channels}
					out_slice := feat_bufs[i * feat_len:]
					feature_ch: int = 1 if db.channels == 3 else 0
					img_compute_feature_multires(&crop_img, s.g_scales[:s.g_n_scales], db.G, db.has_edges, feature_ch, out_slice, &local_feat_bufs)
				}
			}

			for i in 0 ..< n_specs {
				if s.coarse_hit[i] >= 0 {
					t.hits += 1
					midx := s.specs[i].manifest_idx
					manifest[midx].op_id = i32(s.coarse_hit[i])
					manifest[midx].page_idx = reg.entries[s.coarse_hit[i]].page_idx
				}
			}
			t.feat += time.duration_seconds(time.tick_since(tf))

			if n_specs > s.miss_cap {
				s.miss_idx = make([]int, n_specs)
				s.miss_cap = n_specs
			}
			nt = 0
			for i in 0 ..< n_specs {
				if s.coarse_hit[i] >= 0 { continue }
				feat := feat_bufs[i * feat_len :]
				h := full_feat_hash(feat, feat_len)
				found, pid := cache_lookup(s.fcache, s.fcache_cap, h)
				if found {
					t.hits += 1
					midx := s.specs[i].manifest_idx
					manifest[midx].op_id = pid
					manifest[midx].page_idx = reg.entries[pid].page_idx
				} else {
					s.miss_idx[nt] = i
					copy(tiles[nt * feat_len:], feat[:feat_len])
					nt += 1
				}
			}

			if nt > 0 {
				tm := time.tick_now()
				if nt > s.result_cap {
					s.results = make([]int, nt)
					s.result_cap = nt
				}
				match_batch_coarse(db.data, tiles[:nt * feat_len], db.n_pages, nt, feat_len, coarse_len, s.results[:nt], pool)
				for i in 0 ..< nt {
					pid := s.results[i]
					midx := s.specs[s.miss_idx[i]].manifest_idx
					manifest[midx].op_id = i32(pid)
					manifest[midx].page_idx = reg.entries[pid].page_idx
					feat := tiles[i * feat_len :]
					fh := full_feat_hash(feat, feat_len)
					cache_put(&s.fcache, &s.fcache_cap, &s.fcache_n, fh, i32(pid))
					ch := fnv1a_64(feat[:coarse_len])
					cache_put(&s.ccache, &s.ccache_cap, &s.ccache_n, ch, i32(pid))
				}
				t.match += time.duration_seconds(time.tick_since(tm))
				t.tiles += nt
			}
		}
	}

	t.solve += time.duration_seconds(time.tick_since(t0))
	nout^ = n
	ntiles^ = nt
}

arrange_main :: proc() {
	state: Arrange_State
	arrange_init(&state)
	defer arrange_cleanup(&state)

	num_cores := os.get_processor_core_count()
	if num_cores <= 0 { num_cores = 1 }
	num_threads := min(num_cores, 64)
	pool := thread_pool_create(num_threads)
	defer thread_pool_destroy(pool)

	video_path := cli_opt_str("video", "")
	feat_path := cli_opt_str("features", "features.bin")
	reg_path := cli_opt_str("registry", "registry.bin")
	man_dir := cli_opt_str("manifests", "manifests_greedy")
	max_frames := cli_opt_int("max-frames", 0)
	if cli_has("max-block-pct") { state.g_max_block_pct = cli_opt_f64("max-block-pct", 0.5) }
	if cli_has("hero-min-pct") { state.g_hero_min_pct = cli_opt_f64("hero-min-pct", 0.0625) }

	db: FeatureDB
	defer delete(db.data)
	reg: Registry
	defer {
		for e in reg.entries { delete(e.pdf_path) }
		delete(reg.entries)
	}

	if len(video_path) == 0 { cli_die("arrange requires --video <file>") }
	if load_features(feat_path, &db) != 0 { cli_die("cannot load features: %s", feat_path) }
	if load_registry(reg_path, &reg) != 0 { cli_die("cannot load registry: %s", reg_path) }

	state.g_G = db.G
	state.g_feat_len = db.feat_len
	state.g_n_scales = db.n_scales
	for i in 0 ..< db.n_scales { state.g_scales[i] = db.scales[i] }
	state.g_has_edges = db.has_edges

	cli_info("library: %d pages | scales=%d G=%d edges=%d | feat_len=%d",
	         db.n_pages, state.g_n_scales, state.g_G, state.g_has_edges, db.feat_len)

	dec := video_decoder_open(video_path)
	if dec == nil { cli_die("cannot open video: %s", video_path) }
	defer video_decoder_close(dec)

	fw, fh := dec.width, dec.height
	source_fps := dec.fps
	cli_info("video: %dx%d | fps=%.1f", fw, fh, source_fps)

	hero_feat_len := state.g_scales[0] * state.g_scales[0]
	pid_white, pid_black: int
	mx, mn: f64 = -1, 256
	for i in 0 ..< db.n_pages {
		s: f64 = 0
		f := db.data[i * db.feat_len:]
		for j in 0 ..< hero_feat_len { s += f64(f[j]) }
		m := s / f64(hero_feat_len)
		if m > mx { mx = m; pid_white = i }
		if m < mn { mn = m; pid_black = i }
	}

	max_block := int(f64(fw) * state.g_max_block_pct)
	max_block = (max_block / 8) * 8
	if max_block < 8 { max_block = 8 }
	hero_min := int(f64(fh) * state.g_hero_min_pct)

	os.make_directory(man_dir)

	fps_path := fmt.tprintf("%s/fps.bin", man_dir)
	fps_data := make([]u8, 8)
	(^f64)(&fps_data[0])^ = source_fps
	_ = os.write_entire_file(fps_path, fps_data)
	delete(fps_data)

	t: Timings
	frames_done, total_tiles, progress_counter: int
	start := time.tick_now()

	frame: Img
	defer img_free(&frame)
	gray: Img
	defer img_free(&gray)

	manifest_cap := max(512, ((fw + 7) / 8) * ((fh + 7) / 8) + 1)
	manifest := make([]Inst, manifest_cap)
	defer delete(manifest)
	tiles := make([]u8, db.feat_len * manifest_cap)
	defer delete(tiles)

	fi: int
	for video_decoder_read_frame(dec, &frame) {
		if max_frames > 0 && fi >= max_frames { break }

		gray_sz := fw * fh
		if gray.pixels == nil || len(gray.pixels) != gray_sz {
			img_free(&gray)
			gray.pixels = make([]u8, gray_sz)
			gray.w = fw
			gray.h = fh
			gray.stride = fw
			gray.channels = 1
			if frame.channels == 1 {
				copy(gray.pixels, frame.pixels[:gray_sz])
			} else {
				img_to_gray(&frame, &gray)
			}
		} else if frame.channels == 1 {
			copy(gray.pixels, frame.pixels[:gray_sz])
		} else {
			img_to_gray(&frame, &gray)
		}

		needed_cap := ((fw + 7) / 8) * ((fh + 7) / 8) + 1
		if needed_cap > manifest_cap {
			new_cap := needed_cap * 2
			new_manifest := make([]Inst, new_cap)
			copy(new_manifest, manifest[:manifest_cap])
			delete(manifest)
			manifest = new_manifest
			new_tiles := make([]u8, db.feat_len * new_cap)
			delete(tiles)
			tiles = new_tiles
			manifest_cap = new_cap
		}

		n: int
		nt: int
		solve_full(&state, gray.pixels, frame.pixels, frame.stride, frame.channels, fw, fh,
		           &db, &reg, pid_white, pid_black, max_block, hero_min,
		           manifest[:manifest_cap], &n, tiles[:db.feat_len * manifest_cap], &nt, &t, pool)

		for k in 0 ..< n { if manifest[k].op_id >= 0 { total_tiles += 1 } }

		man_file := fmt.tprintf("%s/%04d.bin", man_dir, fi)
		write_manifest(man_file, fw, fh, manifest[:n], n)

		frames_done += 1
		fi += 1
		progress_counter -= 1
		if !g_cli.quiet && progress_counter == 0 {
			progress_counter = 30
			elapsed := time.duration_seconds(time.tick_since(start))
			fps_out := f64(frames_done) / max(elapsed, 0.001)
			cli_progress_frame("arrange", fi, max_frames if max_frames > 0 else int(source_fps * 300),
			                   fps_out, 0.0)
		}
	}

	elapsed := time.duration_seconds(time.tick_since(start))
	overall_fps := f64(frames_done) / max(elapsed, 0.001)
	cli_progress_done(fmt.tprintf("arrange complete in %.2fs | %.2f fps | %d tiles | feat=%.2fs match=%.2fs solve=%.2fs",
	                              elapsed, overall_fps, total_tiles, t.feat, t.match, t.solve))
}
