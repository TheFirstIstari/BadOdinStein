package main

import "core:mem"
import "core:simd"

// SIMD L1 distance: processes 16 bytes at a time using NEON/SSSE3
feature_l1 :: proc(a, b: []u8) -> u32 {
	n := min(len(a), len(b))
	dist: u64 = 0
	j := 0

	// SIMD path: 16 bytes at a time, accumulate into u16 to avoid overflow
	acc := simd.u16x8{0, 0, 0, 0, 0, 0, 0, 0}
	for j + 16 <= n {
		va := simd.from_slice(simd.u8x16, a[j:j+16])
		vb := simd.from_slice(simd.u8x16, b[j:j+16])
		diff := simd.abs_diff(va, vb) // u8x16: |a-b| per byte

		// Convert to array and manually widen to u16x8 (two halves)
		d := simd.to_array(diff)
		lo := simd.u16x8{u16(d[0]), u16(d[1]), u16(d[2]), u16(d[3]), u16(d[4]), u16(d[5]), u16(d[6]), u16(d[7])}
		hi := simd.u16x8{u16(d[8]), u16(d[9]), u16(d[10]), u16(d[11]), u16(d[12]), u16(d[13]), u16(d[14]), u16(d[15])}
		acc = acc + lo + hi
		j += 16
	}

	// Reduce the SIMD accumulator
	dist = u64(simd.reduce_add_pairs(acc))

	// Scalar tail
	for j < n {
		dist += u64(max(a[j], b[j]) - min(a[j], b[j]))
		j += 1
	}

	if dist > u64(max(u32)) {
		return max(u32)
	}
	return u32(dist)
}

feature_l1_bounded :: proc(a, b: []u8, bound: u32) -> u32 {
	n := min(len(a), len(b))
	dist: u64 = 0
	j := 0

	// SIMD path: 16 bytes at a time with periodic bound checks
	acc := simd.u16x8{0, 0, 0, 0, 0, 0, 0, 0}
	CHUNK :: 16
	for j + CHUNK <= n {
		va := simd.from_slice(simd.u8x16, a[j:j+CHUNK])
		vb := simd.from_slice(simd.u8x16, b[j:j+CHUNK])
		diff := simd.abs_diff(va, vb)

		d := simd.to_array(diff)
		lo := simd.u16x8{u16(d[0]), u16(d[1]), u16(d[2]), u16(d[3]), u16(d[4]), u16(d[5]), u16(d[6]), u16(d[7])}
		hi := simd.u16x8{u16(d[8]), u16(d[9]), u16(d[10]), u16(d[11]), u16(d[12]), u16(d[13]), u16(d[14]), u16(d[15])}
		acc = acc + lo + hi

		// Check bound every 64 bytes (4 chunks) to amortize reduce cost
		if (j / CHUNK) % 4 == 3 {
			dist = u64(simd.reduce_add_pairs(acc))
			if dist > u64(bound) {
				if dist > u64(max(u32)) {
					return max(u32)
				}
				return u32(dist)
			}
			acc = simd.u16x8{0, 0, 0, 0, 0, 0, 0, 0}
		}
		j += CHUNK
	}

	// Flush remaining SIMD accumulator
	dist += u64(simd.reduce_add_pairs(acc))

	// Scalar tail with early exit
	for j < n {
		d := u64(max(a[j], b[j]) - min(a[j], b[j]))
		dist += d
		if dist > u64(bound) {
			if dist > u64(max(u32)) {
				return max(u32)
			}
			return u32(dist)
		}
		j += 1
	}

	return u32(dist)
}

MATCH_K :: 16

match_batch_coarse :: proc(lib, targets: []u8, n_pages, num_targets, feat_len, coarse_len: int, results: []int) {
	if num_targets == 0 || n_pages == 0 { return }

	if n_pages == 1 {
		for t in 0 ..< num_targets {
			results[t] = 0
		}
		return
	}

	fine_needed := coarse_len < feat_len
	coarse_len := feat_len if !fine_needed else coarse_len

	K := min(MATCH_K, n_pages)

	merged_dist := make([]u32, num_targets * K)
	merged_best := make([]int, num_targets * K)
	defer {
		delete(merged_dist)
		delete(merged_best)
	}

	for i in 0 ..< num_targets * K {
		merged_dist[i] = max(u32)
		merged_best[i] = -1
	}

	for i in 0 ..< n_pages {
		page := lib[i * feat_len : (i + 1) * feat_len]

		for t in 0 ..< num_targets {
			target := targets[t * feat_len : (t + 1) * feat_len]
			coarse_target := target[:coarse_len]
			coarse_page := page[:coarse_len]

			d := feature_l1(coarse_page, coarse_target)

			kd := merged_dist[t * K :]
			kb := merged_best[t * K :]

			if d >= kd[K - 1] { continue }

			kd[K - 1] = d
			kb[K - 1] = i

			for ki in 0 ..< K - 1 {
				k := K - 1 - ki
				if kd[k] < kd[k - 1] {
					tmp_d := kd[k]
					kd[k] = kd[k - 1]
					kd[k - 1] = tmp_d
					tmp_i := kb[k]
					kb[k] = kb[k - 1]
					kb[k - 1] = tmp_i
				} else {
					break
				}
			}
		}
	}

	if fine_needed {
		for t in 0 ..< num_targets {
			best_d: u32 = max(u32)
			best_i: int = -1
			target := targets[t * feat_len :]
			kb := merged_best[t * K :]

			for k in 0 ..< K {
				if kb[k] < 0 { break }
				page := lib[kb[k] * feat_len :]
				d := feature_l1_bounded(page, target[:feat_len], best_d)
				if d < best_d {
					best_d = d
					best_i = kb[k]
				}
			}
			if best_i == -1 {
				best_i = merged_best[t * K]
			}
			results[t] = best_i
		}
	} else {
		for t in 0 ..< num_targets {
			results[t] = merged_best[t * K]
		}
	}
}

match_batch :: proc(lib, targets: []u8, n_pages, num_targets, feat_len: int, results: []int) {
	match_batch_coarse(lib, targets, n_pages, num_targets, feat_len, feat_len, results)
}
