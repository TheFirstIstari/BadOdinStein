package main

import "core:c"
import "core:mem"
import "core:fmt"
import "core:strings"

// ══════════════════════════════════════════════════════════════════════════════
// FFmpeg FFI — video decode / encode via libavformat, libavcodec,
// libavutil, libswscale.
//
// Opaque struct layouts below target FFmpeg 6.x–7.x.  Rebuild the layout
// structs when upgrading FFmpeg.
// ══════════════════════════════════════════════════════════════════════════════

// ── Foreign library imports ─────────────────────────────────────────────────

foreign import libavformat "libavformat"
foreign import libavcodec  "libavcodec"
foreign import libavutil   "libavutil"
foreign import libswscale  "libswscale"

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
// Odin cannot reach into opaque FFmpeg handles, so we define minimal mirror
// structs whose offsets match a specific FFmpeg major version.  A field
// accessed with the WRONG offset will silently corrupt data — test against
// the exact FFmpeg you link.

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
	nb_streams_bad:  c.int,   // placeholder alignment
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

// ── Foreign function declarations ───────────────────────────────────────────

foreign libavformat {
	avformat_network_init    :: proc() -> c.int ---
	avformat_network_deinit  :: proc() -> c.int ---
	avformat_open_input     :: proc(ctx: ^^AVFormatContext, url: cstring, fmt: ^AVInputFormat, options: ^^AVDictionary) -> c.int ---
	avformat_find_stream_info :: proc(ctx: ^AVFormatContext, options: ^^AVDictionary) -> c.int ---
	avformat_close_input    :: proc(ctx: ^^AVFormatContext) ---
	av_read_frame           :: proc(ctx: ^AVFormatContext, pkt: ^AVPacket) -> c.int ---
	av_seek_frame            :: proc(ctx: ^AVFormatContext, stream_index: c.int, timestamp: i64, flags: c.int) -> c.int ---
	av_guess_format         :: proc(short_name: cstring, filename: cstring, mime_type: cstring) -> ^AVOutputFormat ---
	avformat_alloc_output_context2 :: proc(ctx: ^^AVFormatContext, fmt: ^AVOutputFormat, format_name: cstring, filename: cstring) -> c.int ---
	avformat_new_stream      :: proc(ctx: ^AVFormatContext, c: ^AVCodec) -> ^AVStream ---
	avformat_write_header    :: proc(ctx: ^AVFormatContext, options: ^^AVDictionary) -> c.int ---
	av_write_trailer         :: proc(ctx: ^AVFormatContext) -> c.int ---
	av_interleaved_write_frame :: proc(ctx: ^AVFormatContext, pkt: ^AVPacket) -> c.int ---
	avio_open               :: proc(pb: ^^AVIOContext, url: cstring, flags: c.int) -> c.int ---
	avio_closep             :: proc(pb: ^^AVIOContext) ---
}

foreign libavcodec {
	avcodec_find_decoder           :: proc(id: c.int) -> ^AVCodec ---
	avcodec_find_encoder_by_name   :: proc(name: cstring) -> ^AVCodec ---
	avcodec_find_encoder           :: proc(id: c.int) -> ^AVCodec ---
	avcodec_alloc_context3         :: proc(codec: ^AVCodec) -> ^AVCodecContext ---
	avcodec_free_context           :: proc(ctx: ^^AVCodecContext) ---
	avcodec_parameters_to_context  :: proc(ctx: ^AVCodecContext, par: ^AVCodecParameters) -> c.int ---
	avcodec_parameters_from_context :: proc(par: ^AVCodecParameters, ctx: ^AVCodecContext) -> c.int ---
	avcodec_open2                  :: proc(ctx: ^AVCodecContext, codec: ^AVCodec, options: ^^AVDictionary) -> c.int ---
	avcodec_send_packet            :: proc(ctx: ^AVCodecContext, pkt: ^AVPacket) -> c.int ---
	avcodec_receive_frame          :: proc(ctx: ^AVCodecContext, frame: ^AVFrame) -> c.int ---
	avcodec_send_frame             :: proc(ctx: ^AVCodecContext, frame: ^AVFrame) -> c.int ---
	avcodec_receive_packet         :: proc(ctx: ^AVCodecContext, pkt: ^AVPacket) -> c.int ---
	av_packet_alloc                :: proc() -> ^AVPacket ---
	av_packet_free                 :: proc(pkt: ^^AVPacket) ---
	av_packet_unref                :: proc(pkt: ^AVPacket) ---
	av_packet_rescale_ts           :: proc(pkt: ^AVPacket, tb_src: AVRational, tb_dst: AVRational) ---
}

foreign libavutil {
	av_frame_alloc           :: proc() -> ^AVFrame ---
	av_frame_free            :: proc(frame: ^^AVFrame) ---
	av_frame_get_buffer      :: proc(frame: ^AVFrame, align: c.int) -> c.int ---
	av_frame_make_writable   :: proc(frame: ^AVFrame) -> c.int ---
	av_get_pix_fmt           :: proc(name: cstring) -> c.int ---
	av_pix_fmt_name          :: proc(pix_fmt: c.int) -> cstring ---
	av_opt_set_double        :: proc(obj: rawptr, name: cstring, val: f64, search_flags: c.int) -> c.int ---
	av_image_get_buffer_size :: proc(pix_fmt: c.int, w: c.int, h: c.int, align: c.int) -> c.int ---
	av_dict_set             :: proc(pm: ^^AVDictionary, key: cstring, value: cstring, flags: c.int) -> c.int ---
	av_dict_get             :: proc(m: ^AVDictionary, key: cstring, prev: ^AVDictionary, flags: c.int) -> ^AVDictionary ---
	av_dict_free            :: proc(pm: ^^AVDictionary) ---
	av_rescale_q            :: proc(a: i64, bq: AVRational, cq: AVRational) -> i64 ---
}

foreign libswscale {
	sws_getContext :: proc(
		srcW: c.int, srcH: c.int, srcFormat: c.int,
		dstW: c.int, dstH: c.int, dstFormat: c.int,
		flags: c.int, srcFilter: rawptr, dstFilter: rawptr, param: rawptr,
	) -> ^SwsContext ---
	sws_scale :: proc(
		ctx: ^SwsContext,
		srcSlice: rawptr, srcStride: rawptr,
		srcSliceY: c.int, srcSliceH: c.int,
		dstSlice: rawptr, dstStride: rawptr,
	) -> c.int ---
	sws_freeContext :: proc(ctx: ^SwsContext) ---
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
	// AVERROR maps to negative errno on most platforms
	switch {
	case code == AVERROR_EAGAIN:    return "EAGAIN"
	case code == AVERROR_EOF:       return "EOF"
	case code == AVERROR_INPUT_CHANGED: return "INPUT_CHANGED"
	case code == AVERROR_DECODER_NOT_FOUND: return "DECODER_NOT_FOUND"
	case code == 0:                 return "OK"
	default:                        return "UNKNOWN"
	}
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
	dec := make(VideoDecoder)
	dec.video_stream = -1
	dec.eof = false

	// TODO: avformat_network_init — call once per process lifetime.
	//       Guard with a package-level flag if called from multiple decoders.
	c.avformat_network_init()

	// ── Open input ──
	c_path := strings.clone_to_cstring(path, context.allocator)
	defer delete(c_path)

	ret: c.int = 0
	ret = c.avformat_open_input(
		&dec.fmt_ctx,
		c_path,
		nil,   // auto-detect format
		nil,   // no options
	)
	if ret < 0 {
		cli_error("avformat_open_input failed for %s: %s", path, ffmpeg_err_name(ret))
		delete(dec)
		return nil
	}

	ret = c.avformat_find_stream_info(dec.fmt_ctx, nil)
	if ret < 0 {
		cli_error("avformat_find_stream_info failed: %s", ffmpeg_err_name(ret))
		c.avformat_close_input(&dec.fmt_ctx)
		delete(dec)
		return nil
	}

	// ── Find video stream ──
	fmt_layout := cast(^AVFormatContext_Layout) dec.fmt_ctx
	nb_streams := int(fmt_layout.nb_streams)
	streams_ptr := cast(^^AVStream) fmt_layout.streams

	for i in 0 ..< nb_streams {
		st := streams_ptr[i]
		if st == nil { continue }
		st_layout := cast(^AVStream_Layout) st
		cp := cast(^AVCodecParameters_Layout) st_layout.codecpar
		if cp == nil { continue }
		if cp.codec_type == AVMEDIA_TYPE_VIDEO {
			dec.video_stream = i
			dec.pix_fmt = int(cp.pix_fmt)
			dec.width = int(cp.width)
			dec.height = int(cp.height)
			break
		}
	}

	if dec.video_stream < 0 {
		cli_error("no video stream found in %s", path)
		c.avformat_close_input(&dec.fmt_ctx)
		delete(dec)
		return nil
	}

	// ── Find decoder + open ──
	cp := cast(^AVCodecParameters_Layout) (
		cast(^AVStream_Layout) streams_ptr[dec.video_stream],
	).codecpar

	codec := c.avcodec_find_decoder(cp.codec_id)
	if codec == nil {
		cli_error("decoder not found for codec_id %d", cp.codec_id)
		c.avformat_close_input(&dec.fmt_ctx)
		delete(dec)
		return nil
	}

	dec.codec_ctx = c.avcodec_alloc_context3(codec)
	if dec.codec_ctx == nil {
		cli_error("avcodec_alloc_context3 failed")
		c.avformat_close_input(&dec.fmt_ctx)
		delete(dec)
		return nil
	}

	ret = c.avcodec_parameters_to_context(dec.codec_ctx, cast(^AVCodecParameters) cp)
	if ret < 0 {
		cli_error("avcodec_parameters_to_context failed: %s", ffmpeg_err_name(ret))
		c.avcodec_free_context(&dec.codec_ctx)
		c.avformat_close_input(&dec.fmt_ctx)
		delete(dec)
		return nil
	}

	ret = c.avcodec_open2(dec.codec_ctx, codec, nil)
	if ret < 0 {
		cli_error("avcodec_open2 failed: %s", ffmpeg_err_name(ret))
		c.avcodec_free_context(&dec.codec_ctx)
		c.avformat_close_input(&dec.fmt_ctx)
		delete(dec)
		return nil
	}

	// Re-read dimensions from the opened context (may differ from codecpar)
	ctx_layout := cast(^AVCodecContext_Layout) dec.codec_ctx
	dec.width = int(ctx_layout.width)
	dec.height = int(ctx_layout.height)

	// ── FPS from stream time_base and avg_frame_rate ──
	st_layout := cast(^AVStream_Layout) streams_ptr[dec.video_stream]
	tb := st_layout.time_base
	if tb.den != 0 {
		// avg_frame_rate approximation — use frame count heuristic later if needed
		dec.fps = f64(tb.den) / f64(tb.num) / 1000.0  // rough
	}
	if dec.fps <= 0 || dec.fps > 240 {
		dec.fps = 25.0  // sane default
	}

	// ── Allocate frames + packet ──
	dec.frame = c.av_frame_alloc()
	dec.bgr_frame = c.av_frame_alloc()
	dec.pkt = c.av_packet_alloc()

	if dec.frame == nil || dec.bgr_frame == nil || dec.pkt == nil {
		cli_error("failed to allocate frame/packet")
		video_decoder_close(dec)
		return nil
	}

	// ── SWS context for pixel format conversion ──
	src_fmt := AV_PIX_FMT_YUV420P
	if dec.pix_fmt >= 0 {
		src_fmt = c.int(dec.pix_fmt)
	}
	dec.sws = c.sws_getContext(
		c.int(dec.width), c.int(dec.height), src_fmt,
		c.int(dec.width), c.int(dec.height), AV_PIX_FMT_BGR24,
		SWS_BILINEAR, nil, nil, nil,
	)
	if dec.sws == nil {
		cli_error("sws_getContext failed")
		video_decoder_close(dec)
		return nil
	}

	return dec
}

video_decoder_read_frame :: proc(dec: ^VideoDecoder, out: ^Img) -> bool {
	if dec == nil || dec.eof { return false }

	for {
		ret: c.int = 0

		ret = c.av_read_frame(dec.fmt_ctx, dec.pkt)
		if ret < 0 {
			if ret == AVERROR_EOF {
				dec.eof = true
			}
			return false
		}

		pkt_layout := cast(^AVPacket_Layout) dec.pkt
		if pkt_layout.stream_index != c.int(dec.video_stream) {
			c.av_packet_unref(dec.pkt)
			continue
		}

		// Send packet to decoder
		ret = c.avcodec_send_packet(dec.codec_ctx, dec.pkt)
		c.av_packet_unref(dec.pkt)
		if ret < 0 {
			if ret == AVERROR_EAGAIN {
				continue
			}
			return false
		}

		// Receive decoded frame
		ret = c.avcodec_receive_frame(dec.codec_ctx, dec.frame)
		if ret == AVERROR_EAGAIN {
			continue
		}
		if ret < 0 {
			dec.eof = (ret == AVERROR_EOF)
			return false
		}

		// Convert to BGR24
		frame_layout := cast(^AVFrame_Layout) dec.frame
		out.w = int(frame_layout.width)
		out.h = int(frame_layout.height)
		out.channels = 3

		bgr_buf_size := out.w * out.h * 3
		if len(out.pixels) < bgr_buf_size {
			if len(out.pixels) > 0 { delete(out.pixels) }
			out.pixels = make([]u8, bgr_buf_size)
		}
		out.stride = out.w * 3

		// sws_scale: convert frame data → BGR24 output buffer
		src_data: [8]rawptr
		src_linesize: [8]c.int
		for i in 0 ..< 8 {
			src_data[i] = frame_layout.data[i]
			src_linesize[i] = frame_layout.linesize[i]
		}

		dst_data: [1]rawptr
		dst_data[0] = rawptr(&out.pixels[0])
		dst_linesize: [1]c.int
		dst_linesize[0] = c.int(out.stride)

		c.sws_scale(
			dec.sws,
			rawptr(&src_data), rawptr(&src_linesize),
			0, c.int(dec.height),
			rawptr(&dst_data), rawptr(&dst_linesize),
		)

		return true
	}
}

video_decoder_close :: proc(dec: ^VideoDecoder) {
	if dec == nil { return }
	if dec.sws != nil {
		c.sws_freeContext(dec.sws)
		dec.sws = nil
	}
	if dec.bgr_frame != nil {
		c.av_frame_free(&dec.bgr_frame)
	}
	if dec.frame != nil {
		c.av_frame_free(&dec.frame)
	}
	if dec.pkt != nil {
		c.av_packet_free(&dec.pkt)
	}
	if dec.codec_ctx != nil {
		c.avcodec_free_context(&dec.codec_ctx)
	}
	if dec.fmt_ctx != nil {
		c.avformat_close_input(&dec.fmt_ctx)
	}
	delete(dec)
}

video_image_load :: proc(path: string, out: ^Img) -> int {
	dec := video_decoder_open(path)
	if dec == nil { return -1 }

	ok := video_decoder_read_frame(dec, out)
	video_decoder_close(dec)

	if ok { return 0 }
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
	codec_name: string,     // e.g. "libx264", "mpeg4"
	bitrate: int,
) -> ^VideoEncoder {
	enc := make(VideoEncoder)
	enc.width = width
	enc.height = height
	enc.fps = fps

	// TODO: Full implementation:
	// 1. c.avformat_alloc_output_context2(&enc.fmt_ctx, nil, nil, c_path)
	// 2. Find encoder: c.avcodec_find_encoder_by_name(c_codec_name)
	// 3. c.avformat_new_stream(enc.fmt_ctx, codec)
	// 4. c.avcodec_alloc_context3(codec) → enc.codec_ctx
	// 5. Set codec_ctx fields: width, height, time_base, pix_fmt, bit_rate, etc.
	//    (use cast(^AVCodecContext_Layout) to write fields)
	// 6. If codec requires YUV input, create sws context for BGR→YUV
	// 7. c.avcodec_open2(enc.codec_ctx, codec, nil)
	// 8. c.avcodec_parameters_from_context(stream->codecpar, enc.codec_ctx)
	// 9. c.avio_open(&pb, c_path, AVIO_FLAG_WRITE)
	// 10. c.avformat_write_header(enc.fmt_ctx, nil)
	// 11. c.av_packet_alloc() → enc.pkt
	// 12. c.av_frame_alloc() → enc.frame

	_ = cast(rawptr) enc

	return nil  // TODO: remove nil once implemented
}

video_encoder_write_frame :: proc(enc: ^VideoEncoder, img: ^Img) {
	if enc == nil || enc.frame_idx < 0 { return }

	// TODO: Full implementation:
	// 1. If sws context exists, convert BGR img → YUV frame via sws_scale
	// 2. Otherwise copy BGR data directly into frame->data
	// 3. Set frame->pts = enc.frame_idx
	// 4. c.avcodec_send_frame(enc.codec_ctx, enc.frame)
	// 5. Loop c.avcodec_receive_packet(enc.codec_ctx, enc.pkt)
	//    a. c.av_packet_rescale_ts(enc.pkt, enc.codec_ctx->time_base, enc.stream->time_base)
	//    b. enc.pkt->stream_index = enc.stream->index
	//    c. c.av_interleaved_write_frame(enc.fmt_ctx, enc.pkt)
	//    d. c.av_packet_unref(enc.pkt)
	// 6. enc.frame_idx += 1

	_ = img
}

video_encoder_close :: proc(enc: ^VideoEncoder) {
	if enc == nil { return }

	// TODO: Flush encoder:
	// 1. c.avcodec_send_frame(enc.codec_ctx, nil)
	// 2. Loop c.avcodec_receive_packet until AVERROR_EOF
	// 3. c.av_write_trailer(enc.fmt_ctx)
	// 4. c.avio_closep(&enc.fmt_ctx->pb)
	// 5. c.av_packet_free(&enc.pkt)
	// 6. c.av_frame_free(&enc.frame)
	// 7. c.avcodec_free_context(&enc.codec_ctx)
	// 8. c.avformat_free_context(enc.fmt_ctx)
	// 9. if enc.sws != nil: c.sws_freeContext(enc.sws)

	delete(enc)
}

// ══════════════════════════════════════════════════════════════════════════════
// Utility: probe video metadata without full decode.
// ══════════════════════════════════════════════════════════════════════════════

VideoInfo :: struct {
	width:     int,
	height:    int,
	fps:       f64,
	duration:  f64,     // seconds
	codec_id:  int,
	pix_fmt:   int,
}

video_probe :: proc(path: string) -> (info: VideoInfo, ok: bool) {
	c_path := strings.clone_to_cstring(path, context.allocator)
	defer delete(c_path)

	var fmt_ctx: ^AVFormatContext
	ret := c.avformat_open_input(&fmt_ctx, c_path, nil, nil)
	if ret < 0 { return }

	defer c.avformat_close_input(&fmt_ctx)

	ret = c.avformat_find_stream_info(fmt_ctx, nil)
	if ret < 0 { return }

	fmt_layout := cast(^AVFormatContext_Layout) fmt_ctx
	nb := int(fmt_layout.nb_streams)
	streams := cast(^^AVStream) fmt_layout.streams

	for i in 0 ..< nb {
		if streams[i] == nil { continue }
		st_layout := cast(^AVStream_Layout) streams[i]
		cp_raw := st_layout.codecpar
		if cp_raw == nil { continue }
		cp := cast(^AVCodecParameters_Layout) cp_raw
		if cp.codec_type == AVMEDIA_TYPE_VIDEO {
			info.width = int(cp.width)
			info.height = int(cp.height)
			info.codec_id = int(cp.codec_id)
			info.pix_fmt = int(cp.pix_fmt)

			// Duration from fmt_ctx (ff_duration in AVFormatContext)
			// For a rough estimate use the format context's duration field
			// TODO: read duration properly from format context layout
			info.fps = 30.0  // placeholder
			return info, true
		}
	}
	return
}
