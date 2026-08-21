#ifndef RCAM_CFFMPEG_SHIM_H
#define RCAM_CFFMPEG_SHIM_H

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>

// AVERROR* are function-like macros Swift can't import.
static inline int rcam_averror_eof(void) { return AVERROR_EOF; }
static inline int rcam_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int rcam_averror_exit(void) { return AVERROR_EXIT; }

#endif
