#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <stdint.h>

/* AVFormatContext */
unsigned int ff_fmtc_nb_streams(void *ctx) {
    return ((AVFormatContext *)ctx)->nb_streams;
}

void *ff_fmtc_streams(void *ctx, int i) {
    return ((AVFormatContext *)ctx)->streams[i];
}

void *ff_fmtc_pb(void *ctx) {
    return ((AVFormatContext *)ctx)->pb;
}

void *ff_fmtc_oformat(void *ctx) {
    return ((AVFormatContext *)ctx)->oformat;
}

void **ff_fmtc_pb_ptr(void *ctx) {
    return (void **)&((AVFormatContext *)ctx)->pb;
}

/* AVStream */
int ff_stream_index(void *s) {
    return ((AVStream *)s)->index;
}

void *ff_stream_codecpar(void *s) {
    return ((AVStream *)s)->codecpar;
}

int ff_stream_time_base_num(void *s) {
    return ((AVStream *)s)->time_base.num;
}

int ff_stream_time_base_den(void *s) {
    return ((AVStream *)s)->time_base.den;
}

int ff_stream_r_frame_rate_num(void *s) {
    return ((AVStream *)s)->r_frame_rate.num;
}

int ff_stream_r_frame_rate_den(void *s) {
    return ((AVStream *)s)->r_frame_rate.den;
}

int ff_stream_avg_frame_rate_num(void *s) {
    return ((AVStream *)s)->avg_frame_rate.num;
}

int ff_stream_avg_frame_rate_den(void *s) {
    return ((AVStream *)s)->avg_frame_rate.den;
}

void ff_stream_set_time_base(void *s, int num, int den) {
    ((AVStream *)s)->time_base.num = num;
    ((AVStream *)s)->time_base.den = den;
}

/* AVCodecParameters */
int ff_codecpar_codec_type(void *cp) {
    return ((AVCodecParameters *)cp)->codec_type;
}

int ff_codecpar_codec_id(void *cp) {
    return ((AVCodecParameters *)cp)->codec_id;
}

int ff_codecpar_format(void *cp) {
    return ((AVCodecParameters *)cp)->format;
}

int ff_codecpar_width(void *cp) {
    return ((AVCodecParameters *)cp)->width;
}

int ff_codecpar_height(void *cp) {
    return ((AVCodecParameters *)cp)->height;
}

/* AVCodecContext — reads */
int ff_codecx_width(void *ctx) {
    return ((AVCodecContext *)ctx)->width;
}

int ff_codecx_height(void *ctx) {
    return ((AVCodecContext *)ctx)->height;
}

int ff_codecx_pix_fmt(void *ctx) {
    return ((AVCodecContext *)ctx)->pix_fmt;
}

int ff_codecx_time_base_num(void *ctx) {
    return ((AVCodecContext *)ctx)->time_base.num;
}

int ff_codecx_time_base_den(void *ctx) {
    return ((AVCodecContext *)ctx)->time_base.den;
}

int ff_codecx_flags(void *ctx) {
    return ((AVCodecContext *)ctx)->flags;
}

/* AVCodecContext — writes */
void ff_codecx_set_width(void *ctx, int v) {
    ((AVCodecContext *)ctx)->width = v;
}

void ff_codecx_set_height(void *ctx, int v) {
    ((AVCodecContext *)ctx)->height = v;
}

void ff_codecx_set_pix_fmt(void *ctx, int v) {
    ((AVCodecContext *)ctx)->pix_fmt = v;
}

void ff_codecx_set_time_base(void *ctx, int num, int den) {
    ((AVCodecContext *)ctx)->time_base.num = num;
    ((AVCodecContext *)ctx)->time_base.den = den;
}

void ff_codecx_flags_or(void *ctx, int v) {
    ((AVCodecContext *)ctx)->flags |= v;
}

void ff_codecx_set_thread_count(void *ctx, int v) {
    ((AVCodecContext *)ctx)->thread_count = v;
}

void ff_codecx_set_thread_type(void *ctx, int v) {
    ((AVCodecContext *)ctx)->thread_type = v;
}

/* AVOutputFormat */
int ff_ofmt_flags(void *fmt) {
    return ((AVOutputFormat *)fmt)->flags;
}

int ff_ofmt_video_codec(void *fmt) {
    return ((AVOutputFormat *)fmt)->video_codec;
}

/* AVFrame — reads */
void *ff_frame_data(void *frame, int i) {
    return ((AVFrame *)frame)->data[i];
}

int ff_frame_linesize(void *frame, int i) {
    return ((AVFrame *)frame)->linesize[i];
}

int ff_frame_width(void *frame) {
    return ((AVFrame *)frame)->width;
}

int ff_frame_height(void *frame) {
    return ((AVFrame *)frame)->height;
}

int ff_frame_format(void *frame) {
    return ((AVFrame *)frame)->format;
}

int64_t ff_frame_pts(void *frame) {
    return ((AVFrame *)frame)->pts;
}

/* AVFrame — writes */
void ff_frame_set_pts(void *frame, int64_t v) {
    ((AVFrame *)frame)->pts = v;
}

void ff_frame_set_format(void *frame, int v) {
    ((AVFrame *)frame)->format = v;
}

void ff_frame_set_width(void *frame, int v) {
    ((AVFrame *)frame)->width = v;
}

void ff_frame_set_height(void *frame, int v) {
    ((AVFrame *)frame)->height = v;
}

/* AVPacket */
int ff_packet_stream_index(void *pkt) {
    return ((AVPacket *)pkt)->stream_index;
}

void *ff_packet_data(void *pkt) {
    return ((AVPacket *)pkt)->data;
}

void ff_packet_set_stream_index(void *pkt, int v) {
    ((AVPacket *)pkt)->stream_index = v;
}

/* SwsContext */
void *ff_sws_getContext(int srcW, int srcH, int srcFmt,
                        int dstW, int dstH, int dstFmt, int flags) {
    return sws_getContext(srcW, srcH, srcFmt, dstW, dstH, dstFmt,
                          flags, NULL, NULL, NULL);
}

void ff_sws_freeContext(void *ctx) {
    sws_freeContext((SwsContext *)ctx);
}

int ff_sws_scale(void *ctx, uint8_t *const *srcSlice, const int *srcStride,
                 int srcSliceY, int srcSliceH,
                 uint8_t *const *dstSlice, const int *dstStride) {
    return sws_scale((SwsContext *)ctx, srcSlice, srcStride,
                     srcSliceY, srcSliceH, dstSlice, dstStride);
}
