package main

import "core:simd"

// ══════════════════════════════════════════════════════════════
// SIMD-optimized image operations using core:simd.
// Adds portable SIMD paths matching BadApplestein's C reference
// SIMD implementations (SSE2/AVX2/NEON) in imgops.c.
// ══════════════════════════════════════════════════════════════

// ── Luma conversion constants ──────────────────────────────────
luma_coeff29_  :: simd.u16x8{29, 29, 29, 29, 29, 29, 29, 29}
luma_coeff150_ :: simd.u16x8{150, 150, 150, 150, 150, 150, 150, 150}
luma_coeff77_  :: simd.u16x8{77, 77, 77, 77, 77, 77, 77, 77}
luma_round128_ :: simd.u16x8{128, 128, 128, 128, 128, 128, 128, 128}

// Shuffle indices for B/G/R channel extraction from BGR layout.
// Each pixel occupies 3 bytes: B=offset, G=offset+1, R=offset+2.
// 0xFF marks "don't care" — runtime_swizzle returns 0 for those lanes.
LUMA_STEP :: 5 // pixels per SIMD iteration (same as C reference SSE2 path)

gray_b_idx :: simd.u8x16{0, 3, 6, 9, 12, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255}
gray_g_idx :: simd.u8x16{1, 4, 7, 10, 13, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255}
gray_r_idx :: simd.u8x16{2, 5, 8, 11, 14, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255}

// ── img_to_gray SIMD ──────────────────────────────────────────
// Portable SIMD BGR→grayscale using runtime_swizzle (PSHUFB/tbl)
// for byte-level channel extraction and SIMD u16 arithmetic for
// the luma multiply-add. Processes LUMA_STEP pixels per iteration.
// Mirrors BadApplestein's img_to_gray_simd (SSE2/NEON).

img_to_gray_simd :: proc(src_pixels: []u8, src_stride: int, dst_pixels: []u8, dst_stride: int, w: int, h: int) {
	if w <= 0 || h <= 0 {
		return
	}

	for y in 0 ..< h {
		src_row := src_pixels[y*src_stride:]
		dst_row := dst_pixels[y*dst_stride:]

		x := 0
		for x + LUMA_STEP <= w {
			raw := simd.from_slice(simd.u8x16, src_row[x*3:])

			// SIMD channel extraction — single pshufb/tbl instruction per channel
			b_ch := simd.runtime_swizzle(raw, gray_b_idx)
			g_ch := simd.runtime_swizzle(raw, gray_g_idx)
			r_ch := simd.runtime_swizzle(raw, gray_r_idx)

			// Widen u8 lanes 0..4 to u16; lanes 5..7 are zero (padding).
			b_a := simd.to_array(b_ch)
			g_a := simd.to_array(g_ch)
			r_a := simd.to_array(r_ch)

			b16 := simd.u16x8{ u16(b_a[0]), u16(b_a[1]), u16(b_a[2]), u16(b_a[3]), u16(b_a[4]), 0, 0, 0 }
			g16 := simd.u16x8{ u16(g_a[0]), u16(g_a[1]), u16(g_a[2]), u16(g_a[3]), u16(g_a[4]), 0, 0, 0 }
			r16 := simd.u16x8{ u16(r_a[0]), u16(r_a[1]), u16(r_a[2]), u16(r_a[3]), u16(r_a[4]), 0, 0, 0 }

			// Luma = (29*B + 150*G + 77*R + 128) >> 8
			// Max intermediate = 29*255 + 150*255 + 77*255 + 128 = 65408 (fits in u16)
			luma := simd.mul(b16, luma_coeff29_)
			luma = simd.add(luma, simd.mul(g16, luma_coeff150_))
			luma = simd.add(luma, simd.mul(r16, luma_coeff77_))
			luma = simd.add(luma, luma_round128_)
			luma = simd.shr(luma, 8) // >> 8 divide by 256

			// Store NUMA_STEP results from the low 5 lanes
			r := simd.to_array(luma)
			dst_row[x+0] = u8(r[0])
			dst_row[x+1] = u8(r[1])
			dst_row[x+2] = u8(r[2])
			dst_row[x+3] = u8(r[3])
			dst_row[x+4] = u8(r[4])
			x += LUMA_STEP
		}

		// Scalar tail for remaining pixels
		for x < w {
			off := x * 3
			b := i32(src_row[off+0])
			g := i32(src_row[off+1])
			r := i32(src_row[off+2])
			dst_row[x] = u8((29*b + 150*g + 77*r + 128) >> 8)
			x += 1
		}
	}
}

// ── img_sobel_magnitude ───────────────────────────────────────
// Scalar fallback (matching the C reference scalar path).
// SIMD acceleration requires gather/scatter for the 3×3 kernel,
// which portable core:simd does not expose directly.

img_sobel_magnitude :: proc(gray: []u8, w, h: int, out: []u8) {
	if w < 3 || h < 3 {
		for i in 0 ..< len(out) {
			out[i] = 0
		}
		return
	}

	for y in 1 ..< h - 1 {
		for x in 1 ..< w - 1 {
			tl := i32(gray[(y-1)*w+(x-1)])
			tc := i32(gray[(y-1)*w+x])
			tr := i32(gray[(y-1)*w+(x+1)])
			ml := i32(gray[y*w+(x-1)])
			mr := i32(gray[y*w+(x+1)])
			bl := i32(gray[(y+1)*w+(x-1)])
			bc := i32(gray[(y+1)*w+x])
			br := i32(gray[(y+1)*w+(x+1)])

			gx := -tl + tr - 2*ml + 2*mr - bl + br
			gy := -tl - 2*tc - tr + bl + 2*bc + br
			agx := abs(gx)
			agy := abs(gy)

			out[y*w+x] = u8(min(max(agx, agy) + min(agx, agy) / 2, 255))
		}
	}

	for x in 0 ..< w {
		out[x] = out[w+x]
		out[(h-1)*w+x] = out[(h-2)*w+x]
	}
	for y in 0 ..< h {
		out[y*w] = out[y*w+1]
		out[y*w+(w-1)] = out[y*w+(w-2)]
	}
}

// ── High-level wrappers ───────────────────────────────────────

img_to_gray :: proc(src, dst: ^Img) {
	if src.channels == 1 {
		for y in 0 ..< src.h {
			copy(dst.pixels[y*dst.stride:y*dst.stride+src.w], src.pixels[y*src.stride:y*src.stride+src.w])
		}
		return
	}
	img_to_gray_simd(src.pixels, src.stride, dst.pixels, dst.stride, src.w, src.h)
}

img_resize_area :: proc(src, dst: ^Img, nw, nh: int) {
	sw, sh := src.w, src.h
	sc, dc := src.channels, dst.channels
	nc := min(sc, dc)

	if nw > 0 && sw > 0 && nh > 0 && sh > 0 && nw % sw == 0 && nh % sh == 0 {
		kx := nw / sw
		ky := nh / sh
		for dy in 0 ..< nh {
			sy := dy / ky
			for dx in 0 ..< nw {
				sx := dx / kx
				s_off := sy*src.stride + sx*sc
				d_off := dy*dst.stride + dx*dc
				for c in 0 ..< nc {
					dst.pixels[d_off+c] = src.pixels[s_off+c]
				}
			}
		}
		return
	}

	for dy in 0 ..< nh {
		sy0 := dy * sh / nh
		sy1 := (dy + 1) * sh / nh
		for dx in 0 ..< nw {
			sx0 := dx * sw / nw
			sx1 := (dx + 1) * sw / nw
			area := (sx1 - sx0) * (sy1 - sy0)
			if area == 0 {
				area = 1
			}

			acc: [4]i64
			for c in 0 ..< 4 {
				acc[c] = 0
			}

			for sy in sy0 ..< sy1 {
				for sx in sx0 ..< sx1 {
					s_off := sy*src.stride + sx*sc
					for c in 0 ..< nc {
						acc[c] += i64(src.pixels[s_off+c])
					}
				}
			}

			d_off := dy*dst.stride + dx*dc
			for c in 0 ..< nc {
				v := (acc[c] + i64(area) / 2) / i64(area)
				dst.pixels[d_off+c] = u8(min(v, 255))
			}
		}
	}
}

img_threshold_u8 :: proc(buf: []u8, thr, maxval: int) {
	for i in 0 ..< len(buf) {
		if int(buf[i]) > thr {
			buf[i] = u8(maxval)
		} else {
			buf[i] = 0
		}
	}
}

img_integral :: proc(gray: []u8, w, h: int, allocator := context.allocator) -> []i64 {
	cols := w + 1
	buf := make([]i64, cols*(h+1), allocator)
	for y in 0 ..< h {
		row_sum: i64 = 0
		for x in 0 ..< w {
			row_sum += i64(gray[y*w+x])
			buf[(y+1)*cols+(x+1)] = buf[y*cols+(x+1)] + row_sum
		}
	}
	return buf
}

img_compute_feature :: proc(crop: ^Img, N, G, color: int, out: []u8) {
	channels := crop.channels
	if channels == 3 && color == 0 {
		channels = 1
	}

	stride := N * channels
	tmp_buf := make([]u8, stride*N, context.allocator)
	defer delete(tmp_buf)
	tmp := Img{w = N, h = N, stride = stride, pixels = tmp_buf, channels = channels}

	if crop.channels == 3 && color == 0 {
		gray_buf := make([]u8, crop.w*crop.h, context.allocator)
		defer delete(gray_buf)
		gray := Img{w = crop.w, h = crop.h, stride = crop.w, pixels = gray_buf, channels = 1}
		img_to_gray(crop, &gray)
		img_resize_area(&gray, &tmp, N, N)
	} else {
		img_resize_area(crop, &tmp, N, N)
	}

	maxv := (1 << u32(G)) - 1
	for i in 0 ..< N * N * channels {
		v := int(tmp_buf[i])
		if G >= 8 {
			out[i] = u8(v)
		} else {
			q := (v * maxv + 127) / 255
			if q > maxv {
				q = maxv
			}
			out[i] = u8(q)
		}
	}
}

// Pre-allocated buffers for img_compute_feature_multires
Feature_Buffers :: struct {
	gray_buf:    []u8,
	edge_buf:    []u8,
	color_buf:   []u8,
	full_gray:   []u8,
}

feature_bufs_init :: proc(max_n, max_crop: int, allocator := context.allocator) -> Feature_Buffers {
	return Feature_Buffers{
		gray_buf = make([]u8, max_n * max_n, allocator),
		edge_buf = make([]u8, max_n * max_n, allocator),
		color_buf = make([]u8, max_n * max_n * 3, allocator),
		full_gray = make([]u8, max_crop, allocator),
	}
}

feature_bufs_cleanup :: proc(bufs: ^Feature_Buffers) {
	delete(bufs.gray_buf)
	delete(bufs.edge_buf)
	delete(bufs.color_buf)
	delete(bufs.full_gray)
}

img_compute_feature_multires :: proc(crop: ^Img, scales: []int, G, has_edges, color: int, out: []u8, bufs: ^Feature_Buffers = nil) {
	pos := 0
	maxv := (1 << u32(G)) - 1

	// Use pre-allocated buffers if provided, otherwise allocate locally
	local_bufs: Feature_Buffers
	used_bufs: ^Feature_Buffers
	if bufs != nil {
		used_bufs = bufs
	} else {
		max_n := 0
		for s in scales {
			if s > max_n { max_n = s }
		}
		local_bufs = feature_bufs_init(max_n, crop.w * crop.h)
		used_bufs = &local_bufs
		defer feature_bufs_cleanup(used_bufs)
	}

	// Convert to gray once if needed (reuse for all scales)
	has_gray := crop.channels == 3
	if has_gray {
		full_gray := Img{
			w = crop.w,
			h = crop.h,
			stride = crop.w,
			pixels = used_bufs.full_gray[:crop.w * crop.h],
			channels = 1,
		}
		img_to_gray(crop, &full_gray)
	}

	for N in scales {
		gray_img := Img{
			w = N,
			h = N,
			stride = N,
			pixels = used_bufs.gray_buf[:N*N],
			channels = 1,
		}

		if has_gray {
			full_gray := Img{
				w = crop.w,
				h = crop.h,
				stride = crop.w,
				pixels = used_bufs.full_gray[:crop.w * crop.h],
				channels = 1,
			}
			img_resize_area(&full_gray, &gray_img, N, N)
		} else {
			img_resize_area(crop, &gray_img, N, N)
		}

		for i in 0 ..< N * N {
			v := int(used_bufs.gray_buf[i])
			if G >= 8 {
				out[pos+i] = u8(v)
			} else {
				q := (v * maxv + 127) / 255
				if q > maxv { q = maxv }
				out[pos+i] = u8(q)
			}
		}
		pos += N * N

		if has_edges != 0 {
			img_sobel_magnitude(used_bufs.gray_buf[:N*N], N, N, used_bufs.edge_buf[:N*N])
			for i in 0 ..< N * N {
				v := int(used_bufs.edge_buf[i])
				if G >= 8 {
					out[pos+i] = u8(v)
				} else {
					q := (v * maxv + 127) / 255
					if q > maxv { q = maxv }
					out[pos+i] = u8(q)
				}
			}
			pos += N * N
		}

		if color != 0 {
			color_img := Img{
				w = N,
				h = N,
				stride = N * 3,
				pixels = used_bufs.color_buf[:N*N*3],
				channels = 3,
			}
			img_resize_area(crop, &color_img, N, N)
			total := N * N * 3
			for i in 0 ..< total {
				v := int(used_bufs.color_buf[i])
				if G >= 8 {
					out[pos+i] = u8(v)
				} else {
					q := (v * maxv + 127) / 255
					if q > maxv { q = maxv }
					out[pos+i] = u8(q)
				}
			}
			pos += total
		}
	}
}