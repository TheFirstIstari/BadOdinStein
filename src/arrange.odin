package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import "core:time"
import "core:math"

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
	if ferr != os.ERROR_NONE { return }
	defer os.close(f)
	os.write(f, mbuf)
}

solve_full :: proc(s: ^Arrange_State, gray, color_pixels: []u8, color_stride, color_channels, w, h: int,
                   db: ^FeatureDB, reg: ^Registry, pid_white, pid_black, max_block, hero_min: int,
                   manifest: []Inst, nout: ^int, tiles: []u8, ntiles: ^int, t: ^Timings) {
	CELL_SIZE :: 8

	if s.cap_w < w || s.cap_h < h {
		s.cap_w = w
		s.cap_h = h
		s.sum = make([]i64, (w + 1) * (h + 1))
		s.visited = make([]u8, ((h + 7) / 8) * ((w + 7) / 8))
	}
	sum_stride := w + 1

	for x in 0 ..< w + 1 { s.sum[x] = 0 }
	for y in 0 ..< h { s.sum[(y + 1) * sum_stride] = 0 }
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
	mem.clear(s.visited[:gh * gw])

	feat_len := db.feat_len
	max_cells := max_block / CELL_SIZE
	n: int = 0
	nt: int = 0
	n_specs: int = 0
	spec_cap := max(512, len(s.specs))

	if len(s.specs) < spec_cap {
		s.specs = make([]TileSpec, spec_cap)
	}

	t0 := time.ticks()

	for cy in 0 ..< gh {
		y := cy * CELL_SIZE
		for cx in 0 ..< gw {
			x := cx * CELL_SIZE
			if s.visited[cy * gw + cx] != 0 { continue }

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
				for xx in cx ..< cx + mcw {
					if s.visited[(cy + mch) * gw + xx] != 0 {
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
				for ccx in cx ..< cx + mcw {
					s.visited[ccy * gw + ccx] = 1
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

			tf := time.ticks()

			for i in 0 ..< n_specs {
				sp := s.specs[i]
				my_crop := s.crop_bufs[:sp.w * sp.h * ch_mult]

				if db.channels == 3 {
					for yy in 0 ..< sp.h {
						src_off := (sp.y + yy) * color_stride + sp.x * 3
						dst_off := yy * sp.w * 3
						copy(my_crop[dst_off:], color_pixels[src_off:], sp.w * 3)
					}
				} else {
					for yy in 0 ..< sp.h {
						src_off := (sp.y + yy) * w + sp.x
						dst_off := yy * sp.w
						copy(my_crop[dst_off:], gray[src_off:], sp.w)
					}
				}

				N := s.g_scales[0]
				maxv := (1 << db.G) - 1
				coarse_feat := make([]u8, N * N)
				defer delete(coarse_feat)

				for dy in 0 ..< N {
					sy0 := dy * sp.h / N
					sy1 := min((dy + 1) * sp.h / N, sp.h)
					for dx in 0 ..< N {
						sx0 := dx * sp.w / N
						sx1 := min((dx + 1) * sp.w / N, sp.w)
						psum: u64 = 0
						for sy in sy0 ..< sy1 {
							for sx in sx0 ..< sx1 {
								if db.channels == 3 {
									poff := sy * sp.w * 3 + sx * 3
									psum += u64((29 * u32(my_crop[poff+0]) + 150 * u32(my_crop[poff+1]) + 77 * u32(my_crop[poff+2])) >> 8)
								} else {
									psum += u64(my_crop[sy * sp.w + sx])
								}
							}
						}
						area := (sy1 - sy0) * (sx1 - sx0)
						v := int(psum / u64(area)) if area > 0 else 0
						q := v if db.G >= 8 else (v * maxv + 127) / 255
						if q > maxv { q = maxv }
						coarse_feat[dy * N + dx] = u8(q)
					}
				}

				ch := fnv1a_64(coarse_feat)
				found, pid := cache_lookup(s.ccache, s.ccache_cap, ch)
				if found {
					s.coarse_hit[i] = pid
					continue
				}

				crop_img := Img{w = sp.w, h = sp.h, stride = sp.w * db.channels, pixels = my_crop, channels = db.channels}
				out_slice := feat_bufs[i * feat_len :]
				feature_ch: int = 1 if db.channels == 3 else 0
				img_compute_feature_multires(&crop_img, s.g_scales[:s.g_n_scales], db.G, db.has_edges, feature_ch, out_slice)
			}

			for i in 0 ..< n_specs {
				if s.coarse_hit[i] >= 0 {
					t.hits += 1
					midx := s.specs[i].manifest_idx
					manifest[midx].op_id = i32(s.coarse_hit[i])
					manifest[midx].page_idx = reg.entries[s.coarse_hit[i]].page_idx
				}
			}
			t.feat += f64(time.ticks() - tf) / f64(time.SECOND)

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
				tm := time.ticks()
				if nt > s.result_cap {
					s.results = make([]int, nt)
					s.result_cap = nt
				}
				match_batch_coarse(db.data, tiles[:nt * feat_len], db.n_pages, nt, feat_len, coarse_len, s.results[:nt])
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
				t.match += f64(time.ticks() - tm) / f64(time.SECOND)
				t.tiles += nt
			}
		}
	}

	t.solve += f64(time.ticks() - t0) / f64(time.SECOND)
	nout^ = n
	ntiles^ = nt
}

arrange_main :: proc() {
	state: Arrange_State
	arrange_init(&state)
	defer arrange_cleanup(&state)

	video_path := cli_opt_str("video", "")
	feat_path := cli_opt_str("features", "features.bin")
	reg_path := cli_opt_str("registry", "registry.bin")
	man_dir := cli_opt_str("manifests", "manifests_greedy")
	max_frames := cli_opt_int("max-frames", 0)

	if len(video_path) == 0 {
		cli_die("arrange requires --video <file>")
	}

    db: FeatureDB
    defer delete(db.data)
    if load_features(feat_path, &db) != 0 {
        cli_die("cannot load features: %s", feat_path)
    }

    reg: Registry
    defer {
        for e in reg.entries { delete(e.pdf_path) }
        delete(reg.entries)
    }
    if load_registry(reg_path, &reg) != 0 {
        cli_die("cannot load registry: %s", reg_path)
    }

	state.g_G = db.G
	state.g_feat_len = db.feat_len
	state.g_n_scales = db.n_scales
	for i in 0 ..< db.n_scales { state.g_scales[i] = db.scales[i] }
	state.g_has_edges = db.has_edges

	cli_info("library: %d pages | scales=%d G=%d edges=%d | feat_len=%d",
	         db.n_pages, state.g_n_scales, state.g_G, state.g_has_edges, db.feat_len)

	cli_die("video decode not yet implemented - use --video after video.odin is complete")
}
