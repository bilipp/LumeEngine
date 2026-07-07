// Swift-visible shims for FFmpeg C macros that the Clang importer cannot expose.
#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <errno.h>
#include <lume_ffmpeg/libavutil/avutil.h>
#include <lume_ffmpeg/libavutil/error.h>
#include <lume_ffmpeg/libavutil/rational.h>

static inline int lume_averror(int posix_errno) { return AVERROR(posix_errno); }
static inline int lume_averror_eof(void) { return AVERROR_EOF; }
static inline int lume_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int lume_averror_exit(void) { return AVERROR_EXIT; }
static inline int lume_averror_invaliddata(void) { return AVERROR_INVALIDDATA; }
static inline int lume_averror_decoder_not_found(void) { return AVERROR_DECODER_NOT_FOUND; }

static inline int lume_is_eagain(int ret) { return ret == AVERROR(EAGAIN); }
static inline int lume_is_eof(int ret) { return ret == AVERROR_EOF; }

static inline int64_t lume_av_nopts_value(void) { return AV_NOPTS_VALUE; }
static inline AVRational lume_av_time_base_q(void) { return AV_TIME_BASE_Q; }

#endif /* CFFMPEG_SHIM_H */
