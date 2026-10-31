/* Recovery fixture CODE ONLY: UNCOMPILED/UNRUN. Include after the genuine
 * legacy rig, which supplies memory_file/read/write/seek, BODY_LIMIT and the
 * nine silent_pts/silent_duration values. No process, file or socket is used.
 *
 * The real MOV track order is DATA(gpmd), PCM, MOV_TEXT. Actual demux_lavf's
 * handle_new_stream ignores DATA and keeps each surviving FF stream index;
 * the public fixture must independently assert the resulting reference
 * command index2 differs from raw MPV stream index1. This helper never writes
 * MPV identities or treats expected ordering as an observed MPV result.
 *
 * Source contract inspected: retained libavformat/movenc.c mov_get_codec_tag,
 * mov_write_gpmd_tag, mov_write_subtitle_tag/end_packet and MOV muxer flags;
 * libavformat/isom.c ff_codec_movdata_tags; libavcodec/movtextenc.c sample
 * description shape. Unsupported real mux/demux behavior is an error, not a
 * skipped mapping case or a fallback to the equal-index Matroska corpus. */

static const uint8_t v2_mapping_text[] = "mapping embedded text";
static const uint8_t v2_mapping_data[] = {'V', '2', 'I', 'D', 0, 0, 0, 0};
static const uint8_t v2_mapping_tx3g[] = {
    0, 0, 0, 0,                   /* display flags */
    1, 255,                        /* centered, bottom justified */
    0, 0, 0, 0,                   /* transparent background */
    0, 0, 0, 0, 0, 0, 0, 0,       /* default text box */
    0, 0, 0, 0, 0, 1, 0, 18,      /* style: range0, font1, plain18 */
    255, 255, 255, 255,             /* opaque white text */
    0, 0, 0, 18, 'f', 't', 'a', 'b', 0, 1,
    0, 1, 5, 'S', 'e', 'r', 'i', 'f',
};
_Static_assert(sizeof(v2_mapping_tx3g) == 48, "complete tx3g description");

static bool v2_mapping_empty_time(int64_t pts, AVRational tb)
{
    if (pts == 0)
        return true;
    for (unsigned n = 0; n < 9; n++) {
        if (av_compare_ts(pts, tb, silent_pts[n] + silent_duration[n],
                          (AVRational){1, 1000}) == 0)
            return true;
    }
    return false;
}

static int v2_verify_mapping_media(const struct memory_file *media)
{
    if (!media || !media->bytes || !media->size || media->size > BODY_LIMIT)
        return AVERROR_INVALIDDATA;
    struct memory_file cursor = *media;
    cursor.position = 0;
    AVFormatContext *fmt = avformat_alloc_context();
    AVPacket *packet = av_packet_alloc();
    AVIOContext *io = NULL;
    uint8_t *buffer = av_malloc(4096);
    unsigned seen_data = 0, cues = 0, packets = 0;
    size_t audio_bytes = 0;
    int rc = AVERROR(ENOMEM);
    if (!fmt || !packet || !buffer ||
        !(io = avio_alloc_context(buffer, 4096, 0, &cursor,
                                 memory_read, NULL, memory_seek)))
        goto done;
    buffer = NULL;
    io->seekable = AVIO_SEEKABLE_NORMAL;
    fmt->pb = io;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    const AVInputFormat *input = av_find_input_format("mov");
    if (!input) { rc = AVERROR_DEMUXER_NOT_FOUND; goto done; }
    if ((rc = avformat_open_input(&fmt, NULL, input, NULL)) < 0)
        goto done;
    if (fmt->nb_streams != 3 ||
        fmt->streams[0]->index != 0 || fmt->streams[1]->index != 1 ||
        fmt->streams[2]->index != 2 ||
        fmt->streams[0]->codecpar->codec_type != AVMEDIA_TYPE_DATA ||
        fmt->streams[0]->codecpar->codec_id != AV_CODEC_ID_BIN_DATA ||
        fmt->streams[1]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO ||
        fmt->streams[1]->codecpar->codec_id != AV_CODEC_ID_PCM_S16LE ||
        fmt->streams[1]->codecpar->sample_rate != 8000 ||
        fmt->streams[1]->codecpar->ch_layout.nb_channels != 1 ||
        fmt->streams[2]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE ||
        fmt->streams[2]->codecpar->codec_id != AV_CODEC_ID_MOV_TEXT) {
        rc = AVERROR_INVALIDDATA; goto done;
    }
    for (unsigned n = 0; n < 3; n++) {
        if (fmt->streams[n]->time_base.num <= 0 ||
            fmt->streams[n]->time_base.den <= 0) {
            rc = AVERROR_INVALIDDATA; goto done;
        }
    }
    while ((rc = av_read_frame(fmt, packet)) >= 0) {
        int index = packet->stream_index;
        if (++packets > 64 || index < 0 || index >= 3 || packet->size <= 0 ||
            !packet->data || packet->pts == AV_NOPTS_VALUE ||
            packet->dts == AV_NOPTS_VALUE || packet->pts != packet->dts ||
            packet->duration < 0) {
            rc = AVERROR_INVALIDDATA; goto done;
        }
        AVRational tb = fmt->streams[index]->time_base;
        if (index == 0) {
            if (++seen_data != 1 || packet->pts != 0 ||
                packet->size != (int)sizeof(v2_mapping_data) ||
                memcmp(packet->data, v2_mapping_data, sizeof(v2_mapping_data))) {
                rc = AVERROR_INVALIDDATA; goto done;
            }
        } else if (index == 1) {
            /* Permit genuine PCM repacketization, while checking every byte,
             * its exact sample position/duration and the complete800 samples. */
            if ((packet->size & 1) || (size_t)packet->size > 1600 - audio_bytes ||
                av_compare_ts(packet->pts, tb, (int64_t)(audio_bytes / 2),
                              (AVRational){1, 8000}) != 0 ||
                av_compare_ts(packet->duration, tb, packet->size / 2,
                              (AVRational){1, 8000}) != 0) {
                rc = AVERROR_INVALIDDATA; goto done;
            }
            for (int n = 0; n < packet->size; n++) {
                if (packet->data[n]) { rc = AVERROR_INVALIDDATA; goto done; }
            }
            audio_bytes += (size_t)packet->size;
        } else if (packet->size == 2 && !packet->data[0] && !packet->data[1]) {
            /* The actual MOV muxer adds initial/end empty samples. They are
             * not timing cues; accept only its zero/known cue-end positions. */
            if (!v2_mapping_empty_time(packet->pts, tb)) {
                rc = AVERROR_INVALIDDATA; goto done;
            }
        } else {
            size_t text_bytes = sizeof(v2_mapping_text) - 1;
            if (cues >= 9 || packet->size != (int)(text_bytes + 2) ||
                packet->data[0] != (uint8_t)(text_bytes >> 8) ||
                packet->data[1] != (uint8_t)text_bytes ||
                memcmp(packet->data + 2, v2_mapping_text, text_bytes) ||
                av_compare_ts(packet->pts, tb, silent_pts[cues],
                              (AVRational){1, 1000}) != 0 ||
                av_compare_ts(packet->duration, tb, silent_duration[cues],
                              (AVRational){1, 1000}) != 0) {
                rc = AVERROR_INVALIDDATA; goto done;
            }
            cues++;
        }
        av_packet_unref(packet);
    }
    if (rc == AVERROR_EOF)
        rc = seen_data == 1 && audio_bytes == 1600 && cues == 9 ?
             0 : AVERROR_INVALIDDATA;
done:
    av_packet_free(&packet);
    avformat_close_input(&fmt);
    if (io) av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(buffer);
    return rc;
}

static int v2_make_mapping_media(struct memory_file *m)
{
    if (!m || m->bytes || m->size || m->capacity || m->position)
        return AVERROR(EINVAL);
    AVFormatContext *fmt = NULL;
    AVIOContext *io = NULL;
    AVPacket *packet = NULL;
    uint8_t *buffer = NULL;
    AVDictionary *options = NULL;
    int rc = avformat_alloc_output_context2(&fmt, NULL, "mov", NULL);
    if (rc < 0 || !fmt)
        return rc < 0 ? rc : AVERROR(ENOMEM);
    AVStream *data = avformat_new_stream(fmt, NULL);
    AVStream *audio = avformat_new_stream(fmt, NULL);
    AVStream *subtitle = avformat_new_stream(fmt, NULL);
    if (!data || !audio || !subtitle) { rc = AVERROR(ENOMEM); goto done; }
    data->time_base = (AVRational){1, 1000};
    data->codecpar->codec_type = AVMEDIA_TYPE_DATA;
    data->codecpar->codec_id = AV_CODEC_ID_BIN_DATA;
    data->codecpar->codec_tag = (unsigned)'g' | (unsigned)'p' << 8 |
                              (unsigned)'m' << 16 | (unsigned)'d' << 24;
    audio->time_base = (AVRational){1, 8000};
    audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    audio->codecpar->codec_id = AV_CODEC_ID_PCM_S16LE;
    audio->codecpar->format = AV_SAMPLE_FMT_S16;
    audio->codecpar->sample_rate = 8000;
    audio->codecpar->bits_per_coded_sample = 16;
    audio->codecpar->bits_per_raw_sample = 16;
    audio->codecpar->block_align = 2;
    audio->codecpar->bit_rate = 128000;
    av_channel_layout_default(&audio->codecpar->ch_layout, 1);
    subtitle->time_base = (AVRational){1, 1000};
    subtitle->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
    subtitle->codecpar->codec_id = AV_CODEC_ID_MOV_TEXT;
    subtitle->codecpar->codec_tag = (unsigned)'t' | (unsigned)'x' << 8 |
                                  (unsigned)'3' << 16 | (unsigned)'g' << 24;
    subtitle->codecpar->extradata = av_mallocz(sizeof(v2_mapping_tx3g) +
                                              AV_INPUT_BUFFER_PADDING_SIZE);
    if (!subtitle->codecpar->extradata) { rc = AVERROR(ENOMEM); goto done; }
    memcpy(subtitle->codecpar->extradata, v2_mapping_tx3g, sizeof(v2_mapping_tx3g));
    subtitle->codecpar->extradata_size = (int)sizeof(v2_mapping_tx3g);
    subtitle->disposition = AV_DISPOSITION_DEFAULT;
    if ((rc = av_dict_set(&subtitle->metadata, "language", "eng", 0)) < 0)
        goto done;
    buffer = av_malloc(4096);
    packet = av_packet_alloc();
    if (!buffer || !packet ||
        !(io = avio_alloc_context(buffer, 4096, 1, m,
                                 NULL, memory_write, memory_seek))) {
        rc = AVERROR(ENOMEM); goto done;
    }
    buffer = NULL;
    io->seekable = AVIO_SEEKABLE_NORMAL;
    fmt->pb = io;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    fmt->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    if ((rc = av_dict_set(&options, "movflags",
            "frag_keyframe+empty_moov+default_base_moof", 0)) < 0 ||
        /* All tracks have a real sample at zero, including the MOV muxer's
         * empty subtitle sample. No edit list or origin shift is required. */
        (rc = av_dict_set(&options, "use_editlist", "0", 0)) < 0 ||
        (rc = avformat_write_header(fmt, &options)) < 0)
        goto done;
    if (av_dict_count(options)) { rc = AVERROR_OPTION_NOT_FOUND; goto done; }
    if ((rc = av_new_packet(packet, (int)sizeof(v2_mapping_data))) < 0)
        goto done;
    memcpy(packet->data, v2_mapping_data, sizeof(v2_mapping_data));
    packet->stream_index = 0;
    packet->pts = packet->dts = 0;
    packet->duration = 1;
    packet->flags = AV_PKT_FLAG_KEY;
    av_packet_rescale_ts(packet, (AVRational){1, 1000}, data->time_base);
    if ((rc = av_interleaved_write_frame(fmt, packet)) < 0)
        goto done;
    if ((rc = av_new_packet(packet, 1600)) < 0)
        goto done;
    memset(packet->data, 0, 1600);
    packet->stream_index = 1;
    packet->pts = packet->dts = 0;
    packet->duration = 800;
    packet->flags = AV_PKT_FLAG_KEY;
    av_packet_rescale_ts(packet, (AVRational){1, 8000}, audio->time_base);
    if ((rc = av_interleaved_write_frame(fmt, packet)) < 0)
        goto done;
    for (unsigned cue = 0; cue < 9; cue++) {
        size_t text_bytes = sizeof(v2_mapping_text) - 1;
        if ((rc = av_new_packet(packet, (int)(text_bytes + 2))) < 0)
            goto done;
        packet->data[0] = (uint8_t)(text_bytes >> 8);
        packet->data[1] = (uint8_t)text_bytes;
        memcpy(packet->data + 2, v2_mapping_text, text_bytes);
        packet->stream_index = 2;
        packet->pts = packet->dts = silent_pts[cue];
        packet->duration = silent_duration[cue];
        packet->flags = AV_PKT_FLAG_KEY;
        av_packet_rescale_ts(packet, (AVRational){1, 1000}, subtitle->time_base);
        if ((rc = av_interleaved_write_frame(fmt, packet)) < 0)
            goto done;
    }
    if ((rc = av_write_trailer(fmt)) < 0)
        goto done;
    avio_flush(io);
    rc = io->error < 0 ? io->error :
         m->size && m->size <= BODY_LIMIT ? 0 : AVERROR_INVALIDDATA;
done:
    av_dict_free(&options);
    av_packet_free(&packet);
    fmt->pb = NULL;
    avformat_free_context(fmt);
    if (io) av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(buffer);
    if (rc >= 0)
        rc = v2_verify_mapping_media(m);
    if (rc < 0) {
        av_freep(&m->bytes);
        *m = (struct memory_file){0};
    }
    return rc;
}
