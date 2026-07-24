package main

import "core:os"
import "core:strconv"
import "core:strings"

system_detect :: proc() -> SystemConfig {
    r: SystemConfig

    r.cpu_cores = os.get_processor_core_count()
    if r.cpu_cores <= 0 { r.cpu_cores = 1 }

    r.num_threads = os.get_processor_core_count()
    if r.num_threads <= 0 { r.num_threads = 1 }

    r.total_memory_bytes = 16 * 1024 * 1024 * 1024
    desc: os.Process_Desc = {
        command = {"sysctl", "-n", "hw.memsize"},
    }
    if state, stdout, _, err := os.process_exec(desc, context.allocator); err == nil && state.success {
        if mem_val, ok := strconv.parse_u64(strings.trim_space(string(stdout))); ok && mem_val > 0 {
            r.total_memory_bytes = mem_val
        }
        delete(stdout)
    }

    r.cache_budget_bytes = r.total_memory_bytes / 4
    r.cache_enabled = true

    return r
}
