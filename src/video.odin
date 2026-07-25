package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// ══════════════════════════════════════════════════════════════════════════════
// FFmpeg FFI — video decode / encode via libavformat, libavcodec,
// libavutil, libswscale.
// Pure-Odin pointer arithmetic for struct field access (no C bridge).
// ══════════════════════════════════════════════════════════════════════════════

// ── Foreign imports ─────────────────────────────────────────────────────────

foreign import libavformat "system:avformat"
foreign import libavcodec  "system:avcodec"
foreign import libavutil   "system:avutil"
foreign import libswscale  "system:swscale"

// ── Opaque types ───────────────────────────────────────────────────────────

AVCodec           :: rawptr
SwsContext        :: rawptr
AVIOContext       :: rawptr
AVFormatContext   :: rawptr
AVCodecContext    :: rawptr
AVCodecParameters :: rawptr
AVFrame           :: rawptr
AVPacket          :: rawptr
AVStream          :: rawptr

// All FFmpeg struct handles are opaque raw pointers.
// Field access is done via pure-Odin pointer arithmetic helpers below.

// ── AVRational (used by value in av_packet_rescale_ts) ──────────────────────

AVRational :: struct { num: c.int, den: c.int }

// ══════════════════════════════════════════════════════════════════════════════
// Pure-Odin FFmpeg struct field accessors (pointer arithmetic)
//
// Offsets derived from FFmpeg 8.1.2 headers on macOS ARM64.
// ALL OFFSETS FOLLOW THE C ABI LAYOUT (default Odin struct layout = C ABI).
//
// WARNING: These offsets are version-specific and platform-specific. A different
// FFmpeg version or a different platform (Linux x86_64, ARM64 Linux, etc.) will
// cause SILENT MEMORY CORRUPTION — not a crash. Do not change the FFmpeg version
// or build platform without updating these offsets.
// ══════════════════════════════════════════════════════════════════════════════

// -- AVFormatContext offsets ------------------------------------------------
//   offset 0:  av_class    (ptr, 8)
//   offset 8:  iformat     (ptr, 8)
//   offset 16: oformat     (ptr, 8)
//   offset 24: priv_data   (ptr, 8)
//   offset 32: pb          (ptr, 8)
//   offset 40: ctx_flags   (int, 4)
//   offset 44: nb_streams  (uint, 4)
//   offset 48: streams     (ptr, 8)  → AVStream **

AV_FMT_NB_STREAMS :: uintptr(44)
AV_FMT_STREAMS    :: uintptr(48)
AV_FMT_PB         :: uintptr(32)
AV_FMT_OFORMAT    :: uintptr(16)

fmtc_nb_streams :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_FMT_NB_STREAMS)^
}
fmtc_streams :: proc(ctx: rawptr, i: c.int) -> rawptr {
    streams_arr := (^rawptr)(uintptr(ctx) + AV_FMT_STREAMS)^
    return (([^]rawptr)(streams_arr))[int(i)]
}
fmtc_pb :: proc(ctx: rawptr) -> rawptr {
    return (^rawptr)(uintptr(ctx) + AV_FMT_PB)^
}
fmtc_pb_ptr :: proc(ctx: rawptr) -> ^rawptr {
    return (^rawptr)(uintptr(ctx) + AV_FMT_PB)
}
fmtc_oformat :: proc(ctx: rawptr) -> rawptr {
    return (^rawptr)(uintptr(ctx) + AV_FMT_OFORMAT)^
}

// -- AVStream offsets -------------------------------------------------------
//   offset 0:  av_class          (ptr, 8)
//   offset 8:  index             (int, 4)
//   offset 12: id                (int, 4)
//   offset 16: codecpar          (ptr, 8)
//   offset 24: priv_data         (ptr, 8)
//   offset 32: time_base         (AVRational, 8)
//   offset 40: start_time        (i64, 8)
//   offset 48: duration          (i64, 8)
//   offset 56: nb_frames         (i64, 8)
//   offset 64: disposition       (int, 4)
//   offset 68: discard           (int, 4)
//   offset 72: sample_aspect_ratio (AVRational, 8)
//   offset 80: metadata          (ptr, 8)
//   offset 88: avg_frame_rate    (AVRational, 8)
//   offset 96: attached_pic      (AVPacket, 104 bytes)
//   offset 200: event_flags      (int, 4)
//   offset 204: r_frame_rate     (AVRational, 8)
//   offset 212: pts_wrap_bits    (int, 4)

AV_STREAM_INDEX           :: uintptr(8)
AV_STREAM_CODECPAR        :: uintptr(16)
AV_STREAM_TIME_BASE       :: uintptr(32)
AV_STREAM_AVG_FRAME_RATE  :: uintptr(88)
AV_STREAM_R_FRAME_RATE    :: uintptr(204)

stream_index :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_INDEX)^
}
stream_codecpar :: proc(s: rawptr) -> rawptr {
    return (^rawptr)(uintptr(s) + AV_STREAM_CODECPAR)^
}
stream_time_base_num :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_TIME_BASE)^
}
stream_time_base_den :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_TIME_BASE + 4)^
}
stream_avg_frame_rate_num :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_AVG_FRAME_RATE)^
}
stream_avg_frame_rate_den :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_AVG_FRAME_RATE + 4)^
}
stream_r_frame_rate_num :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_R_FRAME_RATE)^
}
stream_r_frame_rate_den :: proc(s: rawptr) -> c.int {
    return (^c.int)(uintptr(s) + AV_STREAM_R_FRAME_RATE + 4)^
}
stream_set_time_base :: proc(s: rawptr, num, den: c.int) {
    (^c.int)(uintptr(s) + AV_STREAM_TIME_BASE)^ = num
    (^c.int)(uintptr(s) + AV_STREAM_TIME_BASE + 4)^ = den
}

// -- AVCodecParameters offsets ----------------------------------------------
//   offset 0:  codec_type   (int, 4)
//   offset 4:  codec_id     (int, 4)
//   offset 8:  codec_tag    (uint32, 4)
//   offset 12: _pad0        (4 bytes)
//   offset 16: extradata    (ptr, 8)
//   offset 24: extradata_size (int, 4)
//   offset 28: _pad1        (4 bytes)
//   offset 32: coded_side_data (ptr, 8)
//   offset 36: nb_coded_side_data (int, 4)
//   offset 40: format       (int, 4)
//   offset 44: _pad2        (4 bytes)
//   offset 48: bit_rate     (i64, 8)
//   offset 56: bits_per_coded_sample (int, 4)
//   offset 60: bits_per_raw_sample (int, 4)
//   offset 64: profile      (int, 4)
//   offset 68: level        (int, 4)
//   offset 72: width        (int, 4)
//   offset 76: height       (int, 4)

AV_CODECPAR_CODEC_TYPE :: uintptr(0)
AV_CODECPAR_CODEC_ID   :: uintptr(4)
AV_CODECPAR_FORMAT     :: uintptr(40)
AV_CODECPAR_WIDTH      :: uintptr(72)
AV_CODECPAR_HEIGHT     :: uintptr(76)

codecpar_codec_type :: proc(cp: rawptr) -> c.int {
    return (^c.int)(uintptr(cp) + AV_CODECPAR_CODEC_TYPE)^
}
codecpar_codec_id :: proc(cp: rawptr) -> c.int {
    return (^c.int)(uintptr(cp) + AV_CODECPAR_CODEC_ID)^
}
codecpar_format :: proc(cp: rawptr) -> c.int {
    return (^c.int)(uintptr(cp) + AV_CODECPAR_FORMAT)^
}
codecpar_width :: proc(cp: rawptr) -> c.int {
    return (^c.int)(uintptr(cp) + AV_CODECPAR_WIDTH)^
}
codecpar_height :: proc(cp: rawptr) -> c.int {
    return (^c.int)(uintptr(cp) + AV_CODECPAR_HEIGHT)^
}

// -- AVCodecContext offsets -------------------------------------------------
//   offset 0:  av_class         (ptr, 8)
//   offset 8:  log_level_offset (int, 4)
//   offset 12: codec_type       (int, 4)
//   offset 16: codec            (ptr, 8)
//   offset 24: codec_id         (int, 4)
//   offset 28: codec_tag        (uint, 4)
//   offset 32: priv_data        (ptr, 8)
//   offset 40: internal         (ptr, 8)
//   offset 48: opaque           (ptr, 8)
//   offset 56: bit_rate         (i64, 8)
//   offset 64: flags            (int, 4)
//   offset 68: flags2           (int, 4)
//   offset 72: extradata        (ptr, 8)
//   offset 80: extradata_size   (int, 4)
//   offset 84: time_base        (AVRational: num=84, den=88)
//   offset 92: pkt_timebase     (AVRational)
//   offset 100: framerate       (AVRational)
//   offset 108: delay           (int, 4)
//   offset 112: width           (int, 4)
//   offset 116: height          (int, 4)
//   offset 136: pix_fmt         (int, 4)
//   ... (many fields) ...
//   offset 752: thread_count    (int, 4)
//   offset 756: thread_type     (int, 4)

AV_CODECCTX_WIDTH        :: uintptr(112)
AV_CODECCTX_HEIGHT       :: uintptr(116)
AV_CODECCTX_PIX_FMT     :: uintptr(136)
AV_CODECCTX_TIME_BASE    :: uintptr(84)
AV_CODECCTX_FLAGS        :: uintptr(64)
AV_CODECCTX_THREAD_COUNT :: uintptr(752)
AV_CODECCTX_THREAD_TYPE  :: uintptr(756)

codecctx_width :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_CODECCTX_WIDTH)^
}
codecctx_height :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_CODECCTX_HEIGHT)^
}
codecctx_pix_fmt :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_CODECCTX_PIX_FMT)^
}
codecctx_time_base_num :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_CODECCTX_TIME_BASE)^
}
codecctx_time_base_den :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_CODECCTX_TIME_BASE + 4)^
}
codecctx_flags :: proc(ctx: rawptr) -> c.int {
    return (^c.int)(uintptr(ctx) + AV_CODECCTX_FLAGS)^
}
codecctx_set_width :: proc(ctx: rawptr, v: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_WIDTH)^ = v
}
codecctx_set_height :: proc(ctx: rawptr, v: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_HEIGHT)^ = v
}
codecctx_set_pix_fmt :: proc(ctx: rawptr, v: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_PIX_FMT)^ = v
}
codecctx_set_time_base :: proc(ctx: rawptr, num, den: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_TIME_BASE)^ = num
    (^c.int)(uintptr(ctx) + AV_CODECCTX_TIME_BASE + 4)^ = den
}
codecctx_flags_or :: proc(ctx: rawptr, v: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_FLAGS)^ |= v
}
codecctx_set_thread_count :: proc(ctx: rawptr, v: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_THREAD_COUNT)^ = v
}
codecctx_set_thread_type :: proc(ctx: rawptr, v: c.int) {
    (^c.int)(uintptr(ctx) + AV_CODECCTX_THREAD_TYPE)^ = v
}

// -- AVOutputFormat offsets -------------------------------------------------
//   offset 0:  name         (ptr, 8)
//   offset 8:  long_name    (ptr, 8)
//   offset 16: mime_type    (ptr, 8)
//   offset 24: extensions   (ptr, 8)
//   offset 32: audio_codec  (int, 4)
//   offset 36: video_codec  (int, 4)
//   offset 40: subtitle_codec (int, 4)
//   offset 44: flags        (int, 4)

AV_OFMT_FLAGS       :: uintptr(44)
AV_OFMT_VIDEO_CODEC :: uintptr(36)

ofmt_flags :: proc(fmt: rawptr) -> c.int {
    return (^c.int)(uintptr(fmt) + AV_OFMT_FLAGS)^
}
ofmt_video_codec :: proc(fmt: rawptr) -> c.int {
    return (^c.int)(uintptr(fmt) + AV_OFMT_VIDEO_CODEC)^
}

// -- AVFrame offsets --------------------------------------------------------
//   offset 0:   data[8]           ([8]rawptr, 64 bytes)
//   offset 64:  linesize[8]       ([8]int, 32 bytes)
//   offset 96:  extended_data     (ptr, 8)
//   offset 104: width             (int, 4)
//   offset 108: height            (int, 4)
//   offset 112: nb_samples        (int, 4)
//   offset 116: format            (int, 4)
//   offset 120: pict_type         (int, 4)
//   offset 124: sample_aspect_ratio (AVRational, 8)
//   offset 132: _pad              (4 bytes)
//   offset 136: pts               (i64, 8)

AV_FRAME_DATA      :: uintptr(0)
AV_FRAME_LINESIZE  :: uintptr(64)
AV_FRAME_WIDTH     :: uintptr(104)
AV_FRAME_HEIGHT    :: uintptr(108)
AV_FRAME_FORMAT    :: uintptr(116)
AV_FRAME_PTS       :: uintptr(136)

frame_data :: proc(frame: rawptr, i: c.int) -> rawptr {
    return (([^]rawptr)(uintptr(frame) + AV_FRAME_DATA))[int(i)]
}
frame_linesize :: proc(frame: rawptr, i: c.int) -> c.int {
    return (([^]c.int)(uintptr(frame) + AV_FRAME_LINESIZE))[int(i)]
}
frame_width :: proc(frame: rawptr) -> c.int {
    return (^c.int)(uintptr(frame) + AV_FRAME_WIDTH)^
}
frame_height :: proc(frame: rawptr) -> c.int {
    return (^c.int)(uintptr(frame) + AV_FRAME_HEIGHT)^
}
frame_format :: proc(frame: rawptr) -> c.int {
    return (^c.int)(uintptr(frame) + AV_FRAME_FORMAT)^
}
frame_pts :: proc(frame: rawptr) -> i64 {
    return (^i64)(uintptr(frame) + AV_FRAME_PTS)^
}
frame_set_pts :: proc(frame: rawptr, v: i64) {
    (^i64)(uintptr(frame) + AV_FRAME_PTS)^ = v
}
frame_set_format :: proc(frame: rawptr, v: c.int) {
    (^c.int)(uintptr(frame) + AV_FRAME_FORMAT)^ = v
}
frame_set_width :: proc(frame: rawptr, v: c.int) {
    (^c.int)(uintptr(frame) + AV_FRAME_WIDTH)^ = v
}
frame_set_height :: proc(frame: rawptr, v: c.int) {
    (^c.int)(uintptr(frame) + AV_FRAME_HEIGHT)^ = v
}

// -- AVPacket offsets -------------------------------------------------------
//   offset 0:  buf            (ptr, 8)
//   offset 8:  pts            (i64, 8)
//   offset 16: dts            (i64, 8)
//   offset 24: data           (ptr, 8)
//   offset 32: size           (int, 4)
//   offset 36: stream_index   (int, 4)
//   offset 40: flags          (int, 4)
//   offset 44: _pad0          (4 bytes)
//   offset 48: side_data      (ptr, 8)
//   offset 56: side_data_elems (int, 4)
//   offset 60: _pad1          (4 bytes)
//   offset 64: duration       (i64, 8)
//   offset 72: pos            (i64, 8)
//   offset 80: opaque         (ptr, 8)
//   offset 88: opaque_ref     (ptr, 8)
//   offset 96: time_base      (AVRational, 8)

AV_PACKET_STREAM_INDEX :: uintptr(36)
AV_PACKET_DATA          :: uintptr(24)

packet_stream_index :: proc(pkt: rawptr) -> c.int {
    return (^c.int)(uintptr(pkt) + AV_PACKET_STREAM_INDEX)^
}
packet_data :: proc(pkt: rawptr) -> rawptr {
    return (^rawptr)(uintptr(pkt) + AV_PACKET_DATA)^
}
packet_set_stream_index :: proc(pkt: rawptr, v: c.int) {
    (^c.int)(uintptr(pkt) + AV_PACKET_STREAM_INDEX)^ = v
}

// -- SwsContext (opaque, no field access) -----------------------------------

// ── Foreign procedures (libav*) ─────────────────────────────────────────────

foreign libavformat {
    avformat_network_init :: proc "c" () -> c.int ---
    avformat_open_input :: proc "c" (ctxt: ^^AVFormatContext, url: cstring, fmt: rawptr, opts: rawptr) -> c.int ---
    avformat_find_stream_info :: proc "c" (ctxt: ^AVFormatContext, opts: rawptr) -> c.int ---
    av_read_frame :: proc "c" (ctxt: ^AVFormatContext, pkt: ^AVPacket) -> c.int ---
    avformat_close_input :: proc "c" (ctxt: ^^AVFormatContext) ---
    avformat_alloc_output_context2 :: proc "c" (ctxt: ^^AVFormatContext, ofmt: rawptr, name: cstring, url: cstring) -> c.int ---
    avformat_free_context :: proc "c" (ctxt: ^AVFormatContext) ---
    avformat_new_stream :: proc "c" (ctxt: ^AVFormatContext, c: rawptr) -> ^AVStream ---
    avformat_write_header :: proc "c" (ctxt: ^AVFormatContext, opts: rawptr) -> c.int ---
    av_interleaved_write_frame :: proc "c" (ctxt: ^AVFormatContext, pkt: ^AVPacket) -> c.int ---
    av_write_trailer :: proc "c" (ctxt: ^AVFormatContext) ---
    avio_open :: proc "c" (pb: ^AVIOContext, url: cstring, flags: c.int) -> c.int ---
    avio_closep :: proc "c" (pb: ^AVIOContext) -> c.int ---
    av_guess_format :: proc "c" (short_name: cstring, filename: cstring, mime_type: cstring) -> rawptr ---
}

foreign libavcodec {
    avcodec_find_decoder :: proc "c" (id: c.int) -> rawptr ---
    avcodec_find_encoder_by_name :: proc "c" (name: cstring) -> rawptr ---
    avcodec_find_encoder :: proc "c" (id: c.int) -> rawptr ---
    avcodec_alloc_context3 :: proc "c" (codec: rawptr) -> ^AVCodecContext ---
    avcodec_free_context :: proc "c" (ctx: ^^AVCodecContext) ---
    avcodec_parameters_to_context :: proc "c" (ctx: ^AVCodecContext, par: rawptr) -> c.int ---
    avcodec_parameters_from_context :: proc "c" (par: rawptr, ctx: ^AVCodecContext) -> c.int ---
    avcodec_open2 :: proc "c" (ctx: ^AVCodecContext, codec: rawptr, opts: rawptr) -> c.int ---
    avcodec_send_packet :: proc "c" (ctx: ^AVCodecContext, pkt: ^AVPacket) -> c.int ---
    avcodec_receive_frame :: proc "c" (ctx: ^AVCodecContext, frame: ^AVFrame) -> c.int ---
    avcodec_send_frame :: proc "c" (ctx: ^AVCodecContext, frame: ^AVFrame) -> c.int ---
    avcodec_receive_packet :: proc "c" (ctx: ^AVCodecContext, pkt: ^AVPacket) -> c.int ---
    av_packet_alloc :: proc "c" () -> ^AVPacket ---
    av_packet_unref :: proc "c" (pkt: ^AVPacket) ---
    av_packet_free :: proc "c" (pkt: ^^AVPacket) ---
    av_packet_rescale_ts :: proc "c" (pkt: ^AVPacket, tb_src: AVRational, tb_dst: AVRational) ---
}

foreign libavutil {
    av_frame_alloc :: proc "c" () -> ^AVFrame ---
    av_frame_free :: proc "c" (frame: ^^AVFrame) ---
    av_frame_unref :: proc "c" (frame: AVFrame) ---
    av_frame_get_buffer :: proc "c" (frame: AVFrame, align: c.int) -> c.int ---
    av_get_pix_fmt :: proc "c" (name: cstring) -> c.int ---
}

foreign libswscale {
    sws_getContext :: proc "c" (
        srcW, srcH, srcFmt: c.int,
        dstW, dstH, dstFmt: c.int,
        flags: c.int,
        srcFilter, dstFilter: rawptr,
        param: rawptr,
    ) -> rawptr ---
    sws_freeContext :: proc "c" (ctx: rawptr) ---
    sws_scale :: proc "c" (
        ctx: rawptr,
        srcSlice: rawptr, srcStride: rawptr,
        srcSliceY: c.int, srcSliceH: c.int,
        dstSlice: rawptr, dstStride: rawptr,
    ) -> c.int ---
}

// ── Constants (FFmpeg 8.x) ─────────────────────────────────────────────────

AV_PIX_FMT_BGR24           :: c.int(3)
AV_PIX_FMT_RGB24           :: c.int(2)
AV_PIX_FMT_GRAY8           :: c.int(8)
AVMEDIA_TYPE_VIDEO         :: c.int(0)
AVERROR_EAGAIN             :: c.int(-35)
AVERROR_EOF                :: c.int(-541478725)
AVIO_FLAG_WRITE            :: c.int(2)
SWS_BILINEAR               :: c.int(2)
AV_CODEC_FLAG_GLOBAL_HEADER :: c.int(1 << 22)
FF_THREAD_SLICE            :: c.int(2)
AVFMT_NOFILE               :: c.int(1)
AVFMT_GLOBALHEADER         :: c.int(0x00100000)

// ── Helpers ─────────────────────────────────────────────────────────────────

network_inited: bool

clone_to_cstr :: proc(s: string) -> (cstring, []u8) {
	buf := make([]u8, len(s) + 1)
	copy(buf[:len(s)], s)
	buf[len(s)] = 0
	return cstring(raw_data(buf)), buf
}

MAX_VIDEO_PLANES :: 8

// ══════════════════════════════════════════════════════════════════════════════
// VideoDecoder — demux + decode a single video stream to BGR24 frames.
// ══════════════════════════════════════════════════════════════════════════════

VideoDecoder :: struct {
	fmt_ctx:        ^AVFormatContext,
	video_stream:   int,
	codec:          rawptr,
	codec_ctx:      ^AVCodecContext,
	sws:            SwsContext,
	frame:          ^AVFrame,
	pkt:            ^AVPacket,
	width:          int,
	height:         int,
	fps:            f64,
	eof:            bool,
}

video_decoder_open :: proc(path: string) -> ^VideoDecoder {
	if !network_inited {
		avformat_network_init()
		network_inited = true
	}

	dec := new(VideoDecoder)
	cpath, cpath_buf := clone_to_cstr(path)
	defer delete(cpath_buf)

	if avformat_open_input(&dec.fmt_ctx, cpath, nil, nil) != 0 {
		free(dec)
		return nil
	}
	if avformat_find_stream_info(dec.fmt_ctx, nil) < 0 {
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}

	dec.video_stream = -1
	nb_streams := fmtc_nb_streams(dec.fmt_ctx)
	for i in 0 ..< int(nb_streams) {
		stream := fmtc_streams(dec.fmt_ctx, c.int(i))
		if codecpar_codec_type(stream_codecpar(stream)) == AVMEDIA_TYPE_VIDEO {
			dec.video_stream = i
			break
		}
	}
	if dec.video_stream < 0 {
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}

	st := fmtc_streams(dec.fmt_ctx, c.int(dec.video_stream))
	dec.codec = avcodec_find_decoder(codecpar_codec_id(stream_codecpar(st)))
	if dec.codec == nil {
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}
	dec.codec_ctx = avcodec_alloc_context3(dec.codec)
	if dec.codec_ctx == nil {
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}
	if avcodec_parameters_to_context(dec.codec_ctx, stream_codecpar(st)) < 0 {
		avcodec_free_context(&dec.codec_ctx)
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}
	if avcodec_open2(dec.codec_ctx, dec.codec, nil) < 0 {
		avcodec_free_context(&dec.codec_ctx)
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}

	dec.width = int(codecctx_width(dec.codec_ctx))
	dec.height = int(codecctx_height(dec.codec_ctx))

	r_num := stream_r_frame_rate_num(st)
	r_den := stream_r_frame_rate_den(st)
	avg_num := stream_avg_frame_rate_num(st)
	avg_den := stream_avg_frame_rate_den(st)
	if r_num != 0 && r_den != 0 {
		dec.fps = f64(r_num) / f64(r_den)
	} else if avg_num != 0 && avg_den != 0 {
		dec.fps = f64(avg_num) / f64(avg_den)
	} else {
		dec.fps = 30.0
	}

	dec.sws = sws_getContext(
		c.int(dec.width), c.int(dec.height), codecctx_pix_fmt(dec.codec_ctx),
		c.int(dec.width), c.int(dec.height), AV_PIX_FMT_BGR24,
		SWS_BILINEAR,
		nil, nil, nil,
	)
	if dec.sws == nil {
		avcodec_free_context(&dec.codec_ctx)
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}

	dec.frame = av_frame_alloc()
	dec.pkt = av_packet_alloc()
	if dec.frame == nil || dec.pkt == nil {
		av_frame_free(&dec.frame)
		av_packet_free(&dec.pkt)
		sws_freeContext(dec.sws)
		avcodec_free_context(&dec.codec_ctx)
		avformat_close_input(&dec.fmt_ctx)
		free(dec)
		return nil
	}

	return dec
}

video_decoder_read_frame :: proc(dec: ^VideoDecoder, out: ^Img) -> bool {
	if dec.eof { return false }
	out.pixels = nil
	out.w, out.h = 0, 0

	for {
		ret := av_read_frame(dec.fmt_ctx, dec.pkt)
		if ret < 0 {
			dec.eof = true
			return false
		}
		if packet_stream_index(dec.pkt) != c.int(dec.video_stream) {
			av_packet_unref(dec.pkt)
			continue
		}
		ret = avcodec_send_packet(dec.codec_ctx, dec.pkt)
		av_packet_unref(dec.pkt)
		if ret < 0 { continue }

		for {
			ret = avcodec_receive_frame(dec.codec_ctx, dec.frame)
			if ret == AVERROR_EAGAIN || ret == AVERROR_EOF { break }
			if ret < 0 { return false }

			w, h := dec.width, dec.height
			pixels := make([]u8, w * h * 3)
			dst_slices: [1]rawptr
			dst_slices[0] = raw_data(pixels)
			dst_stride := c.int(w * 3)

			src_data: [MAX_VIDEO_PLANES]rawptr
			src_linesize: [MAX_VIDEO_PLANES]c.int
			for i in 0 ..< MAX_VIDEO_PLANES {
				src_data[i] = frame_data(dec.frame, c.int(i))
				src_linesize[i] = frame_linesize(dec.frame, c.int(i))
			}

			sws_scale(
				dec.sws,
				&src_data, &src_linesize,
				0, frame_height(dec.frame),
				&dst_slices, &dst_stride,
			)

			out.w, out.h = w, h
			out.channels = 3
			out.stride = int(dst_stride)
			out.pixels = pixels

			av_frame_unref(dec.frame)
			return true
		}
	}
}

video_decoder_close :: proc(dec: ^VideoDecoder) {
	if dec == nil { return }
	sws_freeContext(dec.sws)
	av_frame_free(&dec.frame)
	av_packet_free(&dec.pkt)
	avcodec_free_context(&dec.codec_ctx)
	avformat_close_input(&dec.fmt_ctx)
	free(dec)
}

// ══════════════════════════════════════════════════════════════════════════════
// Image file loader — load a single image (PNG/JPEG/etc.) via libav.
// ══════════════════════════════════════════════════════════════════════════════

video_image_load :: proc(path: string, out: ^Img) -> int {
	fmt_ctx: ^AVFormatContext
	cpath, cpath_buf := clone_to_cstr(path)
	defer delete(cpath_buf)

	if avformat_open_input(&fmt_ctx, cpath, nil, nil) != 0 { return -1 }
	if avformat_find_stream_info(fmt_ctx, nil) < 0 {
		avformat_close_input(&fmt_ctx)
		return -1
	}

	video_stream: int = -1
	nb_streams := fmtc_nb_streams(fmt_ctx)
	for i in 0 ..< int(nb_streams) {
		stream := fmtc_streams(fmt_ctx, c.int(i))
		if codecpar_codec_type(stream_codecpar(stream)) == AVMEDIA_TYPE_VIDEO {
			video_stream = i
			break
		}
	}
	if video_stream < 0 {
		avformat_close_input(&fmt_ctx)
		return -1
	}

	st := fmtc_streams(fmt_ctx, c.int(video_stream))
	codec := avcodec_find_decoder(codecpar_codec_id(stream_codecpar(st)))
	if codec == nil {
		avformat_close_input(&fmt_ctx)
		return -1
	}

	codec_ctx := avcodec_alloc_context3(codec)
	if codec_ctx == nil {
		avformat_close_input(&fmt_ctx)
		return -1
	}
	if avcodec_parameters_to_context(codec_ctx, stream_codecpar(st)) < 0 {
		avcodec_free_context(&codec_ctx)
		avformat_close_input(&fmt_ctx)
		return -1
	}
	if avcodec_open2(codec_ctx, codec, nil) < 0 {
		avcodec_free_context(&codec_ctx)
		avformat_close_input(&fmt_ctx)
		return -1
	}

	sws := sws_getContext(
		codecctx_width(codec_ctx), codecctx_height(codec_ctx), codecctx_pix_fmt(codec_ctx),
		codecctx_width(codec_ctx), codecctx_height(codec_ctx), AV_PIX_FMT_BGR24,
		SWS_BILINEAR,
		nil, nil, nil,
	)
	if sws == nil {
		avcodec_free_context(&codec_ctx)
		avformat_close_input(&fmt_ctx)
		return -1
	}

	frame := av_frame_alloc()
	pkt := av_packet_alloc()
	got_frame: bool

	for av_read_frame(fmt_ctx, pkt) >= 0 {
		if packet_stream_index(pkt) != c.int(video_stream) {
			av_packet_unref(pkt)
			continue
		}
		ret := avcodec_send_packet(codec_ctx, pkt)
		av_packet_unref(pkt)
		if ret < 0 { continue }
		ret = avcodec_receive_frame(codec_ctx, frame)
		if ret == 0 {
			got_frame = true
			break
		}
		if ret == AVERROR_EOF { break }
	}
	if !got_frame {
		avcodec_send_packet(codec_ctx, nil)
		if avcodec_receive_frame(codec_ctx, frame) == 0 {
			got_frame = true
		}
	}

	result: int = -1
	if got_frame {
		w, h := int(codecctx_width(codec_ctx)), int(codecctx_height(codec_ctx))
		pixels := make([]u8, w * h * 3)
		dst_slices: [1]rawptr
		dst_slices[0] = raw_data(pixels)
		dst_stride := c.int(w * 3)

		src_data: [MAX_VIDEO_PLANES]rawptr
		src_linesize: [MAX_VIDEO_PLANES]c.int
		for i in 0 ..< MAX_VIDEO_PLANES {
			src_data[i] = frame_data(frame, c.int(i))
			src_linesize[i] = frame_linesize(frame, c.int(i))
		}

		sws_scale(sws, &src_data, &src_linesize,
			0, frame_height(frame), &dst_slices, &dst_stride)

		out.w, out.h = w, h
		out.channels = 3
		out.stride = int(dst_stride)
		out.pixels = pixels
		result = 0
	}

	av_frame_free(&frame)
	av_packet_free(&pkt)
	sws_freeContext(sws)
	avcodec_free_context(&codec_ctx)
	avformat_close_input(&fmt_ctx)
	return result
}

// ══════════════════════════════════════════════════════════════════════════════
// VideoEncoder — encode BGR24 frames to a video file.
// ══════════════════════════════════════════════════════════════════════════════

VideoEncoder :: struct {
	fmt_ctx:        ^AVFormatContext,
	stream:         ^AVStream,
	codec:          rawptr,
	codec_ctx:      ^AVCodecContext,
	sws:            SwsContext,
	sws_gray8:      SwsContext,
	frame:          ^AVFrame,
	pkt:            ^AVPacket,
	width:          int,
	height:         int,
	dst_pix_fmt:    c.int,
	no_file:        bool,
}

video_encoder_open :: proc(
	path: string,
	width, height, fps: int,
	codec_name: string,
	bitrate: int,
) -> ^VideoEncoder {
	enc := new(VideoEncoder)
	enc.width = width
	enc.height = height

	cpath, cpath_buf := clone_to_cstr(path)
	defer delete(cpath_buf)

	// Guess output format from filename
	ofmt := av_guess_format(nil, cpath, nil)
	if ofmt == nil && len(codec_name) > 0 {
		ccodec, ccodec_buf := clone_to_cstr(codec_name)
		ofmt = av_guess_format(ccodec, nil, nil)
		delete(ccodec_buf)
	}
	if ofmt == nil {
		ofmt = av_guess_format(cstring("mov"), nil, nil)
	}
	if ofmt == nil {
		free(enc)
		return nil
	}

	if avformat_alloc_output_context2(&enc.fmt_ctx, ofmt, nil, cpath) < 0 {
		free(enc)
		return nil
	}

	// Find encoder
	ccodec_buf: []u8
	ccodec: cstring
	if len(codec_name) > 0 {
		ccodec, ccodec_buf = clone_to_cstr(codec_name)
	} else {
		ccodec = cstring("prores_ks")
	}
	defer delete(ccodec_buf)

	enc.codec = avcodec_find_encoder_by_name(ccodec)
	if enc.codec == nil {
		enc.codec = avcodec_find_encoder(ofmt_video_codec(fmtc_oformat(enc.fmt_ctx)))
	}
	if enc.codec == nil {
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}

	enc.codec_ctx = avcodec_alloc_context3(enc.codec)
	if enc.codec_ctx == nil {
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}

	// Determine destination pixel format from codec name
	switch {
	case len(codec_name) > 0 && strings.contains(codec_name, "prores"):
		enc.dst_pix_fmt = av_get_pix_fmt(cstring("yuv422p10le"))
	case len(codec_name) > 0 && (strings.contains(codec_name, "h264") || strings.contains(codec_name, "libx264")):
		enc.dst_pix_fmt = av_get_pix_fmt(cstring("yuv420p"))
	case:
		enc.dst_pix_fmt = av_get_pix_fmt(cstring("yuv422p10le"))
	}

	codecctx_set_width(enc.codec_ctx, c.int(width))
	codecctx_set_height(enc.codec_ctx, c.int(height))
	codecctx_set_pix_fmt(enc.codec_ctx, enc.dst_pix_fmt)

	fps_val := fps
	if fps_val <= 0 { fps_val = 30 }
	codecctx_set_time_base(enc.codec_ctx, 1, c.int(fps_val))

	if ofmt_flags(fmtc_oformat(enc.fmt_ctx)) & AVFMT_GLOBALHEADER != 0 {
		codecctx_flags_or(enc.codec_ctx, AV_CODEC_FLAG_GLOBAL_HEADER)
	}

	// Detect hardware vs software codec and configure threading
	is_hw := len(codec_name) > 0 && (
		strings.contains(codec_name, "videotoolbox") ||
		strings.contains(codec_name, "vaapi") ||
		strings.contains(codec_name, "nvenc") ||
		strings.contains(codec_name, "amf")
	)
	if !is_hw {
		ncores := os.get_processor_core_count()
		if ncores < 1 { ncores = 1 }
		codecctx_set_thread_count(enc.codec_ctx, c.int(ncores))
		codecctx_set_thread_type(enc.codec_ctx, FF_THREAD_SLICE)
	}

	if avcodec_open2(enc.codec_ctx, enc.codec, nil) < 0 {
		avcodec_free_context(&enc.codec_ctx)
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}

	enc.stream = avformat_new_stream(enc.fmt_ctx, nil)
	if enc.stream == nil {
		avcodec_free_context(&enc.codec_ctx)
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}
	avcodec_parameters_from_context(stream_codecpar(enc.stream), enc.codec_ctx)
	stream_set_time_base(enc.stream, codecctx_time_base_num(enc.codec_ctx), codecctx_time_base_den(enc.codec_ctx))

	if ofmt_flags(fmtc_oformat(enc.fmt_ctx)) & AVFMT_NOFILE == 0 {
		if avio_open(fmtc_pb_ptr(enc.fmt_ctx), cpath, AVIO_FLAG_WRITE) < 0 {
			avcodec_free_context(&enc.codec_ctx)
			avformat_free_context(enc.fmt_ctx)
			free(enc)
			return nil
		}
	} else {
		enc.no_file = true
	}

	if avformat_write_header(enc.fmt_ctx, nil) < 0 {
		if !enc.no_file {
			avio_closep(fmtc_pb_ptr(enc.fmt_ctx))
		}
		avcodec_free_context(&enc.codec_ctx)
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}

	enc.sws = sws_getContext(
		c.int(width), c.int(height), AV_PIX_FMT_BGR24,
		c.int(width), c.int(height), enc.dst_pix_fmt,
		SWS_BILINEAR,
		nil, nil, nil,
	)
	enc.sws_gray8 = sws_getContext(
		c.int(width), c.int(height), AV_PIX_FMT_GRAY8,
		c.int(width), c.int(height), enc.dst_pix_fmt,
		SWS_BILINEAR,
		nil, nil, nil,
	)
	enc.frame = av_frame_alloc()
	if enc.sws == nil || enc.sws_gray8 == nil || enc.frame == nil {
		sws_freeContext(enc.sws)
		sws_freeContext(enc.sws_gray8)
		av_frame_free(&enc.frame)
		if !enc.no_file {
			avio_closep(fmtc_pb_ptr(enc.fmt_ctx))
		}
		avcodec_free_context(&enc.codec_ctx)
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}

	frame_set_format(enc.frame, enc.dst_pix_fmt)
	frame_set_width(enc.frame, c.int(width))
	frame_set_height(enc.frame, c.int(height))
	frame_set_pts(enc.frame, 0)
	if av_frame_get_buffer(enc.frame, 0) < 0 {
		sws_freeContext(enc.sws)
		sws_freeContext(enc.sws_gray8)
		av_frame_free(&enc.frame)
		if !enc.no_file {
			avio_closep(fmtc_pb_ptr(enc.fmt_ctx))
		}
		avcodec_free_context(&enc.codec_ctx)
		avformat_free_context(enc.fmt_ctx)
		free(enc)
		return nil
	}

	enc.pkt = av_packet_alloc()
	return enc
}

video_encoder_write_frame :: proc(enc: ^VideoEncoder, img: ^Img) {
	if enc == nil { return }

	src_slices: [1]rawptr
	src_stride: c.int

	if img.channels == 1 {
		// Direct GRAY8 -> dst — avoids 3x BGR24 expansion
		src_slices[0] = raw_data(img.pixels)
		src_stride = c.int(img.stride)
		dst_data: [MAX_VIDEO_PLANES]rawptr
		dst_linesize: [MAX_VIDEO_PLANES]c.int
		for i in 0 ..< MAX_VIDEO_PLANES {
			dst_data[i] = frame_data(enc.frame, c.int(i))
			dst_linesize[i] = frame_linesize(enc.frame, c.int(i))
		}
		sws_scale(
			enc.sws_gray8,
			&src_slices, &src_stride,
			0, c.int(img.h),
			&dst_data, &dst_linesize,
		)
	} else if img.channels == 3 {
		src_slices[0] = raw_data(img.pixels)
		src_stride = c.int(img.stride)
		dst_data: [MAX_VIDEO_PLANES]rawptr
		dst_linesize: [MAX_VIDEO_PLANES]c.int
		for i in 0 ..< MAX_VIDEO_PLANES {
			dst_data[i] = frame_data(enc.frame, c.int(i))
			dst_linesize[i] = frame_linesize(enc.frame, c.int(i))
		}
		sws_scale(
			enc.sws,
			&src_slices, &src_stride,
			0, c.int(img.h),
			&dst_data, &dst_linesize,
		)
	} else {
		return
	}

	ret := avcodec_send_frame(enc.codec_ctx, enc.frame)
	frame_set_pts(enc.frame, frame_pts(enc.frame) + 1)
	if ret < 0 { return }

	for {
		ret = avcodec_receive_packet(enc.codec_ctx, enc.pkt)
		if ret == AVERROR_EAGAIN || ret == AVERROR_EOF { break }
		if ret < 0 { return }
		av_packet_rescale_ts(enc.pkt,
			AVRational{codecctx_time_base_num(enc.codec_ctx), codecctx_time_base_den(enc.codec_ctx)},
			AVRational{stream_time_base_num(enc.stream), stream_time_base_den(enc.stream)})
		packet_set_stream_index(enc.pkt, stream_index(enc.stream))
		av_interleaved_write_frame(enc.fmt_ctx, enc.pkt)
		av_packet_unref(enc.pkt)
	}
}

video_encoder_close :: proc(enc: ^VideoEncoder) {
	if enc == nil { return }

	// Flush encoder
	avcodec_send_frame(enc.codec_ctx, nil)
	for {
		ret := avcodec_receive_packet(enc.codec_ctx, enc.pkt)
		if ret < 0 { break }
		av_packet_rescale_ts(enc.pkt,
			AVRational{codecctx_time_base_num(enc.codec_ctx), codecctx_time_base_den(enc.codec_ctx)},
			AVRational{stream_time_base_num(enc.stream), stream_time_base_den(enc.stream)})
		packet_set_stream_index(enc.pkt, stream_index(enc.stream))
		av_interleaved_write_frame(enc.fmt_ctx, enc.pkt)
		av_packet_unref(enc.pkt)
	}

	video_encoder_cleanup(enc)
}

video_encoder_cleanup :: proc(enc: ^VideoEncoder) {
	av_write_trailer(enc.fmt_ctx)
	if !enc.no_file {
		avio_closep(fmtc_pb_ptr(enc.fmt_ctx))
	}
	sws_freeContext(enc.sws)
	sws_freeContext(enc.sws_gray8)
	av_frame_free(&enc.frame)
	av_packet_free(&enc.pkt)
	avformat_free_context(enc.fmt_ctx)
	free(enc)
}

// ══════════════════════════════════════════════════════════════════════════════
// Utility: probe video metadata without full decode.
// ══════════════════════════════════════════════════════════════════════════════

VideoInfo :: struct {
	width:     int,
	height:    int,
	fps:       f64,
	duration:  f64,
	codec_id:  int,
	pix_fmt:   int,
}

video_probe :: proc(path: string) -> (info: VideoInfo, ok: bool) {
	fmt_ctx: ^AVFormatContext
	cpath, cpath_buf := clone_to_cstr(path)
	defer delete(cpath_buf)

	if avformat_open_input(&fmt_ctx, cpath, nil, nil) != 0 { return }
	defer avformat_close_input(&fmt_ctx)

	if avformat_find_stream_info(fmt_ctx, nil) < 0 { return }

	nb_streams := fmtc_nb_streams(fmt_ctx)
	for i in 0 ..< int(nb_streams) {
		stream := fmtc_streams(fmt_ctx, c.int(i))
		cp := stream_codecpar(stream)
		if codecpar_codec_type(cp) == AVMEDIA_TYPE_VIDEO {
			info.width = int(codecpar_width(cp))
			info.height = int(codecpar_height(cp))
			info.codec_id = int(codecpar_codec_id(cp))
			info.pix_fmt = int(codecpar_format(cp))

			r_num := stream_r_frame_rate_num(stream)
			r_den := stream_r_frame_rate_den(stream)
			avg_num := stream_avg_frame_rate_num(stream)
			avg_den := stream_avg_frame_rate_den(stream)
			if r_num != 0 && r_den != 0 {
				info.fps = f64(r_num) / f64(r_den)
			} else if avg_num != 0 && avg_den != 0 {
				info.fps = f64(avg_num) / f64(avg_den)
			} else {
				info.fps = 30.0
			}

			ok = true
			break
		}
	}
	return
}
