package main

import "core:fmt"

system_detect :: proc() -> SystemConfig {
    r: SystemConfig
    r.total_memory_bytes = 0
    r.cpu_cores = 1
    r.num_threads = 1
    r.cache_budget_bytes = 64 * 1024 * 1024
    r.cache_enabled = true
    return r
}
