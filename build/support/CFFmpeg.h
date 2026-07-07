// Umbrella header for the CFFmpeg module (LumeEngine binary distribution).
#ifndef CFFMPEG_UMBRELLA_H
#define CFFMPEG_UMBRELLA_H

#include <lume_ffmpeg/libavformat/avformat.h>
#include <lume_ffmpeg/libavformat/avio.h>
#include <lume_ffmpeg/libavformat/version.h>

#include <lume_ffmpeg/libavcodec/avcodec.h>
#include <lume_ffmpeg/libavcodec/codec.h>
#include <lume_ffmpeg/libavcodec/codec_desc.h>
#include <lume_ffmpeg/libavcodec/bsf.h>
#include <lume_ffmpeg/libavcodec/videotoolbox.h>
#include <lume_ffmpeg/libavcodec/version.h>

#include <lume_ffmpeg/libavutil/avutil.h>
#include <lume_ffmpeg/libavutil/opt.h>
#include <lume_ffmpeg/libavutil/dict.h>
#include <lume_ffmpeg/libavutil/error.h>
#include <lume_ffmpeg/libavutil/frame.h>
#include <lume_ffmpeg/libavutil/imgutils.h>
#include <lume_ffmpeg/libavutil/samplefmt.h>
#include <lume_ffmpeg/libavutil/channel_layout.h>
#include <lume_ffmpeg/libavutil/pixdesc.h>
#include <lume_ffmpeg/libavutil/pixfmt.h>
#include <lume_ffmpeg/libavutil/time.h>
#include <lume_ffmpeg/libavutil/mathematics.h>
#include <lume_ffmpeg/libavutil/rational.h>
#include <lume_ffmpeg/libavutil/display.h>
#include <lume_ffmpeg/libavutil/log.h>
#include <lume_ffmpeg/libavutil/hwcontext.h>
#include <lume_ffmpeg/libavutil/hwcontext_videotoolbox.h>
#include <lume_ffmpeg/libavutil/mastering_display_metadata.h>
#include <lume_ffmpeg/libavutil/hdr_dynamic_metadata.h>
#include <lume_ffmpeg/libavutil/dovi_meta.h>
#include <lume_ffmpeg/libavutil/stereo3d.h>
#include <lume_ffmpeg/libavutil/version.h>

#include <lume_ffmpeg/libswresample/swresample.h>
#include <lume_ffmpeg/libswscale/swscale.h>

#include <lume_ffmpeg/libavfilter/avfilter.h>
#include <lume_ffmpeg/libavfilter/buffersrc.h>
#include <lume_ffmpeg/libavfilter/buffersink.h>

#include "CFFmpegShim.h"

#endif /* CFFMPEG_UMBRELLA_H */
