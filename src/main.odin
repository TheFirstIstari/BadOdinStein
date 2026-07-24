package main

import "core:fmt"
import "core:os"
import "core:strings"

VERSION :: "1.0.0"

print_help :: proc() {
    fmt.eprintfln(
        "BadOdinStein v%s — tiled video encoder using PDF/image library matching\n" +
        "\n" +
        "Usage:\n" +
        "  badodin <command> [options]\n" +
        "\n" +
        "Commands:\n" +
        "  arrange  — decode video, match tiles against library, write manifests\n" +
        "  render   — assemble frames from manifests, encode output video\n" +
        "  build    — build source library (features.bin + registry.bin) from PDFs/images\n" +
        "\n" +
        "Run 'badodin <command> --help' for command-specific options.\n",
        VERSION)
}

print_arrange_help :: proc() {
    fmt.eprintfln(
        "BadOdinStein arrange — decode video, match tiles, write manifests\n" +
        "\n" +
        "Usage:\n" +
        "  badodin arrange --video <file> [options]\n" +
        "\n" +
        "Options:\n" +
        "  --video <file>         Input video file (required)\n" +
        "  --features <file>      Feature database (default: features.bin)\n" +
        "  --registry <file>      Registry (default: registry.bin)\n" +
        "  --manifests <dir>      Manifest output directory (default: manifests_greedy)\n" +
        "  --max-block <N>        Maximum block size in pixels (default: auto)\n" +
        "  --hero-min <N>         Minimum hero block size (default: 192)\n" +
        "  --max-frames <N>       Maximum frames to process (0 = all)\n" +
        "  --threads <N>          Thread count (0 = auto)\n" +
        "  --verbose, -v          Verbose output\n" +
        "  --quiet, -q            Suppress non-error output\n")
}

print_render_help :: proc() {
    fmt.eprintfln(
        "BadOdinStein render — assemble frames from manifests, encode output video\n" +
        "\n" +
        "Usage:\n" +
        "  badodin render [options]\n" +
        "\n" +
        "Options:\n" +
        "  --manifests <dir>      Manifest directory (default: manifests_greedy)\n" +
        "  --registry <file>      Registry (default: registry.bin)\n" +
        "  --output <file>        Output video (default: output.mov)\n" +
        "  --width <N>            Output width (auto-detect from manifest)\n" +
        "  --height <N>           Output height (auto-detect from manifest)\n" +
        "  --fps <N>              Output FPS (auto-detect from sidecar)\n" +
        "  --channels <N>         1=grayscale, 3=color (default: 1)\n" +
        "  --max-frames <N>       Maximum frames to render (0 = all)\n" +
        "  --threads <N>          Thread count (0 = auto)\n" +
        "  --verbose, -v          Verbose output\n" +
        "  --quiet, -q            Suppress non-error output\n")
}

print_build_help :: proc() {
    fmt.eprintfln(
        "BadOdinStein build — build source library from PDFs and images\n" +
        "\n" +
        "Usage:\n" +
        "  badodin build <sources_dir> [options]\n" +
        "\n" +
        "Options:\n" +
        "  --bits <N>             Bits per cell G, 1-8 (default: 1)\n" +
        "  --no-edges             Disable edge detection features\n" +
        "  --color                Include BGR color features\n" +
        "  --scales <list>        Comma-separated scale levels (default: 32,64,128)\n" +
        "  --out <file>           Output features file (default: features.bin)\n" +
        "  --threads <N>          Thread count (0 = auto)\n" +
        "  --verbose, -v          Verbose output\n" +
        "  --quiet, -q            Suppress non-error output\n")
}

main :: proc() {
    args := os.args

    // Skip program name
    if len(args) < 2 {
        print_help()
        return
    }

    cmd := args[1]

    switch cmd {
    case "arrange":
        // Parse flags after command
        cli_parse(args)
        if cli_has("help") || cli_has("h") {
            print_arrange_help()
            return
        }
        arrange_main()

    case "render":
        cli_parse(args)
        if cli_has("help") || cli_has("h") {
            print_render_help()
            return
        }
        render_main()

    case "build", "build-library":
        cli_parse(args)
        if cli_has("help") || cli_has("h") {
            print_build_help()
            return
        }
        build_main()

    case "help", "--help", "-h":
        print_help()

    case "--version", "-V":
        fmt.eprintfln("badodin v%s", VERSION)

    case:
        fmt.eprintfln("Unknown command: %s", cmd)
        fmt.eprintfln("Run 'badodin help' for usage.")
        os.exit(1)
    }
}
