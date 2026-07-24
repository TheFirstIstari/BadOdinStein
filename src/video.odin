package main

import "core:c"
import "core:mem"
import "core:fmt"
import "core:strings"

// ══════════════════════════════════════════════════════════════════════════════
// FFmpeg FFI — video decode / encode via libavformat, libavcodec,
// libavutil, libswscale.
//
// Stubbed out for now.  All functions return nil/error to allow
// compilation without FFmpeg libraries installed.
// ══════════════════════════════════════════════════════════════════════════════

// ── Opaque handle types ─────────────────────────────────────────────────────

AVFormatContext :: struct {}
AVCodecContext  :: struct {}
AVCodec         :: struct {}
AVFrame         :: struct {}
AVPacket        :: struct {}
AVStream        :: struct {}
AVOutputFormat  :: struct {}
AVInputFormat   :: struct {}
AVIOContext     :: struct {}
AVDictionary    :: struct {}
AVCodecParameters :: struct {}
SwsContext      :: struct {}

AVRational :: struct { num: c.int, den: c.int }

// ── Struct layouts for field access ─────────────────────────────────────────

AVFormatContext_Layout :: struct {
	av_class:        rawptr,
	log_level_offset: c.int,
	iostream:        rawptr,
	avio_flags:      c.int,
	format:          rawptr,
	iformat:         rawptr,
	oformat:         rawptr,
	io_open:         rawptr,
	io_close2:       rawptr,
	opaque:          rawptr,
	pb:              rawptr,
	ctx_flags:       c.int,
	_pad0:           [4]u8,
	nb_streams:      c.uint,
	streams:         rawptr,
	nb_programs:     c.uint,
	programs:        rawptr,
	nb_streams_bad:  c.int,
}

AVStream_Layout :: struct {
	av_class:  rawptr,
	index:     c.int,
	id:        c.int,
	codecpar:  rawptr,
	_pad0:     [8]u8,
	time_base: AVRational,
}

AVCodecContext_Layout :: struct {
	av_class:        rawptr,
	log_level_offset: c.int,
	codec_type:      c.int,
	codec:           rawptr,
	codec_tag:       u32,
	bit_rate:        i64,
	_pad0:           [8]u8,
	width:           c.int,
	height:          c.int,
	gop_size:        c.int,
	max_b_frames:    c.int,
	pix_fmt:         c.int,
	_pad1:           [4]u8,
	time_base:       AVRational,
	ticks_per_frame: c.int,
	_pad2:           [12]u8,
	framerate:       AVRational,
	channels:        c.int,
	sample_rate:     c.int,
}

AVFrame_Layout :: struct {
	av_class: rawptr,
	data:     [8]rawptr,
	linesize: [8]c.int,
	_pad0:    [16]u8,
	width:    c.int,
	height:   c.int,
	format:   c.int,
	key_frame: c.int,
	pkt_pts:  i64,
}

AVPacket_Layout :: struct {
	av_class:     rawptr,
	buf:          rawptr,
	pts:          i64,
	dts:          i64,
	data:         rawptr,
	size:         c.int,
	stream_index: c.int,
	flags:        c.int,
	duration:     i64,
	pos:          i64,
}

AVCodecParameters_Layout :: struct {
	codec_type:   c.int,
	codec_id:     c.int,
	codec_tag:    u32,
	extra_data:   rawptr,
	extra_size:   c.int,
	_pad0:        [4]u8,
	width:        c.int,
	height:       c.int,
	bit_rate:     i64,
}

// ── Constants ───────────────────────────────────────────────────────────────

AV_PIX_FMT_BGR24       :: c.int(2)
AV_PIX_FMT_RGB24       :: c.int(2)
AV_PIX_FMT_GRAY8       :: c.int(8)
AV_PIX_FMT_YUV420P     :: c.int(0)
AV_PIX_FMT_YUV422P10LE :: c.int(66)

AVMEDIA_TYPE_VIDEO :: c.int(0)
AVMEDIA_TYPE_AUDIO :: c.int(1)

AVERROR_EAGAIN :: c.int(-11)
AVERROR_EOF    :: c.int(-541478725)
AVERROR_INPUT_CHANGED :: c.int(-1668179843)
AVERROR_DECODER_NOT_FOUND :: c.int(-1128613112)

AVSEEK_FLAG_BACKWARD :: c.int(1)
AVSEEK_FLAG_BYTE     :: c.int(2)
AVSEEK_FLAG_ANY      :: c.int(4)

AVIO_FLAG_READ       :: c.int(1)
AVIO_FLAG_WRITE      :: c.int(2)
AVIO_FLAG_READ_WRITE :: c.int(3)

AVFMT_NOFILE      :: c.int(1)
AVFMT_NEEDNUMBER  :: c.int(2)
AVFMT_RAWPICTURE  :: c.int(0x0020)

SWS_FAST_BILINEAR :: c.int(1)
SWS_BILINEAR      :: c.int(2)
SWS_BICUBIC       :: c.int(4)

FF_API_FLAG1      :: c.int(0)
FF_CODEC_CAP_INIT_THREADSAFETY :: c.int(0x100)

// ── Helper: check FFmpeg error code ─────────────────────────────────────────

ffmpeg_is_error :: proc(code: c.int) -> bool {
	return code < 0
}

ffmpeg_err_name :: proc(code: c.int) -> string {
	if code == AVERROR_EAGAIN { return "EAGAIN" }
	if code == AVERROR_EOF { return "EOF" }
	if code == AVERROR_INPUT_CHANGED { return "INPUT_CHANGED" }
	if code == AVERROR_DECODER_NOT_FOUND { return "DECODER_NOT_FOUND" }
	if code == 0 { return "OK" }
	return "UNKNOWN"
}

// ══════════════════════════════════════════════════════════════════════════════
// VideoDecoder — demux + decode a single video stream to BGR24 frames.
// ══════════════════════════════════════════════════════════════════════════════

VideoDecoder :: struct {
	fmt_ctx:        ^AVFormatContext,
	video_stream:   int,
	codec_ctx:      ^AVCodecContext,
	sws:            ^SwsContext,
	frame:          ^AVFrame,
	bgr_frame:      ^AVFrame,
	pkt:            ^AVPacket,
	width:          int,
	height:         int,
	fps:            f64,
	pix_fmt:        int,
	eof:            bool,
}

video_decoder_open :: proc(path: string) -> ^VideoDecoder {
	// TODO: implement with FFmpeg
	cli_warn("video decode not yet implemented")
	return nil
}

video_decoder_read_frame :: proc(dec: ^VideoDecoder, out: ^Img) -> bool {
	return false
}

video_decoder_close :: proc(dec: ^VideoDecoder) {
	// TODO: implement
}

video_image_load :: proc(path: string, out: ^Img) -> int {
	return -1
}

// ══════════════════════════════════════════════════════════════════════════════
// VideoEncoder — encode BGR24 frames to a video file.
// ══════════════════════════════════════════════════════════════════════════════

VideoEncoder :: struct {
	fmt_ctx:        ^AVFormatContext,
	stream:         ^AVStream,
	codec_ctx:      ^AVCodecContext,
	pkt:            ^AVPacket,
	frame:          ^AVFrame,
	sws:            ^SwsContext,
	width:          int,
	height:         int,
	fps:            int,
	frame_idx:      int,
}

video_encoder_open :: proc(
	path: string,
	width, height, fps: int,
	codec_name: string,
	bitrate: int,
) -> ^VideoEncoder {
	// TODO: implement with FFmpeg
	return nil
}

video_encoder_write_frame :: proc(enc: ^VideoEncoder, img: ^Img) {
	// TODO: implement
}

video_encoder_close :: proc(enc: ^VideoEncoder) {
	// TODO: implement
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
	// TODO: implement with FFmpeg
	return
}
