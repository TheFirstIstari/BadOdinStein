package main

img_to_gray :: proc(src, dst: ^Img) {
	if src.channels == 1 {
		for y in 0 ..< src.h {
			copy(dst.pixels[y*dst.stride:y*dst.stride+src.w], src.pixels[y*src.stride:y*src.stride+src.w])
		}
		return
	}
	for y in 0 ..< src.h {
		for x in 0 ..< src.w {
			so := y * src.stride + x * src.channels
			b := i32(src.pixels[so+0])
			g := i32(src.pixels[so+1])
			r := i32(src.pixels[so+2])
			dst.pixels[y*dst.stride+x] = u8((29*b + 150*g + 77*r + 128) >> 8)
		}
	}
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

img_compute_feature_multires :: proc(crop: ^Img, scales: []int, G, has_edges, color: int, out: []u8) {
	pos := 0
	maxv := (1 << u32(G)) - 1

	max_n := 0
	for s in scales {
		if s > max_n {
			max_n = s
		}
	}

	gray_buf := make([]u8, max_n*max_n, context.allocator)
	defer delete(gray_buf)
	edge_buf := make([]u8, max_n*max_n, context.allocator)
	defer delete(edge_buf)
	color_buf := make([]u8, max_n*max_n*3, context.allocator)
	defer delete(color_buf)

	full_gray_buf := make([]u8, crop.w*crop.h, context.allocator)
	defer delete(full_gray_buf)

	for N in scales {
		gray_img := Img{
			w = N,
			h = N,
			stride = N,
			pixels = gray_buf[:N*N],
			channels = 1,
		}

		if crop.channels == 3 {
			full_gray := Img{
				w = crop.w,
				h = crop.h,
				stride = crop.w,
				pixels = full_gray_buf,
				channels = 1,
			}
			img_to_gray(crop, &full_gray)
			img_resize_area(&full_gray, &gray_img, N, N)
		} else {
			img_resize_area(crop, &gray_img, N, N)
		}

		for i in 0 ..< N * N {
			v := int(gray_buf[i])
			if G >= 8 {
				out[pos+i] = u8(v)
			} else {
				q := (v * maxv + 127) / 255
				if q > maxv {
					q = maxv
				}
				out[pos+i] = u8(q)
			}
		}
		pos += N * N

		if has_edges != 0 {
			img_sobel_magnitude(gray_buf[:N*N], N, N, edge_buf[:N*N])
			for i in 0 ..< N * N {
				v := int(edge_buf[i])
				if G >= 8 {
					out[pos+i] = u8(v)
				} else {
					q := (v * maxv + 127) / 255
					if q > maxv {
						q = maxv
					}
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
				pixels = color_buf[:N*N*3],
				channels = 3,
			}
			img_resize_area(crop, &color_img, N, N)
			total := N * N * 3
			for i in 0 ..< total {
				v := int(color_buf[i])
				if G >= 8 {
					out[pos+i] = u8(v)
				} else {
					q := (v * maxv + 127) / 255
					if q > maxv {
						q = maxv
					}
					out[pos+i] = u8(q)
				}
			}
			pos += total
		}
	}
}
