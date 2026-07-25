package main

import "core:fmt"
import "core:strings"
import "core:os"
import "core:strconv"

// ── Context ──
CLI_Ctx :: struct {
	verbose:    bool,
	quiet:      bool,
	json_mode:  bool,
	threads:    int,  // 0 = auto
}

g_cli: CLI_Ctx

// ── Option store (flat key=value pairs) ──
OPT_MAX :: 128
Opt_Entry :: struct {
    name:  string,
    value: string,
}
g_opts:  [OPT_MAX]Opt_Entry
g_nopts: int

cli_store :: proc(name, value: string) {
	for i in 0 ..< g_nopts {
		if g_opts[i].name == name {
			g_opts[i].value = strings.clone(value, context.allocator)
			return
		}
	}
	if g_nopts < OPT_MAX {
		g_opts[g_nopts].name = strings.clone(name, context.allocator)
		g_opts[g_nopts].value = strings.clone(value, context.allocator)
		g_nopts += 1
	}
}

cli_get :: proc(name, def: string) -> string {
	for i in 0 ..< g_nopts {
		if g_opts[i].name == name {
			return g_opts[i].value
		}
	}
	return def
}

cli_opt_str :: proc(name, def: string) -> string {
	return cli_get(name, def)
}

cli_opt_int :: proc(name: string, def: int) -> int {
	v := cli_get(name, "")
	if len(v) > 0 {
		result, ok := strconv.parse_int(v)
		if ok { return result }
	}
	return def
}

cli_opt_f64 :: proc(name: string, def: f64) -> f64 {
	v := cli_get(name, "")
	if len(v) > 0 {
		result, ok := strconv.parse_f64(v)
		if ok { return result }
	}
	return def
}

cli_has :: proc(name: string) -> bool {
	for i in 0 ..< g_nopts {
		if g_opts[i].name == name {
			return true
		}
	}
	return false
}

// ── Argument parser ──
cli_parse :: proc(args: []string) {
	i := 1
	for i < len(args) {
		arg := args[i]
		switch {
		case arg == "--verbose" || arg == "-v":
			g_cli.verbose = true
		case arg == "--quiet" || arg == "-q":
			g_cli.quiet = true
		case arg == "--json":
			g_cli.json_mode = true
		case strings.has_prefix(arg, "--threads="):
			v := strings.trim_prefix(arg, "--threads=")
			cli_store("threads", v)
		case arg == "--threads" && i + 1 < len(args):
			i += 1
			cli_store("threads", args[i])
		case arg == "--":
			i += 1
		case strings.has_prefix(arg, "--"):
			eq := strings.index(arg, "=")
			if eq >= 0 {
				cli_store(arg[2:eq], arg[eq + 1:])
			} else if i + 1 < len(args) && len(args[i+1]) > 0 && args[i+1][0] != '-' {
				i += 1
				cli_store(arg[2:], args[i])
			} else {
				cli_store(arg[2:], "1")
			}
		case len(arg) > 1 && arg[0] == '-' && arg[1] != '-':
			flag := arg[1:2]
			cli_store(flag, "1")
		}
		i += 1
	}
}

// ── Output helpers ──
cli_info :: proc(msg: string, args: ..any) {
	if g_cli.quiet { return }
	if g_cli.json_mode {
		fmt.eprintf("{\"level\":\"info\",\"message\":\"%s\"}", fmt.tprintf(msg, ..args))
		return
	}
	fmt.eprint("\033[1;36m[info]\033[0m ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

cli_warn :: proc(msg: string, args: ..any) {
	if g_cli.json_mode {
		fmt.eprintf("{\"level\":\"warn\",\"message\":\"%s\"}", fmt.tprintf(msg, ..args))
		return
	}
	fmt.eprint("\033[1;33m[warn]\033[0m ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

cli_error :: proc(msg: string, args: ..any) {
	if g_cli.json_mode {
		fmt.eprintf("{\"level\":\"error\",\"message\":\"%s\"}", fmt.tprintf(msg, ..args))
		return
	}
	fmt.eprint("\033[1;31m[error]\033[0m ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

cli_die :: proc(msg: string, args: ..any) -> ! {
	if g_cli.json_mode {
		fmt.eprintf("{\"level\":\"fatal\",\"message\":\"%s\"}", fmt.tprintf(msg, ..args))
	} else {
		fmt.eprint("\033[1;31m[fatal]\033[0m ")
		fmt.eprintf(msg, ..args)
		fmt.eprintf("\n")
	}
	os.exit(1)
}

// ── Progress ──
g_last_progress: f64 = -1.0

cli_progress_frame :: proc(label: string, frame, total_frames: int, fps, cache_hit_pct: f64) {
	if g_cli.quiet || g_cli.json_mode { return }
	pct: f64 = 0.0
	if total_frames > 0 { pct = f64(frame) / f64(total_frames) * 100.0 }
	if pct - g_last_progress < 1.0 && g_last_progress >= 0.0 { return }
	g_last_progress = pct
	fmt.eprint("\r\033[K")
	fmt.eprintfln("\033[1;32m[%s]\033[0m frame %d/%d (%.1f%%) | %.1f fps | cache %.1f%%",
	              label, frame, total_frames, pct, fps, cache_hit_pct)
	os.flush(os.stderr)
}

cli_progress_done :: proc(summary: string) {
	if g_cli.quiet { return }
	fmt.eprint("\r\033[K")
	fmt.eprintfln("\033[1;32m[done]\033[0m %s", summary)
}

cli_progress_stage :: proc(stage: string, percent: int) {
	if g_cli.quiet || g_cli.json_mode { return }
	fmt.eprint("\r\033[K")
	fmt.eprintfln("\033[1;34m[stage]\033[0m %s: %d%%", stage, percent)
}
