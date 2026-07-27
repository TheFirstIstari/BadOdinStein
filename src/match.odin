package main

import "core:mem"
import "core:thread"
import "core:os"

/* ── SIMD-accelerated L1 distance via hardware intrinsics ────
 * Delegates to C bridge (match_bridge.c) which uses SSE2/AVX2/NEON
 * _mm_sad_epu8 / _mm256_sad_epu8 / vabdq_u8 instructions for
 * single-instruction sum-of-absolute-differences, matching the
 * C reference (BadApplestein) for identical binary output. */
foreign import match_bridge "libmatch_bridge.a"

foreign match_bridge {
	feature_l1_simd         :: proc "c" (a, b: rawptr, len: int) -> u32 ---
	feature_l1_bounded_simd :: proc "c" (a, b: rawptr, len: int, bound: u32) -> u32 ---
}

feature_l1 :: proc(a, b: []u8) -> u32 {
	n := min(len(a), len(b))
	return feature_l1_simd(rawptr(&a[0]), rawptr(&b[0]), n)
}

feature_l1_bounded :: proc(a, b: []u8, bound: u32) -> u32 {
	n := min(len(a), len(b))
	return feature_l1_bounded_simd(rawptr(&a[0]), rawptr(&b[0]), n, bound)
}

MATCH_K :: 16

// Thread context for parallel coarse matching
Match_Work :: struct {
	lib:          []u8,
	targets:      []u8,
	page_start:   int,
	page_end:     int,
	num_targets:  int,
	feat_len:     int,
	coarse_len:   int,
	K:            int,
	local_dist:   []u32,  // num_targets * K
	local_best:   []int,  // num_targets * K
}

// Thread context for parallel fine matching
Fine_Work :: struct {
	lib:          []u8,
	targets:      []u8,
	target_start: int,
	target_end:   int,
	feat_len:     int,
	K:            int,
	coarse_best:  []int,  // num_targets * K (coarse results)
	results:      []int,  // num_targets (output)
}

// Thread function for parallel coarse matching
match_thread_proc :: proc(t: ^thread.Thread) {
	w := cast(^Match_Work)t.data

	for i in w.page_start ..< w.page_end {
		page := w.lib[i * w.feat_len : (i + 1) * w.feat_len]

		for t_idx in 0 ..< w.num_targets {
			target := w.targets[t_idx * w.feat_len : (t_idx + 1) * w.feat_len]
			coarse_target := target[:w.coarse_len]
			coarse_page := page[:w.coarse_len]

			d := feature_l1(coarse_page, coarse_target)

			kd := w.local_dist[t_idx * w.K :]
			kb := w.local_best[t_idx * w.K :]

			if d >= kd[w.K - 1] { continue }

			kd[w.K - 1] = d
			kb[w.K - 1] = i

			// Insertion sort to maintain sorted order
			for ki in 0 ..< w.K - 1 {
				k := w.K - 1 - ki
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
}

// Thread function for parallel fine matching
fine_match_thread_proc :: proc(t: ^thread.Thread) {
	w := cast(^Fine_Work)t.data

	for t_idx in w.target_start ..< w.target_end {
		best_d: u32 = max(u32)
		best_i: int = -1
		target := w.targets[t_idx * w.feat_len :]
		kb := w.coarse_best[t_idx * w.K :]

		for k in 0 ..< w.K {
			if kb[k] < 0 { break }
			page := w.lib[kb[k] * w.feat_len :]
			d := feature_l1_bounded(page, target[:w.feat_len], best_d)
			if d < best_d {
				best_d = d
				best_i = kb[k]
			}
		}
		if best_i == -1 {
			best_i = w.coarse_best[t_idx * w.K]
		}
		w.results[t_idx] = best_i
	}
}

// Merge thread-local results into global results
merge_thread_results :: proc(global_dist: []u32, global_best: []int, local_dist: []u32, local_best: []int, num_targets, K: int) {
	// For each target, merge the local top-K into global top-K
	for t in 0 ..< num_targets {
		gd := global_dist[t * K :]
		gb := global_best[t * K :]
		ld := local_dist[t * K :]
		lb := local_best[t * K :]

		for li in 0 ..< K {
			if lb[li] < 0 { break }
			d := ld[li]
			i := lb[li]

			if d >= gd[K - 1] { continue }

			gd[K - 1] = d
			gb[K - 1] = i

			// Insertion sort
			for ki in 0 ..< K - 1 {
				k := K - 1 - ki
				if gd[k] < gd[k - 1] {
					tmp_d := gd[k]
					gd[k] = gd[k - 1]
					gd[k - 1] = tmp_d
					tmp_i := gb[k]
					gb[k] = gb[k - 1]
					gb[k - 1] = tmp_i
				} else {
					break
				}
			}
		}
	}
}

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

	// Use threading for coarse matching if we have enough work
	num_cores := os.get_processor_core_count()
	if num_cores <= 0 { num_cores = 1 }
	num_threads := min(num_cores, n_pages / 64)

	if num_threads > 1 {
		// Parallel coarse matching
		pages_per_thread := n_pages / num_threads

		// Allocate thread-local storage arrays
		local_dists := make([][]u32, num_threads)
		local_bests := make([][]int, num_threads)
		threads := make([]^thread.Thread, num_threads)
		work_items := make([]Match_Work, num_threads)

		for ti in 0 ..< num_threads {
			start := ti * pages_per_thread
			end := start + pages_per_thread
			if ti == num_threads - 1 {
				end = n_pages
			}

			local_dists[ti] = make([]u32, num_targets * K)
			local_bests[ti] = make([]int, num_targets * K)
			for i in 0 ..< num_targets * K {
				local_dists[ti][i] = max(u32)
				local_bests[ti][i] = -1
			}

			work_items[ti] = Match_Work {
				lib = lib,
				targets = targets,
				page_start = start,
				page_end = end,
				num_targets = num_targets,
				feat_len = feat_len,
				coarse_len = coarse_len,
				K = K,
				local_dist = local_dists[ti],
				local_best = local_bests[ti],
			}

			t := thread.create(match_thread_proc)
			t.data = &work_items[ti]
			thread.start(t)
			threads[ti] = t
		}

		// Wait for all threads to finish
		for ti in 0 ..< num_threads {
			thread.join(threads[ti])
		}

		// Merge results
		global_dist := make([]u32, num_targets * K)
		global_best := make([]int, num_targets * K)
		for i in 0 ..< num_targets * K {
			global_dist[i] = max(u32)
			global_best[i] = -1
		}

		for ti in 0 ..< num_threads {
			merge_thread_results(global_dist, global_best, local_dists[ti], local_bests[ti], num_targets, K)
			delete(local_dists[ti])
			delete(local_bests[ti])
		}

		// Fine matching (parallelized over targets)
		if fine_needed {
			// Use threading for fine matching if we have enough targets
			fine_threads := min(num_cores, num_targets / 16)

			if fine_threads > 1 {
				targets_per_thread := num_targets / fine_threads
				fine_work := make([]Fine_Work, fine_threads)
				fine_threads_arr := make([]^thread.Thread, fine_threads)

				for ti in 0 ..< fine_threads {
					start := ti * targets_per_thread
					end := start + targets_per_thread
					if ti == fine_threads - 1 {
						end = num_targets
					}

					fine_work[ti] = Fine_Work {
						lib = lib,
						targets = targets,
						target_start = start,
						target_end = end,
						feat_len = feat_len,
						K = K,
						coarse_best = global_best,
						results = results,
					}

					t := thread.create(fine_match_thread_proc)
					t.data = &fine_work[ti]
					thread.start(t)
					fine_threads_arr[ti] = t
				}

				// Wait for all fine threads to finish
				for ti in 0 ..< fine_threads {
					thread.join(fine_threads_arr[ti])
				}

				delete(fine_work)
				delete(fine_threads_arr)
			} else {
				// Single-threaded fine matching
				for t in 0 ..< num_targets {
					best_d: u32 = max(u32)
					best_i: int = -1
					target := targets[t * feat_len :]
					kb := global_best[t * K :]

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
						best_i = global_best[t * K]
					}
					results[t] = best_i
				}
			}
		} else {
			for t in 0 ..< num_targets {
				results[t] = global_best[t * K]
			}
		}

		delete(global_dist)
		delete(global_best)
		delete(threads)
		delete(work_items)
		delete(local_dists)
		delete(local_bests)
	} else {
		// Single-threaded fallback
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
			// Use threading for fine matching if we have enough targets
			fine_threads := min(num_cores, num_targets / 16)

			if fine_threads > 1 {
				targets_per_thread := num_targets / fine_threads
				fine_work := make([]Fine_Work, fine_threads)
				fine_threads_arr := make([]^thread.Thread, fine_threads)

				for ti in 0 ..< fine_threads {
					start := ti * targets_per_thread
					end := start + targets_per_thread
					if ti == fine_threads - 1 {
						end = num_targets
					}

					fine_work[ti] = Fine_Work {
						lib = lib,
						targets = targets,
						target_start = start,
						target_end = end,
						feat_len = feat_len,
						K = K,
						coarse_best = merged_best,
						results = results,
					}

					t := thread.create(fine_match_thread_proc)
					t.data = &fine_work[ti]
					thread.start(t)
					fine_threads_arr[ti] = t
				}

				// Wait for all fine threads to finish
				for ti in 0 ..< fine_threads {
					thread.join(fine_threads_arr[ti])
				}

				delete(fine_work)
				delete(fine_threads_arr)
			} else {
				// Single-threaded fine matching
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
			}
		} else {
			for t in 0 ..< num_targets {
				results[t] = merged_best[t * K]
			}
		}
	}
}

match_batch :: proc(lib, targets: []u8, n_pages, num_targets, feat_len: int, results: []int) {
	match_batch_coarse(lib, targets, n_pages, num_targets, feat_len, feat_len, results)
}
