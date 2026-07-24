package main

import "core:sys/posix"
import "core:fmt"

// system_detect detects CPU cores and physical memory at runtime.
system_detect :: proc() -> SystemConfig {
    r: SystemConfig
    r.total_memory_bytes = detect_total_memory()
    r.cpu_cores = detect_cores()
    r.cache_budget_bytes = system_cache_budget(r.total_memory_bytes)
    r.cache_enabled = r.cache_budget_bytes > 0
    r.num_threads = r.cpu_cores
    if r.total_memory_bytes > 0 && r.total_memory_bytes < 512 * 1024 * 1024 {
        r.num_threads = 1
    }
    return r
}

detect_cores :: proc() -> int {
    when ODIN_OS == .Linux || ODIN_OS == .Darwin {
        n := int(posix.sysconf(posix._SC_NPROCESSORS_ONLN))
        if n > 0 { return n }
    }
    return 1
}

detect_total_memory :: proc() -> u64 {
    when ODIN_OS == .Linux || ODIN_OS == .Darwin {
        page_size := u64(posix.sysconf(posix._SC_PAGE_SIZE))
        pages := u64(posix.sysconf(posix._SC_PHYS_PAGES))
        if pages > 0 && page_size > 0 {
            return page_size * pages
        }
    }
    return 0
}

system_cache_budget :: proc(total_memory: u64) -> u64 {
    if total_memory == 0 { return 64 * 1024 * 1024 }
    if total_memory < 512 * 1024 * 1024 { return 0 }
    if total_memory < 1024 * 1024 * 1024 { return total_memory / 10 }
    budget := total_memory / 4
    cap := u64(4 * 1024 * 1024 * 1024)
    if budget < cap { return budget }
    return cap
}
