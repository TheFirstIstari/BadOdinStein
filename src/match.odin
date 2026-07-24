package main

import "core:mem"

feature_l1 :: proc(a, b: []u8) -> u32 {
	dist: u64 = 0
	n := min(len(a), len(b))
	for j in 0 ..< n {
		d := i32(a[j]) - i32(b[j])
		if d < 0 { d = -d }
		dist += u64(d)
	}
	if dist > u64(max(u32)) {
		return max(u32)
	}
	return u32(dist)
}

feature_l1_bounded :: proc(a, b: []u8, bound: u32) -> u32 {
	dist: u64 = 0
	n := min(len(a), len(b))
	for j in 0 ..< n {
		d := i32(a[j]) - i32(b[j])
		if d < 0 { d = -d }
		dist += u64(d)
		if dist > u64(bound) {
			if dist > u64(max(u32)) {
				return max(u32)
			}
			return u32(dist)
		}
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
	if !fine_needed {
		coarse_len = feat_len
	}

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

			kd := merged_dist[t * K ..]
			kb := merged_best[t * K ..]

			if d >= kd[K - 1] { continue }

			kd[K - 1] = d
			kb[K - 1] = i

			for k in K - 1 >.. 0 {
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
			target := targets[t * feat_len ..]
			kb := merged_best[t * K ..]

			for k in 0 ..< K {
				if kb[k] < 0 { break }
				page := lib[kb[k] * feat_len ..]
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
