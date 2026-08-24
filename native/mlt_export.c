/* native/mlt_export.c */
#include "mlt_export.h"
#include "mlt_composition.h"

#include <framework/mlt.h>
#include <glib.h>

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>

#define MLT_EXPORT_DEINTERLACER "onefield"

#if defined(__GNUC__)
#define MLT_EXPORT_API __attribute__((visibility("default")))
#else
#define MLT_EXPORT_API
#endif

/* ------------------------------------------------------------------------- */

/*
 * Export owns a completely separate producer/profile/consumer graph from
 * preview playback. Only these small status fields cross thread boundaries.
 */
static GMutex export_mutex;
static GThread *export_thread = NULL;
static int export_running = 0;
static int export_success = 0;
static int export_cancel_requested = 0;
static double export_progress = 0.0;
static char export_error[512] = "";

/*
 * Purpose-named movie export presets. The selected process-level value is
 * copied into each ExportJob before its worker starts, so a later UI change
 * cannot mutate an export already in flight.
 */
enum {
    EXPORT_VIDEO_PRESET_H264_DELIVERY = 0,
    EXPORT_VIDEO_PRESET_PRORES_422_HQ = 1
};

static int export_video_preset = EXPORT_VIDEO_PRESET_H264_DELIVERY;

/*
 * 0/1 means "match the source profile". Non-zero values are canonical
 * rational output rates selected by the UI. Like the codec preset, the pair
 * is copied into each ExportJob before the worker starts.
 */
static int export_video_frame_rate_num = 0;
static int export_video_frame_rate_den = 1;

typedef struct _ExportJob {
    char *export_source_path;
    char *export_secondary_path;
    char *export_tertiary_path;
    char *export_output_path;
    int64_t export_in_frame;
    int64_t export_out_frame;
    int64_t export_secondary_start_frame;
    int64_t export_secondary_end_frame;
    int64_t export_secondary_source_in_frame;
    int64_t export_secondary_source_out_frame;
    int64_t export_tertiary_start_frame;
    int64_t export_tertiary_end_frame;
    int64_t export_tertiary_source_in_frame;
    int64_t export_tertiary_source_out_frame;
    int export_has_secondary;
    int export_has_tertiary;
    int export_snapshot_valid;
    int export_visual_order[MLT_COMPOSITION_MAX_LAYERS];
    int export_primary_has_audio;
    int export_secondary_has_audio;
    int export_secondary_is_still;
    int export_secondary_alpha_mode;
    int export_tertiary_has_audio;
    int export_tertiary_is_still;
    int export_tertiary_alpha_mode;
    double export_primary_audio_gain;
    double export_secondary_audio_gain;
    double export_secondary_opacity;
    double export_secondary_x;
    double export_secondary_y;
    double export_secondary_scale;
    double export_tertiary_audio_gain;
    double export_tertiary_opacity;
    double export_tertiary_x;
    double export_tertiary_y;
    double export_tertiary_scale;
    int export_video_preset;
    int export_video_frame_rate_num;
    int export_video_frame_rate_den;
    MltExportKind export_kind;
} ExportJob;

typedef struct _ExportGraph {
    mlt_profile export_profile;
    mlt_producer export_primary;
    mlt_producer export_secondary;
    mlt_playlist export_secondary_playlist;
    mlt_producer export_tertiary;
    mlt_playlist export_tertiary_playlist;
    mlt_tractor export_tractor;
    mlt_playlist export_visual_canvas;
    mlt_transition export_primary_composite;
    mlt_transition export_primary_mix;
    mlt_transition export_composite;
    mlt_transition export_mix;
    mlt_transition export_tertiary_composite;
    mlt_transition export_tertiary_mix;
    mlt_producer export_top;
    int source_frame_rate_num;
    int source_frame_rate_den;
    double source_fps;
    double output_fps;
    MltCompositionDerivedState derived;
} ExportGraph;


typedef struct _ExportTelemetry {
    gint64 worker_started_us;
    gint64 graph_ready_us;
    gint64 consumer_ready_us;
    gint64 encode_started_us;
    gint64 encode_finished_us;
    gint64 flush_finished_us;
    gint64 last_report_us;
    int64_t total_frames;
    int64_t frames_completed;
    int64_t current_position;
    int output_width;
    int output_height;
    double source_fps;
    double output_fps;
    int consumer_real_time;
    int consumer_buffer;
    int consumer_prefill;
    double worker_started_cpu_seconds;
    double encode_started_cpu_seconds;
    double encode_finished_cpu_seconds;
} ExportTelemetry;

static gsize export_lock_initialized = 0;

static void ensure_export_lock(void)
{
    if (g_once_init_enter(&export_lock_initialized)) {
        g_mutex_init(&export_mutex);
        g_once_init_leave(&export_lock_initialized, 1);
    }
}

/* ------------------------------------------------------------------------- */

static void export_set_error_locked(const char *message)
{
    if (message == NULL) {
        export_error[0] = '\0';
        return;
    }

    snprintf(
        export_error,
        sizeof(export_error),
        "%s",
        message
    );
}

static int export_cancel_was_requested(void)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);
    const int requested = export_cancel_requested;
    g_mutex_unlock(&export_mutex);

    return requested;
}

static void export_publish_progress(double value)
{
    if (value < 0.0) {
        value = 0.0;
    } else if (value > 1.0) {
        value = 1.0;
    }

    ensure_export_lock();

    g_mutex_lock(&export_mutex);
    export_progress = value;
    g_mutex_unlock(&export_mutex);
}

static int output_file_has_data(const char *path)
{
    struct stat info;

    return path != NULL &&
        stat(path, &info) == 0 &&
        info.st_size > 0;
}


static int64_t output_file_size(const char *path)
{
    struct stat info;

    if (path == NULL ||
        stat(path, &info) != 0 ||
        info.st_size < 0) {
        return 0;
    }

    return (int64_t)info.st_size;
}

static const char *export_kind_name(const ExportJob *job)
{
    if (job == NULL) {
        return "unknown";
    }

    switch (job->export_kind) {
        case MLT_EXPORT_KIND_MP4:
            return job->export_video_preset == EXPORT_VIDEO_PRESET_PRORES_422_HQ
                ? "mov"
                : "mp4";
        case MLT_EXPORT_KIND_PNG_FRAME:
            return "png_frame";
        case MLT_EXPORT_KIND_PNG_SEQUENCE:
            return "png_sequence";
        case MLT_EXPORT_KIND_WAV_AUDIO:
            return "wav_audio";
        default:
            return "unknown";
    }
}

static const char *export_video_codec_name(const ExportJob *job)
{
    if (job == NULL || job->export_kind != MLT_EXPORT_KIND_MP4) {
        return "n/a";
    }

    return job->export_video_preset == EXPORT_VIDEO_PRESET_PRORES_422_HQ
        ? "prores_ks"
        : "libx264";
}

static const char *export_video_preset_name(const ExportJob *job)
{
    if (job == NULL || job->export_kind != MLT_EXPORT_KIND_MP4) {
        return "n/a";
    }

    return job->export_video_preset == EXPORT_VIDEO_PRESET_PRORES_422_HQ
        ? "prores_422_hq_master"
        : "h264_delivery";
}

static int export_video_frame_rate_is_supported(
    int numerator,
    int denominator)
{
    if (numerator == 0) {
        return denominator == 1;
    }

    static const int supported[][2] = {
        {24000, 1001},
        {24, 1},
        {25, 1},
        {30000, 1001},
        {30, 1},
        {50, 1},
        {60000, 1001},
        {60, 1},
    };

    for (size_t index = 0;
         index < sizeof(supported) / sizeof(supported[0]);
         index++) {
        if (supported[index][0] == numerator &&
            supported[index][1] == denominator) {
            return 1;
        }
    }

    return 0;
}

static int export_job_has_explicit_video_frame_rate(
    const ExportJob *job)
{
    return job != NULL &&
        job->export_kind == MLT_EXPORT_KIND_MP4 &&
        job->export_video_frame_rate_num > 0 &&
        job->export_video_frame_rate_den > 0;
}

/*
 * Convert a frame boundary by time instead of by frame number. Using
 * boundaries is important for inclusive In/Out ranges: [0..24] at 25 fps is
 * one second, so its exclusive end boundary is frame 25 and becomes frame 30
 * at 30 fps.
 */
static int64_t export_scale_frame_boundary(
    int64_t source_boundary,
    int source_num,
    int source_den,
    int target_num,
    int target_den)
{
    if (source_boundary <= 0) {
        return 0;
    }

    if (source_num <= 0 ||
        source_den <= 0 ||
        target_num <= 0 ||
        target_den <= 0) {
        return source_boundary;
    }

    if ((int64_t)source_num * target_den ==
        (int64_t)target_num * source_den) {
        return source_boundary;
    }

    const long double scaled =
        ((long double)source_boundary *
         (long double)target_num *
         (long double)source_den) /
        ((long double)source_num *
         (long double)target_den);

    if (scaled >= (long double)INT64_MAX) {
        return INT64_MAX;
    }

    return (int64_t)(scaled + 0.5L);
}

static char *export_report_path(const ExportJob *job)
{
    if (job == NULL ||
        job->export_output_path == NULL ||
        job->export_output_path[0] == '\0') {
        return NULL;
    }

    if (job->export_kind == MLT_EXPORT_KIND_PNG_SEQUENCE) {
        return g_build_filename(
            job->export_output_path,
            "export.json",
            NULL
        );
    }

    return g_strdup_printf(
        "%s.export.json",
        job->export_output_path
    );
}

static void export_json_write_string(
    FILE *file,
    const char *value)
{
    fputc('"', file);

    if (value != NULL) {
        const unsigned char *cursor =
            (const unsigned char *)value;

        while (*cursor != 0) {
            switch (*cursor) {
                case '"':
                    fputs("\\\"", file);
                    break;
                case '\\':
                    fputs("\\\\", file);
                    break;
                case '\b':
                    fputs("\\b", file);
                    break;
                case '\f':
                    fputs("\\f", file);
                    break;
                case '\n':
                    fputs("\\n", file);
                    break;
                case '\r':
                    fputs("\\r", file);
                    break;
                case '\t':
                    fputs("\\t", file);
                    break;
                default:
                    if (*cursor < 0x20) {
                        fprintf(file, "\\u%04x", (unsigned int)*cursor);
                    } else {
                        fputc((int)*cursor, file);
                    }
                    break;
            }

            cursor += 1;
        }
    }

    fputc('"', file);
}

static void export_utc_timestamp(
    char *buffer,
    size_t capacity)
{
    if (buffer == NULL || capacity == 0) {
        return;
    }

    const time_t now = time(NULL);
    struct tm utc;

    if (now == (time_t)-1 ||
        gmtime_r(&now, &utc) == NULL ||
        strftime(
            buffer,
            capacity,
            "%Y-%m-%dT%H:%M:%SZ",
            &utc) == 0) {
        snprintf(buffer, capacity, "unknown");
    }
}

static double export_process_cpu_seconds(
    int64_t *max_rss_kb_out)
{
    struct rusage usage;

    if (getrusage(RUSAGE_SELF, &usage) != 0) {
        if (max_rss_kb_out != NULL) {
            *max_rss_kb_out = 0;
        }
        return 0.0;
    }

    if (max_rss_kb_out != NULL) {
        *max_rss_kb_out = (int64_t)usage.ru_maxrss;
    }

    const double user_seconds =
        (double)usage.ru_utime.tv_sec +
        (double)usage.ru_utime.tv_usec / 1000000.0;
    const double system_seconds =
        (double)usage.ru_stime.tv_sec +
        (double)usage.ru_stime.tv_usec / 1000000.0;

    return user_seconds + system_seconds;
}

static double export_elapsed_seconds(
    gint64 start_us,
    gint64 end_us)
{
    if (start_us <= 0 || end_us <= start_us) {
        return 0.0;
    }

    return (double)(end_us - start_us) / 1000000.0;
}

static void export_update_frame_telemetry(
    ExportTelemetry *telemetry,
    mlt_producer producer)
{
    if (telemetry == NULL || producer == NULL) {
        return;
    }

    int64_t position =
        (int64_t)mlt_producer_position(producer);

    telemetry->current_position = position;

    int64_t completed = position + 1;

    if (completed < 0) {
        completed = 0;
    }

    if (telemetry->total_frames > 0 &&
        completed > telemetry->total_frames) {
        completed = telemetry->total_frames;
    }

    telemetry->frames_completed = completed;
}

static int export_write_report(
    const ExportJob *job,
    const ExportTelemetry *telemetry,
    const char *status,
    const char *error_message,
    gint64 now_us)
{
    if (job == NULL || telemetry == NULL) {
        return 0;
    }

    char *report_path = export_report_path(job);

    if (report_path == NULL) {
        return 0;
    }

    char *temp_path =
        g_strdup_printf("%s.tmp", report_path);

    if (temp_path == NULL) {
        g_free(report_path);
        return 0;
    }

    FILE *file = fopen(temp_path, "wb");

    if (file == NULL) {
        g_free(temp_path);
        g_free(report_path);
        return 0;
    }

    const double total_seconds =
        export_elapsed_seconds(
            telemetry->worker_started_us,
            now_us
        );
    const gint64 encode_end_us =
        telemetry->encode_finished_us > 0
            ? telemetry->encode_finished_us
            : now_us;
    const double encode_seconds =
        export_elapsed_seconds(
            telemetry->encode_started_us,
            encode_end_us
        );
    const double effective_fps =
        encode_seconds > 0.0
            ? (double)telemetry->frames_completed / encode_seconds
            : 0.0;
    const double speed_vs_realtime =
        telemetry->source_fps > 0.0
            ? effective_fps / telemetry->source_fps
            : 0.0;
    const double progress =
        telemetry->total_frames > 0
            ? (double)telemetry->frames_completed /
                (double)telemetry->total_frames
            : 0.0;
    const int render_threads =
        telemetry->consumer_real_time < 0
            ? -telemetry->consumer_real_time
            : telemetry->consumer_real_time;
    const int drops_frames =
        telemetry->consumer_real_time > 0 ? 1 : 0;

    int64_t max_rss_kb = 0;
    const double process_cpu_now =
        export_process_cpu_seconds(&max_rss_kb);
    const double process_cpu_seconds =
        process_cpu_now >= telemetry->worker_started_cpu_seconds
            ? process_cpu_now - telemetry->worker_started_cpu_seconds
            : 0.0;
    const double encode_cpu_end =
        telemetry->encode_finished_cpu_seconds > 0.0
            ? telemetry->encode_finished_cpu_seconds
            : process_cpu_now;
    const double encode_cpu_seconds =
        encode_cpu_end >= telemetry->encode_started_cpu_seconds
            ? encode_cpu_end - telemetry->encode_started_cpu_seconds
            : 0.0;
    const double average_cpu_cores =
        encode_seconds > 0.0
            ? encode_cpu_seconds / encode_seconds
            : 0.0;
    const guint machine_processors = g_get_num_processors();
    const double machine_cpu_percent =
        machine_processors > 0
            ? (average_cpu_cores / (double)machine_processors) * 100.0
            : 0.0;

    char updated_at[64];
    export_utc_timestamp(updated_at, sizeof(updated_at));

    fputs("{\n", file);
    fputs("  \"schema\": \"mlt-player-export-report-v1\",\n", file);
    fputs("  \"updated_at_utc\": ", file);
    export_json_write_string(file, updated_at);
    fputs(",\n  \"status\": ", file);
    export_json_write_string(file, status != NULL ? status : "unknown");
    fputs(",\n  \"error\": ", file);
    if (error_message != NULL && error_message[0] != '\0') {
        export_json_write_string(file, error_message);
    } else {
        fputs("null", file);
    }
    fputs(",\n  \"export_kind\": ", file);
    export_json_write_string(file, export_kind_name(job));
    fputs(",\n  \"output_path\": ", file);
    export_json_write_string(file, job->export_output_path);
    fputs(",\n  \"source_path\": ", file);
    export_json_write_string(file, job->export_source_path);
    fprintf(
        file,
        ",\n  \"range\": {\"in_frame\": %lld, \"out_frame\": %lld, \"total_frames\": %lld},\n",
        (long long)job->export_in_frame,
        (long long)job->export_out_frame,
        (long long)telemetry->total_frames
    );
    fprintf(
        file,
        "  \"progress\": {\"frames_completed\": %lld, \"current_position\": %lld, \"fraction\": %.6f, \"percent\": %.2f},\n",
        (long long)telemetry->frames_completed,
        (long long)telemetry->current_position,
        progress,
        progress * 100.0
    );
    fprintf(
        file,
        "  \"video\": {\"width\": %d, \"height\": %d, \"source_fps\": %.6f, \"output_fps\": %.6f, \"codec\": \"%s\", \"preset\": \"%s\", \"crf\": %d},\n",
        telemetry->output_width,
        telemetry->output_height,
        telemetry->source_fps,
        telemetry->output_fps,
        export_video_codec_name(job),
        export_video_preset_name(job),
        job->export_kind == MLT_EXPORT_KIND_MP4 &&
                job->export_video_preset == EXPORT_VIDEO_PRESET_H264_DELIVERY
            ? 18
            : 0
    );
    fprintf(
        file,
        "  \"mlt_consumer\": {\"real_time\": %d, \"render_threads\": %d, \"frame_dropping\": %s, \"buffer_frames\": %d, \"prefill_frames\": %d},\n",
        telemetry->consumer_real_time,
        render_threads,
        drops_frames ? "true" : "false",
        telemetry->consumer_buffer,
        telemetry->consumer_prefill
    );
    fprintf(
        file,
        "  \"composition\": {\"layers\": %d, "
        "\"layer2_start_frame\": %lld, \"layer2_is_still\": %s, "
        "\"layer2_alpha_mode\": %d, \"layer2_opacity\": %.6f, "
        "\"layer2_scale\": %.6f, \"layer3_start_frame\": %lld, "
        "\"layer3_is_still\": %s, \"layer3_alpha_mode\": %d, "
        "\"layer3_opacity\": %.6f, \"layer3_scale\": %.6f},\n",
        job->export_has_tertiary ? 3 : (job->export_has_secondary ? 2 : 1),
        (long long)job->export_secondary_start_frame,
        job->export_secondary_is_still ? "true" : "false",
        job->export_secondary_alpha_mode,
        job->export_secondary_opacity,
        job->export_secondary_scale,
        (long long)job->export_tertiary_start_frame,
        job->export_tertiary_is_still ? "true" : "false",
        job->export_tertiary_alpha_mode,
        job->export_tertiary_opacity,
        job->export_tertiary_scale
    );
    fprintf(
        file,
        "  \"timing_seconds\": {\"graph_setup\": %.6f, \"consumer_setup\": %.6f, \"encode\": %.6f, \"flush\": %.6f, \"total\": %.6f},\n",
        export_elapsed_seconds(
            telemetry->worker_started_us,
            telemetry->graph_ready_us
        ),
        export_elapsed_seconds(
            telemetry->graph_ready_us,
            telemetry->consumer_ready_us
        ),
        encode_seconds,
        export_elapsed_seconds(
            telemetry->encode_finished_us,
            telemetry->flush_finished_us
        ),
        total_seconds
    );
    fprintf(
        file,
        "  \"performance\": {\"effective_fps\": %.6f, \"milliseconds_per_frame\": %.6f, \"speed_vs_realtime\": %.6f},\n",
        effective_fps,
        effective_fps > 0.0 ? 1000.0 / effective_fps : 0.0,
        speed_vs_realtime
    );
    fprintf(
        file,
        "  \"process\": {\"cpu_seconds\": %.6f, \"encode_cpu_seconds\": %.6f, \"average_cpu_cores_used\": %.6f, \"average_cpu_percent_of_machine\": %.2f, \"peak_rss_kb\": %lld},\n",
        process_cpu_seconds,
        encode_cpu_seconds,
        average_cpu_cores,
        machine_cpu_percent,
        (long long)max_rss_kb
    );
    fprintf(
        file,
        "  \"output_bytes\": %lld,\n",
        (long long)(
            job->export_kind == MLT_EXPORT_KIND_PNG_SEQUENCE
                ? 0
                : output_file_size(job->export_output_path)
        )
    );
    fprintf(
        file,
        "  \"diagnostics\": {\"single_mlt_render_thread\": %s}\n",
        render_threads == 1 ? "true" : "false"
    );
    fputs("}\n", file);

    const int flush_ok = fflush(file) == 0;
    const int close_ok = fclose(file) == 0;
    const int write_ok = flush_ok && close_ok;

    int installed = 0;

    if (write_ok && rename(temp_path, report_path) == 0) {
        installed = 1;
    } else {
        remove(temp_path);
    }

    g_free(temp_path);
    g_free(report_path);
    return installed;
}

/*
 * image2 treats percent signs in its target as filename-pattern syntax.
 * Escape any literal percent signs in the chosen directory before appending
 * the one pattern token that belongs to this export.
 */
static char *export_sequence_consumer_target(
    const char *directory)
{
    if (directory == NULL ||
        directory[0] == '\0') {
        return NULL;
    }

    GString *escaped =
        g_string_sized_new(strlen(directory) + 32);

    if (escaped == NULL) {
        return NULL;
    }

    for (const char *cursor = directory;
         *cursor != '\0';
         cursor++) {
        if (*cursor == '%') {
            g_string_append(escaped, "%%");
        } else {
            g_string_append_c(escaped, *cursor);
        }
    }

    char *target =
        g_build_filename(
            escaped->str,
            "frame_%06d.png",
            NULL
        );

    g_string_free(escaped, TRUE);

    return target;
}

static int64_t export_sequence_frame_number(
    const char *name)
{
    static const char prefix[] = "frame_";
    static const char suffix[] = ".png";

    if (name == NULL ||
        !g_str_has_prefix(name, prefix) ||
        !g_str_has_suffix(name, suffix)) {
        return -1;
    }

    const size_t name_length = strlen(name);
    const size_t prefix_length = strlen(prefix);
    const size_t suffix_length = strlen(suffix);

    if (name_length <= prefix_length + suffix_length) {
        return -1;
    }

    const size_t digits_length =
        name_length - prefix_length - suffix_length;

    if (digits_length < 6) {
        return -1;
    }

    int64_t value = 0;

    for (size_t index = 0;
         index < digits_length;
         index++) {
        const char digit =
            name[prefix_length + index];

        if (digit < '0' || digit > '9') {
            return -1;
        }

        const int next_digit = digit - '0';

        if (value > (G_MAXINT64 - next_digit) / 10) {
            return -1;
        }

        value = (value * 10) + next_digit;
    }

    return value > 0 ? value : -1;
}

static int export_sequence_filename_is_owned(
    const char *name)
{
    return export_sequence_frame_number(name) > 0;
}

static int export_directory_is_empty(
    const char *directory)
{
    if (directory == NULL ||
        directory[0] == '\0') {
        return 0;
    }

    GDir *dir =
        g_dir_open(directory, 0, NULL);

    if (dir == NULL) {
        return 0;
    }

    const char *name =
        g_dir_read_name(dir);

    const int is_empty =
        name == NULL;

    g_dir_close(dir);

    return is_empty;
}

/*
 * Sequence exports always target a dedicated directory created by the Dart
 * UI. On cancellation or failure, delete only filenames owned by this export
 * and then remove the directory if it is empty. This preserves the same
 * "no partial output" contract used by movie and still exports.
 */
static void export_remove_sequence_outputs(
    const char *directory)
{
    if (directory == NULL ||
        directory[0] == '\0') {
        return;
    }

    GDir *dir =
        g_dir_open(directory, 0, NULL);

    if (dir != NULL) {
        const char *name = NULL;

        while ((name = g_dir_read_name(dir)) != NULL) {
            if (!export_sequence_filename_is_owned(name)) {
                continue;
            }

            char *path =
                g_build_filename(
                    directory,
                    name,
                    NULL
                );

            if (path != NULL) {
                remove(path);
                g_free(path);
            }
        }

        g_dir_close(dir);
    }

    /*
     * remove() also removes an empty directory on POSIX. If a caller placed
     * unrelated files there, it safely fails and leaves the directory alone.
     */
    remove(directory);
}

static void export_remove_partial_output(
    const ExportJob *job)
{
    if (job == NULL) {
        return;
    }

    if (job->export_kind == MLT_EXPORT_KIND_PNG_SEQUENCE) {
        export_remove_sequence_outputs(job->export_output_path);
        return;
    }

    remove(job->export_output_path);
}

static void export_job_free(ExportJob *job)
{
    if (job == NULL) {
        return;
    }

    g_free(job->export_source_path);
    g_free(job->export_secondary_path);
    g_free(job->export_tertiary_path);
    g_free(job->export_output_path);
    g_free(job);
}

static void export_set_failure(
    char *failure,
    size_t failure_size,
    const char *message)
{
    if (failure == NULL ||
        failure_size == 0) {
        return;
    }

    snprintf(
        failure,
        failure_size,
        "%s",
        message != NULL ? message : "Export failed."
    );
}

static int export_prepare_destination(
    const ExportJob *job,
    char *failure,
    size_t failure_size)
{
    if (job->export_kind == MLT_EXPORT_KIND_PNG_SEQUENCE) {
        if (!g_file_test(
                job->export_output_path,
                G_FILE_TEST_IS_DIR)) {
            export_set_failure(
                failure,
                failure_size,
                "The image-sequence destination directory is unavailable."
            );
            return 0;
        }

        /*
         * Native code enforces the same ownership contract as the Dart UI:
         * a sequence export only starts in a fresh, empty directory. This
         * makes cancellation cleanup safe even for callers outside Flutter.
         */
        if (!export_directory_is_empty(job->export_output_path)) {
            export_set_failure(
                failure,
                failure_size,
                "The image-sequence destination directory must be empty."
            );
            return 0;
        }

        return 1;
    }

    /*
     * Save dialogs handle overwrite confirmation for single-file exports.
     * Remove the destination immediately before encoding so avformat always
     * receives a fresh target.
     */
    remove(job->export_output_path);

    return 1;
}

/*
 * Build the independent source graph shared by every export kind.
 *
 * The source is probed once to derive its native profile, reopened against
 * that profile, constrained to the requested absolute source-frame range,
 * then rebased so producer position zero is the first export frame.
 */
static void export_graph_close(ExportGraph *graph)
{
    if (graph == NULL) {
        return;
    }

    graph->export_top = NULL;

    if (graph->export_tractor != NULL) {
        mlt_tractor_close(graph->export_tractor);
        graph->export_tractor = NULL;
    }

    if (graph->export_visual_canvas != NULL) {
        mlt_playlist_close(graph->export_visual_canvas);
        graph->export_visual_canvas = NULL;
    }

    if (graph->export_primary_composite != NULL) {
        mlt_transition_close(graph->export_primary_composite);
        graph->export_primary_composite = NULL;
    }

    if (graph->export_primary_mix != NULL) {
        mlt_transition_close(graph->export_primary_mix);
        graph->export_primary_mix = NULL;
    }

    if (graph->export_composite != NULL) {
        mlt_transition_close(graph->export_composite);
        graph->export_composite = NULL;
    }

    if (graph->export_mix != NULL) {
        mlt_transition_close(graph->export_mix);
        graph->export_mix = NULL;
    }

    if (graph->export_tertiary_composite != NULL) {
        mlt_transition_close(graph->export_tertiary_composite);
        graph->export_tertiary_composite = NULL;
    }

    if (graph->export_tertiary_mix != NULL) {
        mlt_transition_close(graph->export_tertiary_mix);
        graph->export_tertiary_mix = NULL;
    }

    if (graph->export_tertiary_playlist != NULL) {
        mlt_playlist_close(graph->export_tertiary_playlist);
        graph->export_tertiary_playlist = NULL;
    }

    if (graph->export_tertiary != NULL) {
        mlt_producer_close(graph->export_tertiary);
        graph->export_tertiary = NULL;
    }

    if (graph->export_secondary_playlist != NULL) {
        mlt_playlist_close(graph->export_secondary_playlist);
        graph->export_secondary_playlist = NULL;
    }

    if (graph->export_secondary != NULL) {
        mlt_producer_close(graph->export_secondary);
        graph->export_secondary = NULL;
    }

    if (graph->export_primary != NULL) {
        mlt_producer_close(graph->export_primary);
        graph->export_primary = NULL;
    }

    if (graph->export_profile != NULL) {
        mlt_profile_close(graph->export_profile);
        graph->export_profile = NULL;
    }
}

static int export_attach_audio_gain(
    mlt_profile export_profile,
    mlt_producer target,
    double gain)
{
    if (export_profile == NULL || target == NULL) {
        return 0;
    }

    mlt_filter filter =
        mlt_factory_filter(
            export_profile,
            "volume",
            NULL
        );

    if (filter == NULL) {
        return 0;
    }

    mlt_properties_set_double(
        MLT_FILTER_PROPERTIES(filter),
        "gain",
        gain
    );

    const int attached =
        mlt_producer_attach(
            target,
            filter
        ) == 0;

    mlt_filter_close(filter);
    return attached;
}

static int export_attach_still_converter(
    mlt_profile export_profile,
    mlt_producer target)
{
    if (export_profile == NULL || target == NULL) {
        return 0;
    }

    mlt_filter filter =
        mlt_factory_filter(
            export_profile,
            "avcolor_space",
            NULL
        );

    if (filter == NULL) {
        filter =
            mlt_factory_filter(
                export_profile,
                "imageconvert",
                NULL
            );
    }

    if (filter == NULL) {
        return 0;
    }

    const int attached =
        mlt_producer_attach(
            target,
            filter
        ) == 0;

    mlt_filter_close(filter);
    return attached;
}

static int export_attach_alpha_interpretation(
    mlt_producer target,
    int mode)
{
    return mlt_composition_attach_alpha_filter(
               target,
               mode
           ) != NULL;
}


static int export_visual_order_is_permutation(
    const int order[MLT_COMPOSITION_MAX_LAYERS])
{
    int seen[MLT_COMPOSITION_MAX_LAYERS] = {0};
    for (int position = 0; position < MLT_COMPOSITION_MAX_LAYERS; position++) {
        const int layer = order[position];
        if (layer < 0 || layer >= MLT_COMPOSITION_MAX_LAYERS || seen[layer]) {
            return 0;
        }
        seen[layer] = 1;
    }
    return 1;
}

static mlt_producer export_logical_layer_producer(
    ExportGraph *graph,
    int layer_index)
{
    if (graph == NULL) {
        return NULL;
    }
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) {
        return graph->export_primary;
    }
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY &&
        graph->export_secondary_playlist != NULL) {
        return mlt_playlist_producer(graph->export_secondary_playlist);
    }
    if (layer_index == MLT_COMPOSITION_SECOND_OVERLAY &&
        graph->export_tertiary_playlist != NULL) {
        return mlt_playlist_producer(graph->export_tertiary_playlist);
    }
    return NULL;
}

static int export_configure_sum_mix(mlt_transition transition)
{
    if (transition == NULL) {
        return 0;
    }
    mlt_properties properties = MLT_TRANSITION_PROPERTIES(transition);
    mlt_properties_set_int(properties, "always_active", 1);
    mlt_properties_set_double(properties, "start", 1.0);
    mlt_properties_set_double(properties, "end", 1.0);
    mlt_properties_set_int(properties, "sum", 1);
    return 1;
}

static int export_rebuild_visual_order(
    const ExportJob *job,
    ExportGraph *graph,
    char *failure,
    size_t failure_size)
{
    if (job == NULL || graph == NULL || graph->derived.layer_count <= 1) {
        return 1;
    }
    if (!export_visual_order_is_permutation(job->export_visual_order)) {
        export_set_failure(failure, failure_size, "The export visual layer order is invalid.");
        return 0;
    }

    int present_order[MLT_COMPOSITION_MAX_LAYERS] = {-1, -1, -1};
    int present_count = 0;
    for (int position = 0; position < MLT_COMPOSITION_MAX_LAYERS; position++) {
        const int logical = job->export_visual_order[position];
        if (logical < graph->derived.layer_count) {
            present_order[present_count++] = logical;
        }
    }
    if (present_count != graph->derived.layer_count) {
        export_set_failure(failure, failure_size, "The export visual order is missing a present layer.");
        return 0;
    }

    int already_default = 1;
    for (int position = 0; position < present_count; position++) {
        if (present_order[position] != position) {
            already_default = 0;
            break;
        }
    }
    if (already_default) {
        return 1;
    }

    const int64_t length = graph->derived.composition_length;
    if (length <= 0) {
        export_set_failure(failure, failure_size, "The reordered export has no timeline.");
        return 0;
    }

    mlt_playlist pending_canvas = mlt_playlist_new(graph->export_profile);
    mlt_tractor pending_tractor = NULL;
    mlt_transition pending_video[MLT_COMPOSITION_MAX_LAYERS] = {NULL, NULL, NULL};
    mlt_transition pending_mix[MLT_COMPOSITION_MAX_LAYERS] = {NULL, NULL, NULL};
    int succeeded = 0;

    if (pending_canvas == NULL ||
        mlt_playlist_blank(pending_canvas, (mlt_position)length - 1) != 0) {
        export_set_failure(failure, failure_size, "Could not create the reordered export canvas.");
        goto export_visual_cleanup;
    }

    pending_tractor = mlt_tractor_new();
    if (pending_tractor == NULL) {
        export_set_failure(failure, failure_size, "Could not create the reordered export tractor.");
        goto export_visual_cleanup;
    }
    mlt_service_set_profile(
        MLT_TRACTOR_SERVICE(pending_tractor),
        graph->export_profile
    );

    if (mlt_tractor_set_track(
            pending_tractor,
            mlt_playlist_producer(pending_canvas),
            0) != 0) {
        export_set_failure(failure, failure_size, "Could not connect the reordered export canvas.");
        goto export_visual_cleanup;
    }

    for (int visual = 0; visual < present_count; visual++) {
        const int logical = present_order[visual];
        mlt_producer producer = export_logical_layer_producer(graph, logical);
        if (producer == NULL ||
            mlt_tractor_set_track(pending_tractor, producer, visual + 1) != 0) {
            export_set_failure(failure, failure_size, "Could not connect a reordered export layer.");
            goto export_visual_cleanup;
        }
    }

    mlt_field field = mlt_tractor_field(pending_tractor);
    if (field == NULL) {
        export_set_failure(failure, failure_size, "The reordered export tractor has no MLT field.");
        goto export_visual_cleanup;
    }

    for (int visual = 0; visual < present_count; visual++) {
        const int logical = present_order[visual];
        const int physical = visual + 1;
        const MltCompositionLayerDerivedState *layer = &graph->derived.layers[logical];

        pending_video[logical] =
            mlt_factory_transition(graph->export_profile, "composite", NULL);
        if (pending_video[logical] == NULL ||
            !mlt_composition_configure_transition(
                pending_video[logical],
                layer->x,
                layer->y,
                layer->width,
                layer->height,
                layer->opacity) ||
            mlt_field_plant_transition(
                field,
                pending_video[logical],
                0,
                physical) != 0) {
            export_set_failure(failure, failure_size, "Could not plant a reordered export video composite.");
            goto export_visual_cleanup;
        }

        if (layer->has_audio) {
            pending_mix[logical] =
                mlt_factory_transition(graph->export_profile, "mix", NULL);
            if (pending_mix[logical] == NULL ||
                !export_configure_sum_mix(pending_mix[logical]) ||
                mlt_field_plant_transition(
                    field,
                    pending_mix[logical],
                    0,
                    physical) != 0) {
                export_set_failure(failure, failure_size, "Could not plant a reordered export audio mix.");
                goto export_visual_cleanup;
            }
        }
    }

    mlt_tractor_refresh(pending_tractor);
    mlt_producer pending_top = mlt_tractor_producer(pending_tractor);
    if (pending_top == NULL) {
        export_set_failure(failure, failure_size, "The reordered export tractor did not expose a producer.");
        goto export_visual_cleanup;
    }

    if (graph->export_tractor != NULL) {
        mlt_tractor_close(graph->export_tractor);
    }
    if (graph->export_visual_canvas != NULL) {
        mlt_playlist_close(graph->export_visual_canvas);
    }
    if (graph->export_primary_composite != NULL) {
        mlt_transition_close(graph->export_primary_composite);
    }
    if (graph->export_primary_mix != NULL) {
        mlt_transition_close(graph->export_primary_mix);
    }
    if (graph->export_composite != NULL) {
        mlt_transition_close(graph->export_composite);
    }
    if (graph->export_mix != NULL) {
        mlt_transition_close(graph->export_mix);
    }
    if (graph->export_tertiary_composite != NULL) {
        mlt_transition_close(graph->export_tertiary_composite);
    }
    if (graph->export_tertiary_mix != NULL) {
        mlt_transition_close(graph->export_tertiary_mix);
    }

    graph->export_tractor = pending_tractor;
    graph->export_visual_canvas = pending_canvas;
    graph->export_primary_composite = pending_video[0];
    graph->export_primary_mix = pending_mix[0];
    graph->export_composite = pending_video[1];
    graph->export_mix = pending_mix[1];
    graph->export_tertiary_composite = pending_video[2];
    graph->export_tertiary_mix = pending_mix[2];
    graph->export_top = pending_top;

    pending_tractor = NULL;
    pending_canvas = NULL;
    for (int logical = 0; logical < MLT_COMPOSITION_MAX_LAYERS; logical++) {
        pending_video[logical] = NULL;
        pending_mix[logical] = NULL;
    }
    succeeded = 1;

export_visual_cleanup:
    if (pending_tractor != NULL) {
        mlt_tractor_close(pending_tractor);
    }
    if (pending_canvas != NULL) {
        mlt_playlist_close(pending_canvas);
    }
    for (int logical = 0; logical < MLT_COMPOSITION_MAX_LAYERS; logical++) {
        if (pending_video[logical] != NULL) {
            mlt_transition_close(pending_video[logical]);
        }
        if (pending_mix[logical] != NULL) {
            mlt_transition_close(pending_mix[logical]);
        }
    }
    return succeeded;
}

/*
 * Build an export-only graph from a snapshot of the open movie. With one
 * layer this remains the original source-only path. With overlay layers it
 * recreates the preview tractor using fresh producers so the export worker
 * never shares live MLT objects with preview playback.
 */
static int export_prepare_source_graph(
    const ExportJob *job,
    ExportGraph *graph,
    int64_t *in_frame_out,
    int64_t *out_frame_out,
    char *failure,
    size_t failure_size)
{
    mlt_producer probe_producer = NULL;

    if (job == NULL || graph == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "The export graph request is invalid."
        );
        return 0;
    }

    memset(graph, 0, sizeof(*graph));
    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        graph->derived.visual_order[index] =
            job->export_snapshot_valid ? job->export_visual_order[index] : index;
        if (index >= MLT_COMPOSITION_FIRST_OVERLAY) {
            graph->derived.layers[index].start_frame = -1;
        }
    }

    graph->export_profile = mlt_profile_init(NULL);

    if (graph->export_profile == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "Could not create an MLT export profile."
        );
        goto fail;
    }

    probe_producer =
        mlt_factory_producer(
            graph->export_profile,
            NULL,
            job->export_source_path
        );

    if (probe_producer == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not open the base source for export."
        );
        goto fail;
    }

    mlt_producer_probe(probe_producer);
    mlt_profile_from_producer(graph->export_profile, probe_producer);

    graph->source_frame_rate_num = graph->export_profile->frame_rate_num;
    graph->source_frame_rate_den = graph->export_profile->frame_rate_den;
    graph->source_fps = mlt_profile_fps(graph->export_profile);

    if (graph->source_frame_rate_num <= 0 ||
        graph->source_frame_rate_den <= 0 ||
        graph->source_fps <= 0.0) {
        export_set_failure(
            failure,
            failure_size,
            "The base source has an invalid frame rate."
        );
        goto fail;
    }

    if (export_job_has_explicit_video_frame_rate(job)) {
        graph->export_profile->frame_rate_num =
            job->export_video_frame_rate_num;
        graph->export_profile->frame_rate_den =
            job->export_video_frame_rate_den;
    }

    graph->output_fps = mlt_profile_fps(graph->export_profile);

    mlt_producer_close(probe_producer);
    probe_producer = NULL;

    graph->export_primary =
        mlt_factory_producer(
            graph->export_profile,
            NULL,
            job->export_source_path
        );

    if (graph->export_primary == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not reopen the base source for export."
        );
        goto fail;
    }

    mlt_producer_probe(graph->export_primary);

    const int64_t source_length =
        (int64_t)mlt_producer_get_length(graph->export_primary);

    int64_t in_frame = job->export_in_frame;
    int64_t out_frame = job->export_out_frame;

    if (in_frame < 0) {
        in_frame = 0;
    }

    if (export_job_has_explicit_video_frame_rate(job)) {
        const int64_t source_out_boundary =
            out_frame < INT64_MAX ? out_frame + 1 : INT64_MAX;

        in_frame = export_scale_frame_boundary(
            in_frame,
            graph->source_frame_rate_num,
            graph->source_frame_rate_den,
            job->export_video_frame_rate_num,
            job->export_video_frame_rate_den
        );

        const int64_t target_out_boundary =
            export_scale_frame_boundary(
                source_out_boundary,
                graph->source_frame_rate_num,
                graph->source_frame_rate_den,
                job->export_video_frame_rate_num,
                job->export_video_frame_rate_den
            );

        out_frame =
            target_out_boundary > 0
                ? target_out_boundary - 1
                : 0;
    }

    if (out_frame >= source_length) {
        out_frame = source_length - 1;
    }

    if (source_length <= 0 || out_frame < in_frame) {
        export_set_failure(
            failure,
            failure_size,
            "The requested export range is invalid."
        );
        goto fail;
    }

    graph->derived.layer_count =
        job->export_has_tertiary ? 3 : (job->export_has_secondary ? 2 : 1);
    graph->derived.profile_width = graph->export_profile->width;
    graph->derived.profile_height = graph->export_profile->height;
    graph->derived.profile_fps = mlt_profile_fps(graph->export_profile);
    graph->derived.composition_length = source_length;
    graph->derived.range_in_frame = in_frame;
    graph->derived.range_out_frame = out_frame;

    MltCompositionLayerDerivedState *base =
        &graph->derived.layers[MLT_COMPOSITION_BASE_LAYER];
    base->present = 1;
    base->start_frame = 0;
    base->timeline_length = source_length;
    base->source_in_frame = 0;
    base->source_out_frame = source_length - 1;
    base->base_width = graph->derived.profile_width;
    base->base_height = graph->derived.profile_height;
    base->x = 0.0;
    base->y = 0.0;
    base->width = graph->derived.profile_width;
    base->height = graph->derived.profile_height;
    base->opacity = 1.0;
    base->has_audio = job->export_primary_has_audio ? 1 : 0;
    base->audio_gain = job->export_primary_audio_gain;

    MltCompositionLayerDerivedState *layer2 = NULL;
    if (job->export_has_secondary) {
        layer2 = &graph->derived.layers[MLT_COMPOSITION_FIRST_OVERLAY];
        layer2->present = 1;
        layer2->is_still = job->export_secondary_is_still ? 1 : 0;
        layer2->alpha_mode = job->export_secondary_alpha_mode;
        layer2->has_audio = job->export_secondary_has_audio ? 1 : 0;
        layer2->audio_gain = job->export_secondary_audio_gain;
    }

    if (job->export_snapshot_valid &&
        job->export_primary_has_audio &&
        !export_attach_audio_gain(
            graph->export_profile,
            graph->export_primary,
            job->export_primary_audio_gain)) {
        export_set_failure(
            failure,
            failure_size,
            "Could not apply Layer 1 audio level to export."
        );
        goto fail;
    }

    if (!job->export_has_secondary) {
        if (mlt_producer_set_in_and_out(
                graph->export_primary,
                (mlt_position)in_frame,
                (mlt_position)out_frame) != 0 ||
            mlt_producer_seek(graph->export_primary, 0) != 0 ||
            mlt_producer_set_speed(graph->export_primary, 1.0) != 0) {
            export_set_failure(
                failure,
                failure_size,
                "MLT could not initialize the export range."
            );
            goto fail;
        }

        graph->export_top = graph->export_primary;
        graph->derived.valid = 1;
        *in_frame_out = in_frame;
        *out_frame_out = out_frame;
        return 1;
    }

    if (job->export_secondary_path == NULL ||
        job->export_secondary_path[0] == '\0') {
        export_set_failure(
            failure,
            failure_size,
            "Layer 2 has no exportable source path."
        );
        goto fail;
    }

    if (job->export_secondary_is_still) {
        graph->export_secondary =
            mlt_factory_producer(
                graph->export_profile,
                "pixbuf",
                job->export_secondary_path
            );

        if (graph->export_secondary == NULL) {
            graph->export_secondary =
                mlt_factory_producer(
                    graph->export_profile,
                    "avformat",
                    job->export_secondary_path
                );
        }
    } else {
        graph->export_secondary =
            mlt_factory_producer(
                graph->export_profile,
                NULL,
                job->export_secondary_path
            );
    }

    if (graph->export_secondary == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not open Layer 2 for export."
        );
        goto fail;
    }

    if (job->export_secondary_is_still &&
        !export_attach_still_converter(
            graph->export_profile,
            graph->export_secondary)) {
        export_set_failure(
            failure,
            failure_size,
            "Could not install Layer 2 still-image conversion for export."
        );
        goto fail;
    }

    mlt_producer_probe(graph->export_secondary);

    mlt_position normalized_secondary_start = 0;
    mlt_position normalized_secondary_source_in = -1;
    mlt_position normalized_secondary_source_out = -1;
    int64_t secondary_start_frame = job->export_secondary_start_frame;
    int64_t secondary_end_frame = job->export_secondary_end_frame;
    int64_t secondary_source_in_frame = job->export_secondary_source_in_frame;
    int64_t secondary_source_out_frame = job->export_secondary_source_out_frame;

    if (export_job_has_explicit_video_frame_rate(job)) {
        secondary_start_frame = export_scale_frame_boundary(
            secondary_start_frame,
            graph->source_frame_rate_num,
            graph->source_frame_rate_den,
            job->export_video_frame_rate_num,
            job->export_video_frame_rate_den
        );

        if (secondary_end_frame >= 0) {
            const int64_t source_end_boundary =
                secondary_end_frame < INT64_MAX
                    ? secondary_end_frame + 1
                    : secondary_end_frame;
            const int64_t target_end_boundary =
                export_scale_frame_boundary(
                    source_end_boundary,
                    graph->source_frame_rate_num,
                    graph->source_frame_rate_den,
                    job->export_video_frame_rate_num,
                    job->export_video_frame_rate_den
                );
            secondary_end_frame =
                target_end_boundary > 0
                    ? target_end_boundary - 1
                    : 0;
        }

        if (secondary_source_in_frame >= 0) {
            secondary_source_in_frame = export_scale_frame_boundary(
                secondary_source_in_frame,
                graph->source_frame_rate_num,
                graph->source_frame_rate_den,
                job->export_video_frame_rate_num,
                job->export_video_frame_rate_den
            );
        }
        if (secondary_source_out_frame >= 0) {
            const int64_t source_trim_out_boundary =
                secondary_source_out_frame < INT64_MAX
                    ? secondary_source_out_frame + 1
                    : secondary_source_out_frame;
            const int64_t target_trim_out_boundary =
                export_scale_frame_boundary(
                    source_trim_out_boundary,
                    graph->source_frame_rate_num,
                    graph->source_frame_rate_den,
                    job->export_video_frame_rate_num,
                    job->export_video_frame_rate_den
                );
            secondary_source_out_frame =
                target_trim_out_boundary > 0
                    ? target_trim_out_boundary - 1
                    : 0;
        }
    }

    const MltSecondaryPlacementResult placement_result =
        mlt_composition_build_secondary_playlist_trimmed(
            graph->export_profile,
            graph->export_secondary,
            (mlt_position)secondary_start_frame,
            (mlt_position)secondary_end_frame,
            (mlt_position)secondary_source_in_frame,
            (mlt_position)secondary_source_out_frame,
            (mlt_position)source_length,
            job->export_secondary_is_still,
            &graph->export_secondary_playlist,
            &normalized_secondary_start,
            &normalized_secondary_source_in,
            &normalized_secondary_source_out
        );

    if (placement_result != MLT_SECONDARY_PLACEMENT_OK) {
        const char *placement_error =
            "Could not configure Layer 2 placement for export.";

        switch (placement_result) {
            case MLT_SECONDARY_PLACEMENT_NO_DURATION:
                placement_error =
                    "Layer 2 reports no usable duration for export.";
                break;

            case MLT_SECONDARY_PLACEMENT_NO_ROOM:
                placement_error =
                    "Layer 2 has no frames inside the base movie.";
                break;

            case MLT_SECONDARY_PLACEMENT_SOURCE_INIT_FAILED:
                placement_error =
                    "MLT could not initialize Layer 2 for export.";
                break;

            case MLT_SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED:
                placement_error =
                    "Could not create the Layer 2 export playlist.";
                break;

            case MLT_SECONDARY_PLACEMENT_LEAD_IN_FAILED:
                placement_error =
                    "Could not create the Layer 2 export lead-in.";
                break;

            case MLT_SECONDARY_PLACEMENT_APPEND_FAILED:
                placement_error =
                    "Could not place Layer 2 in the export composition.";
                break;

            case MLT_SECONDARY_PLACEMENT_INVALID_ARGUMENT:
            case MLT_SECONDARY_PLACEMENT_OK:
            default:
                break;
        }

        export_set_failure(
            failure,
            failure_size,
            placement_error
        );
        goto fail;
    }

    layer2->start_frame = (int64_t)normalized_secondary_start;
    layer2->source_in_frame =
        job->export_secondary_is_still ? -1 : (int64_t)normalized_secondary_source_in;
    layer2->source_out_frame =
        job->export_secondary_is_still ? -1 : (int64_t)normalized_secondary_source_out;
    layer2->timeline_length =
        (int64_t)mlt_producer_get_length(
            mlt_playlist_producer(graph->export_secondary_playlist)
        );

    if (job->export_secondary_has_audio &&
        !export_attach_audio_gain(
            graph->export_profile,
            mlt_playlist_producer(graph->export_secondary_playlist),
            job->export_secondary_audio_gain)) {
        export_set_failure(
            failure,
            failure_size,
            "Could not apply Layer 2 audio level to export."
        );
        goto fail;
    }

    if (!export_attach_alpha_interpretation(
            graph->export_secondary,
            job->export_secondary_alpha_mode)) {
        export_set_failure(
            failure,
            failure_size,
            "Could not apply Layer 2 alpha interpretation to export."
        );
        goto fail;
    }

    if (job->export_has_tertiary) {
        if (job->export_tertiary_path == NULL || job->export_tertiary_path[0] == '\0') {
            export_set_failure(failure, failure_size, "Layer 3 has no exportable source path.");
            goto fail;
        }

        if (job->export_tertiary_is_still) {
            graph->export_tertiary = mlt_factory_producer(
                graph->export_profile,
                "pixbuf",
                job->export_tertiary_path
            );
            if (graph->export_tertiary == NULL) {
                graph->export_tertiary = mlt_factory_producer(
                    graph->export_profile,
                    "avformat",
                    job->export_tertiary_path
                );
            }
        } else {
            graph->export_tertiary = mlt_factory_producer(
                graph->export_profile,
                NULL,
                job->export_tertiary_path
            );
        }

        if (graph->export_tertiary == NULL) {
            export_set_failure(failure, failure_size, "MLT could not open Layer 3 for export.");
            goto fail;
        }

        if (job->export_tertiary_is_still &&
            !export_attach_still_converter(graph->export_profile, graph->export_tertiary)) {
            export_set_failure(failure, failure_size, "Could not install Layer 3 still-image conversion for export.");
            goto fail;
        }

        mlt_producer_probe(graph->export_tertiary);
        mlt_position normalized_tertiary_start = 0;
        mlt_position normalized_tertiary_source_in = -1;
        mlt_position normalized_tertiary_source_out = -1;
        int64_t tertiary_start_frame = job->export_tertiary_start_frame;
        int64_t tertiary_end_frame = job->export_tertiary_end_frame;
        int64_t tertiary_source_in_frame = job->export_tertiary_source_in_frame;
        int64_t tertiary_source_out_frame = job->export_tertiary_source_out_frame;

        if (export_job_has_explicit_video_frame_rate(job)) {
            tertiary_start_frame = export_scale_frame_boundary(
                tertiary_start_frame,
                graph->source_frame_rate_num,
                graph->source_frame_rate_den,
                job->export_video_frame_rate_num,
                job->export_video_frame_rate_den
            );

            if (tertiary_end_frame >= 0) {
                const int64_t source_end_boundary =
                    tertiary_end_frame < INT64_MAX
                        ? tertiary_end_frame + 1
                        : tertiary_end_frame;
                const int64_t target_end_boundary =
                    export_scale_frame_boundary(
                        source_end_boundary,
                        graph->source_frame_rate_num,
                        graph->source_frame_rate_den,
                        job->export_video_frame_rate_num,
                        job->export_video_frame_rate_den
                    );
                tertiary_end_frame =
                    target_end_boundary > 0
                        ? target_end_boundary - 1
                        : 0;
            }

            if (tertiary_source_in_frame >= 0) {
                tertiary_source_in_frame = export_scale_frame_boundary(
                    tertiary_source_in_frame,
                    graph->source_frame_rate_num,
                    graph->source_frame_rate_den,
                    job->export_video_frame_rate_num,
                    job->export_video_frame_rate_den
                );
            }
            if (tertiary_source_out_frame >= 0) {
                const int64_t source_trim_out_boundary =
                    tertiary_source_out_frame < INT64_MAX
                        ? tertiary_source_out_frame + 1
                        : tertiary_source_out_frame;
                const int64_t target_trim_out_boundary =
                    export_scale_frame_boundary(
                        source_trim_out_boundary,
                        graph->source_frame_rate_num,
                        graph->source_frame_rate_den,
                        job->export_video_frame_rate_num,
                        job->export_video_frame_rate_den
                    );
                tertiary_source_out_frame =
                    target_trim_out_boundary > 0
                        ? target_trim_out_boundary - 1
                        : 0;
            }
        }

        const MltSecondaryPlacementResult tertiary_placement =
            mlt_composition_build_secondary_playlist_trimmed(
                graph->export_profile,
                graph->export_tertiary,
                (mlt_position)tertiary_start_frame,
                (mlt_position)tertiary_end_frame,
                (mlt_position)tertiary_source_in_frame,
                (mlt_position)tertiary_source_out_frame,
                (mlt_position)source_length,
                job->export_tertiary_is_still,
                &graph->export_tertiary_playlist,
                &normalized_tertiary_start,
                &normalized_tertiary_source_in,
                &normalized_tertiary_source_out
            );
        if (tertiary_placement != MLT_SECONDARY_PLACEMENT_OK) {
            export_set_failure(failure, failure_size, "Could not configure Layer 3 placement for export.");
            goto fail;
        }

        if (job->export_tertiary_has_audio &&
            !export_attach_audio_gain(
                graph->export_profile,
                mlt_playlist_producer(graph->export_tertiary_playlist),
                job->export_tertiary_audio_gain)) {
            export_set_failure(failure, failure_size, "Could not apply Layer 3 audio level to export.");
            goto fail;
        }

        if (!export_attach_alpha_interpretation(
                graph->export_tertiary,
                job->export_tertiary_alpha_mode)) {
            export_set_failure(failure, failure_size, "Could not apply Layer 3 alpha interpretation to export.");
            goto fail;
        }

        MltCompositionLayerDerivedState *layer3 =
            &graph->derived.layers[MLT_COMPOSITION_SECOND_OVERLAY];
        layer3->present = 1;
        layer3->start_frame = (int64_t)normalized_tertiary_start;
        layer3->source_in_frame =
            job->export_tertiary_is_still ? -1 : (int64_t)normalized_tertiary_source_in;
        layer3->source_out_frame =
            job->export_tertiary_is_still ? -1 : (int64_t)normalized_tertiary_source_out;
        layer3->timeline_length = (int64_t)mlt_producer_get_length(
            mlt_playlist_producer(graph->export_tertiary_playlist)
        );
        layer3->is_still = job->export_tertiary_is_still ? 1 : 0;
        layer3->alpha_mode = job->export_tertiary_alpha_mode;
        layer3->has_audio = job->export_tertiary_has_audio ? 1 : 0;
        layer3->audio_gain = job->export_tertiary_audio_gain;
    }

    graph->export_tractor = mlt_tractor_new();

    if (graph->export_tractor == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "Could not create the export tractor."
        );
        goto fail;
    }

    mlt_service_set_profile(
        MLT_TRACTOR_SERVICE(graph->export_tractor),
        graph->export_profile
    );

    if (mlt_tractor_set_track(
            graph->export_tractor,
            graph->export_primary,
            0) != 0 ||
        mlt_tractor_set_track(
            graph->export_tractor,
            mlt_playlist_producer(graph->export_secondary_playlist),
            1) != 0 ||
        (job->export_has_tertiary &&
         mlt_tractor_set_track(
             graph->export_tractor,
             mlt_playlist_producer(graph->export_tertiary_playlist),
             2) != 0)) {
        export_set_failure(
            failure,
            failure_size,
            "Could not connect the composition layers to the export tractor."
        );
        goto fail;
    }

    mlt_field field = mlt_tractor_field(graph->export_tractor);

    if (field == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "The export tractor did not provide an MLT field."
        );
        goto fail;
    }

    graph->export_composite =
        mlt_factory_transition(
            graph->export_profile,
            "composite",
            NULL
        );

    if (graph->export_composite == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "MLT's composite transition is unavailable for export."
        );
        goto fail;
    }

    double base_width = 0.0;
    double base_height = 0.0;

    if (!mlt_composition_secondary_base_size(
            graph->export_profile,
            graph->export_secondary,
            job->export_secondary_is_still,
            &base_width,
            &base_height)) {
        export_set_failure(
            failure,
            failure_size,
            "Layer 2 has invalid export geometry."
        );
        goto fail;
    }

    layer2->base_width = base_width;
    layer2->base_height = base_height;

    const double scale =
        isfinite(job->export_secondary_scale)
            ? CLAMP(job->export_secondary_scale, 0.10, 3.0)
            : 1.0;
    const double x =
        isfinite(job->export_secondary_x) ? job->export_secondary_x : 0.0;
    const double y =
        isfinite(job->export_secondary_y) ? job->export_secondary_y : 0.0;
    const double opacity =
        isfinite(job->export_secondary_opacity)
            ? CLAMP(job->export_secondary_opacity, 0.0, 1.0)
            : 1.0;

    if (!mlt_composition_configure_transition(
            graph->export_composite,
            x,
            y,
            base_width * scale,
            base_height * scale,
            opacity) ||
        !mlt_composition_get_geometry(
            graph->export_composite,
            &layer2->x,
            &layer2->y,
            &layer2->width,
            &layer2->height,
            &layer2->opacity)) {
        export_set_failure(
            failure,
            failure_size,
            "Could not configure the export video composite."
        );
        goto fail;
    }

    if (mlt_field_plant_transition(
            field,
            graph->export_composite,
            0,
            1) != 0) {
        export_set_failure(
            failure,
            failure_size,
            "Could not plant the export video composite."
        );
        goto fail;
    }

    if (job->export_secondary_has_audio) {
        graph->export_mix =
            mlt_factory_transition(
                graph->export_profile,
                "mix",
                NULL
            );

        if (graph->export_mix == NULL) {
            export_set_failure(
                failure,
                failure_size,
                "MLT's audio mix transition is unavailable for export."
            );
            goto fail;
        }

        mlt_properties mix_properties =
            MLT_TRANSITION_PROPERTIES(graph->export_mix);

        mlt_properties_set_int(mix_properties, "always_active", 1);
        mlt_properties_set_double(mix_properties, "start", 1.0);
        mlt_properties_set_double(mix_properties, "end", 1.0);
        mlt_properties_set_int(mix_properties, "sum", 1);

        if (mlt_field_plant_transition(
                field,
                graph->export_mix,
                0,
                1) != 0) {
            export_set_failure(
                failure,
                failure_size,
                "Could not plant the export audio mix."
            );
            goto fail;
        }
    }

    if (job->export_has_tertiary) {
        double tertiary_base_width = 0.0;
        double tertiary_base_height = 0.0;

        if (!mlt_composition_secondary_base_size(
                graph->export_profile,
                graph->export_tertiary,
                job->export_tertiary_is_still,
                &tertiary_base_width,
                &tertiary_base_height)) {
            export_set_failure(failure, failure_size, "Layer 3 has invalid export geometry.");
            goto fail;
        }

        graph->export_tertiary_composite =
            mlt_factory_transition(graph->export_profile, "composite", NULL);
        if (graph->export_tertiary_composite == NULL) {
            export_set_failure(failure, failure_size, "MLT's Layer 3 composite transition is unavailable for export.");
            goto fail;
        }

        const double tertiary_scale =
            isfinite(job->export_tertiary_scale)
                ? CLAMP(job->export_tertiary_scale, 0.10, 3.0)
                : 1.0;
        const double tertiary_x =
            isfinite(job->export_tertiary_x) ? job->export_tertiary_x : 0.0;
        const double tertiary_y =
            isfinite(job->export_tertiary_y) ? job->export_tertiary_y : 0.0;
        const double tertiary_opacity =
            isfinite(job->export_tertiary_opacity)
                ? CLAMP(job->export_tertiary_opacity, 0.0, 1.0)
                : 1.0;

        MltCompositionLayerDerivedState *layer3 =
            &graph->derived.layers[MLT_COMPOSITION_SECOND_OVERLAY];
        layer3->base_width = tertiary_base_width;
        layer3->base_height = tertiary_base_height;

        if (!mlt_composition_configure_transition(
                graph->export_tertiary_composite,
                tertiary_x,
                tertiary_y,
                tertiary_base_width * tertiary_scale,
                tertiary_base_height * tertiary_scale,
                tertiary_opacity) ||
            !mlt_composition_get_geometry(
                graph->export_tertiary_composite,
                &layer3->x,
                &layer3->y,
                &layer3->width,
                &layer3->height,
                &layer3->opacity)) {
            export_set_failure(failure, failure_size, "Could not configure the Layer 3 export video composite.");
            goto fail;
        }

        if (mlt_field_plant_transition(
                field,
                graph->export_tertiary_composite,
                0,
                2) != 0) {
            export_set_failure(failure, failure_size, "Could not plant the Layer 3 export video composite.");
            goto fail;
        }

        if (job->export_tertiary_has_audio) {
            graph->export_tertiary_mix =
                mlt_factory_transition(graph->export_profile, "mix", NULL);
            if (graph->export_tertiary_mix == NULL) {
                export_set_failure(
                    failure,
                    failure_size,
                    "MLT's Layer 3 audio mix transition is unavailable for export."
                );
                goto fail;
            }
            mlt_properties mix_properties =
                MLT_TRANSITION_PROPERTIES(graph->export_tertiary_mix);
            mlt_properties_set_int(mix_properties, "always_active", 1);
            mlt_properties_set_double(mix_properties, "start", 1.0);
            mlt_properties_set_double(mix_properties, "end", 1.0);
            mlt_properties_set_int(mix_properties, "sum", 1);
            if (mlt_field_plant_transition(
                    field,
                    graph->export_tertiary_mix,
                    0,
                    2) != 0) {
                export_set_failure(failure, failure_size, "Could not plant the Layer 3 export audio mix.");
                goto fail;
            }
        }
    }

    mlt_tractor_refresh(graph->export_tractor);
    graph->export_top = mlt_tractor_producer(graph->export_tractor);

    if (graph->export_top == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "The export tractor did not expose a producer."
        );
        goto fail;
    }

    if (!export_rebuild_visual_order(job, graph, failure, failure_size)) {
        goto fail;
    }

    mlt_producer_set_in_and_out(
        graph->export_top,
        0,
        (mlt_position)source_length - 1
    );

    if (mlt_producer_set_in_and_out(
            graph->export_top,
            (mlt_position)in_frame,
            (mlt_position)out_frame) != 0 ||
        mlt_producer_seek(graph->export_top, 0) != 0 ||
        mlt_producer_set_speed(graph->export_top, 1.0) != 0) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not initialize the composite export range."
        );
        goto fail;
    }

    graph->derived.valid = 1;
    *in_frame_out = in_frame;
    *out_frame_out = out_frame;
    return 1;

fail:
    if (probe_producer != NULL) {
        mlt_producer_close(probe_producer);
    }

    export_graph_close(graph);
    return 0;
}

/*
 * Most exports consume the source profile directly. PNG image exports differ:
 * it needs square pixels at display geometry so anamorphic storage dimensions
 * are not written as a squeezed image. The cloned profile belongs to the
 * caller; source_profile always remains owned by the source graph.
 */
static int export_prepare_consumer_profile(
    MltExportKind kind,
    mlt_profile source_profile,
    mlt_profile *owned_profile_out,
    mlt_profile *consumer_profile_out,
    char *failure,
    size_t failure_size)
{
    *owned_profile_out = NULL;
    *consumer_profile_out = source_profile;

    if (kind == MLT_EXPORT_KIND_MP4 ||
        kind == MLT_EXPORT_KIND_WAV_AUDIO) {
        return 1;
    }

    if (kind != MLT_EXPORT_KIND_PNG_FRAME &&
        kind != MLT_EXPORT_KIND_PNG_SEQUENCE) {
        export_set_failure(
            failure,
            failure_size,
            "The requested export type is unsupported."
        );
        return 0;
    }

    mlt_profile image_profile =
        mlt_profile_clone(source_profile);

    if (image_profile == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "Could not create the PNG export profile."
        );
        return 0;
    }

    const double display_aspect =
        mlt_profile_dar(source_profile);

    if (image_profile->height <= 0 ||
        display_aspect <= 0.0) {
        mlt_profile_close(image_profile);

        export_set_failure(
            failure,
            failure_size,
            "The source has invalid display geometry."
        );
        return 0;
    }

    const int display_width =
        (int)(
            ((double)image_profile->height * display_aspect) +
            0.5
        );

    if (display_width <= 0) {
        mlt_profile_close(image_profile);

        export_set_failure(
            failure,
            failure_size,
            "The source has invalid display geometry."
        );
        return 0;
    }

    image_profile->width = display_width;
    image_profile->sample_aspect_num = 1;
    image_profile->sample_aspect_den = 1;
    image_profile->display_aspect_num = display_width;
    image_profile->display_aspect_den = image_profile->height;
    image_profile->progressive = 1;

    *owned_profile_out = image_profile;
    *consumer_profile_out = image_profile;

    return 1;
}

static int export_source_has_audio(
    mlt_producer source_producer)
{
    if (source_producer == NULL) {
        return 0;
    }

    mlt_properties properties =
        MLT_PRODUCER_PROPERTIES(source_producer);

    if (properties == NULL) {
        return 0;
    }

    const char *audio_index_value =
        mlt_properties_get(
            properties,
            "audio_index"
        );

    if (audio_index_value != NULL) {
        return mlt_properties_get_int(
            properties,
            "audio_index"
        ) >= 0;
    }

    /*
     * Some producer types do not publish audio_index. If stream metadata is
     * available, scan it before falling back to the historic "audio may be
     * present" behavior.
     */
    if (mlt_properties_get(
            properties,
            "meta.media.nb_streams") != NULL) {
        const int stream_total =
            mlt_properties_get_int(
                properties,
                "meta.media.nb_streams"
            );

        for (int index = 0;
             index < stream_total;
             index++) {
            char key[128];

            snprintf(
                key,
                sizeof(key),
                "meta.media.%d.stream.type",
                index
            );

            const char *type =
                mlt_properties_get(
                    properties,
                    key
                );

            if (type != NULL &&
                strcmp(type, "audio") == 0) {
                return 1;
            }
        }

        return 0;
    }

    return 1;
}

static void export_configure_video_consumer(
    mlt_properties properties,
    int composition_has_audio,
    int video_preset)
{
    if (video_preset == EXPORT_VIDEO_PRESET_PRORES_422_HQ) {
        /*
         * Purpose-named edit/master preset: QuickTime MOV carrying ProRes 422
         * HQ at 10-bit 4:2:2. PCM audio avoids a second lossy encode in the
         * master. Frame rate remains the composition profile's frame rate.
         */
        mlt_properties_set(properties, "f", "mov");
        mlt_properties_set(properties, "vcodec", "prores_ks");
        mlt_properties_set(properties, "pix_fmt", "yuv422p10le");
        mlt_properties_set(properties, "vprofile", "hq");

        if (composition_has_audio) {
            mlt_properties_set(properties, "acodec", "pcm_s24le");
            mlt_properties_set(properties, "mlt_audio_format", "s32le");
        } else {
            mlt_properties_set_int(properties, "an", 1);
        }
    } else {
        /*
         * H.264 Delivery is the original POC 9 movie preset. Keep its exact
         * behavior as the default so existing exports remain unchanged.
         */
        mlt_properties_set(properties, "f", "mp4");
        mlt_properties_set(properties, "vcodec", "libx264");
        mlt_properties_set(properties, "pix_fmt", "yuv420p");
        mlt_properties_set(properties, "preset", "medium");
        mlt_properties_set_int(properties, "crf", 18);
        mlt_properties_set(properties, "movflags", "+faststart");

        if (composition_has_audio) {
            mlt_properties_set(properties, "acodec", "aac");
        } else {
            mlt_properties_set_int(properties, "an", 1);
        }
    }

    /* Both movie presets follow the viewer's progressive output policy. */
    mlt_properties_set(
        properties,
        "deinterlacer",
        MLT_EXPORT_DEINTERLACER
    );
    mlt_properties_set_int(properties, "top_field_first", -1);
    mlt_properties_set_int(properties, "progressive", 1);
}

static void export_configure_wav_audio_consumer(
    mlt_properties properties,
    mlt_producer source_producer)
{
    /*
     * POC 9.4 uses one dependable professional interchange preset:
     * uncompressed 24-bit PCM in a WAV container. MLT renders 32-bit integer
     * samples internally because it has no 24-bit render-buffer format;
     * FFmpeg's pcm_s24le encoder writes the final 24-bit samples.
     */
    mlt_properties_set(properties, "f", "wav");
    mlt_properties_set(properties, "acodec", "pcm_s24le");
    mlt_properties_set(properties, "mlt_audio_format", "s32le");
    mlt_properties_set_int(properties, "vn", 1);

    /*
     * Preserve the selected source stream's sample rate and channel count
     * when avformat exposes them. Otherwise leave MLT's consumer defaults
     * alone rather than inventing metadata.
     */
    if (source_producer != NULL) {
        mlt_properties source_properties =
            MLT_PRODUCER_PROPERTIES(source_producer);

        const char *audio_index_value =
            mlt_properties_get(
                source_properties,
                "audio_index"
            );

        if (audio_index_value != NULL) {
            const int audio_index =
                mlt_properties_get_int(
                    source_properties,
                    "audio_index"
                );

            if (audio_index >= 0) {
                char key[128];

                snprintf(
                    key,
                    sizeof(key),
                    "meta.media.%d.codec.sample_rate",
                    audio_index
                );

                if (mlt_properties_get(source_properties, key) != NULL) {
                    const int sample_rate =
                        mlt_properties_get_int(
                            source_properties,
                            key
                        );

                    if (sample_rate > 0) {
                        mlt_properties_set_int(
                            properties,
                            "frequency",
                            sample_rate
                        );
                    }
                }

                snprintf(
                    key,
                    sizeof(key),
                    "meta.media.%d.codec.channels",
                    audio_index
                );

                if (mlt_properties_get(source_properties, key) != NULL) {
                    const int channels =
                        mlt_properties_get_int(
                            source_properties,
                            key
                        );

                    if (channels > 0) {
                        mlt_properties_set_int(
                            properties,
                            "channels",
                            channels
                        );
                    }
                }
            }
        }
    }
}

static void export_configure_png_common(
    mlt_properties properties)
{
    /*
     * PNG exports are rendered from the source graph, not copied from
     * Flutter's display texture. Their consumer profile converts anamorphic
     * storage pixels to display-correct square pixels. RGBA preserves
     * source alpha when the decoder provides it.
     */
    mlt_properties_set(properties, "f", "image2");
    mlt_properties_set(properties, "vcodec", "png");
    mlt_properties_set(properties, "pix_fmt", "rgba");
    mlt_properties_set_int(properties, "an", 1);
    mlt_properties_set(properties, "mlt_image_format", "rgba");

    /* Match the progressive frame the viewer presents. */
    mlt_properties_set(properties, "rescale", "lanczos");
    mlt_properties_set(properties, "deinterlacer", MLT_EXPORT_DEINTERLACER);
    mlt_properties_set_int(properties, "top_field_first", -1);
    mlt_properties_set_int(properties, "progressive", 1);
}

static void export_configure_png_frame_consumer(
    mlt_properties properties)
{
    export_configure_png_common(properties);

    /*
     * A frame export is one literal file, never an image2 filename pattern.
     */
    mlt_properties_set_int(properties, "update", 1);
}

static void export_configure_png_sequence_consumer(
    mlt_properties properties)
{
    export_configure_png_common(properties);

    /*
     * Image2 expands frame_%06d.png into a one-based sequence. Keep update
     * disabled so every source frame becomes a separate PNG.
     */
    mlt_properties_set_int(properties, "update", 0);
    mlt_properties_set_int(properties, "start_number", 1);
}

static int export_render_thread_count(void)
{
    guint processors = g_get_num_processors();

    if (processors < 1) {
        processors = 1;
    }

    /*
     * MLT uses abs(real_time) as its frame-processing worker count. The old
     * exporter hard-coded -1, which disabled frame dropping correctly but
     * also serialized frame preparation through one worker. Four workers is
     * a conservative cap: it lets layered decode/composite work overlap while
     * leaving CPU headroom for libx264's own internal worker threads.
     */
    if (processors > 4) {
        processors = 4;
    }

    return (int)processors;
}

static int export_configure_consumer(
    const ExportJob *job,
    mlt_properties properties,
    mlt_producer source_producer,
    char *failure,
    size_t failure_size)
{
    const MltExportKind kind = job->export_kind;
    const int composition_has_audio =
        job->export_snapshot_valid
            ? (job->export_primary_has_audio || job->export_secondary_has_audio || job->export_tertiary_has_audio)
            : export_source_has_audio(source_producer);

    switch (kind) {
        case MLT_EXPORT_KIND_MP4:
            export_configure_video_consumer(
                properties,
                composition_has_audio,
                job->export_video_preset
            );
            break;

        case MLT_EXPORT_KIND_PNG_FRAME:
            export_configure_png_frame_consumer(properties);
            break;

        case MLT_EXPORT_KIND_PNG_SEQUENCE:
            export_configure_png_sequence_consumer(properties);
            break;

        case MLT_EXPORT_KIND_WAV_AUDIO:
            export_configure_wav_audio_consumer(
                properties,
                source_producer
            );
            break;

        default:
            export_set_failure(
                failure,
                failure_size,
                "The requested export type is unsupported."
            );
            return 0;
    }

    /*
     * Negative real_time disables frame dropping. Its magnitude is also MLT's
     * frame-processing worker count, so do not accidentally serialize export
     * through one render worker.
     */
    const int render_threads = export_render_thread_count();
    mlt_properties_set_int(
        properties,
        "real_time",
        -render_threads
    );
    mlt_properties_set_int(properties, "terminate_on_pause", 1);

    return 1;
}

static int export_sequence_outputs_complete(
    const char *directory,
    int64_t expected_frames)
{
    if (directory == NULL ||
        directory[0] == '\0' ||
        expected_frames <= 0) {
        return 0;
    }

    GDir *dir =
        g_dir_open(directory, 0, NULL);

    if (dir == NULL) {
        return 0;
    }

    int64_t owned_count = 0;
    int64_t minimum_frame = G_MAXINT64;
    int64_t maximum_frame = 0;
    int all_have_data = 1;

    const char *name = NULL;

    while ((name = g_dir_read_name(dir)) != NULL) {
        const int64_t frame_number =
            export_sequence_frame_number(name);

        if (frame_number <= 0) {
            continue;
        }

        owned_count += 1;

        if (frame_number < minimum_frame) {
            minimum_frame = frame_number;
        }

        if (frame_number > maximum_frame) {
            maximum_frame = frame_number;
        }

        char *path =
            g_build_filename(
                directory,
                name,
                NULL
            );

        if (path == NULL ||
            !output_file_has_data(path)) {
            all_have_data = 0;
        }

        g_free(path);
    }

    g_dir_close(dir);

    /*
     * Filenames are unique directory entries. If N owned files exist and
     * their minimum and maximum indices are 1 and N, there can be no gap.
     */
    return all_have_data &&
           owned_count == expected_frames &&
           minimum_frame == 1 &&
           maximum_frame == expected_frames;
}

static int export_output_completed(
    const ExportJob *job,
    mlt_producer source_producer,
    int64_t total_frames,
    char *failure,
    size_t failure_size)
{
    switch (job->export_kind) {
        case MLT_EXPORT_KIND_PNG_FRAME:
            /*
             * A one-frame producer has no meaningful terminal-position check:
             * frame zero is both its start and end. The output file itself is
             * the useful completion signal for this export kind.
             */
            if (output_file_has_data(job->export_output_path)) {
                return 1;
            }

            export_set_failure(
                failure,
                failure_size,
                "MLT did not write the requested PNG frame."
            );
            return 0;

        case MLT_EXPORT_KIND_PNG_SEQUENCE: {
            const int64_t final_position =
                (int64_t)mlt_producer_position(source_producer);

            if (final_position >= total_frames - 1 &&
                export_sequence_outputs_complete(
                    job->export_output_path,
                    total_frames)) {
                return 1;
            }

            export_set_failure(
                failure,
                failure_size,
                "MLT image-sequence export stopped before every frame completed."
            );
            return 0;
        }

        case MLT_EXPORT_KIND_WAV_AUDIO:
        case MLT_EXPORT_KIND_MP4: {
            const int64_t final_position =
                (int64_t)mlt_producer_position(source_producer);

            if (final_position >= total_frames - 1 &&
                output_file_has_data(job->export_output_path)) {
                return 1;
            }

            export_set_failure(
                failure,
                failure_size,
                "MLT export stopped before the requested range completed."
            );
            return 0;
        }

        default:
            export_set_failure(
                failure,
                failure_size,
                "The requested export type is unsupported."
            );
            return 0;
    }
}

static gpointer export_worker(gpointer data)
{
    ExportJob *job = (ExportJob *)data;

    ExportGraph graph;
    memset(&graph, 0, sizeof(graph));

    mlt_profile owned_consumer_profile = NULL;
    mlt_profile consumer_profile = NULL;
    mlt_consumer export_consumer = NULL;

    char *owned_consumer_target = NULL;
    const char *consumer_target = NULL;

    int64_t in_frame = 0;
    int64_t out_frame = -1;

    int succeeded = 0;
    int cancelled = 0;
    int destination_prepared = 0;
    char failure[512] = "";

    ExportTelemetry telemetry;
    memset(&telemetry, 0, sizeof(telemetry));
    telemetry.worker_started_us = g_get_monotonic_time();
    telemetry.worker_started_cpu_seconds =
        export_process_cpu_seconds(NULL);
    telemetry.current_position = -1;

    if (!export_prepare_source_graph(
            job,
            &graph,
            &in_frame,
            &out_frame,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    telemetry.graph_ready_us = g_get_monotonic_time();

    mlt_producer export_producer = graph.export_top;
    mlt_profile export_profile = graph.export_profile;

    if (export_profile != NULL) {
        telemetry.output_width = export_profile->width;
        telemetry.output_height = export_profile->height;
        telemetry.source_fps = graph.source_fps;
        telemetry.output_fps = graph.output_fps;
    }

    if (!export_prepare_consumer_profile(
            job->export_kind,
            export_profile,
            &owned_consumer_profile,
            &consumer_profile,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    if (job->export_kind == MLT_EXPORT_KIND_PNG_SEQUENCE) {
        owned_consumer_target =
            export_sequence_consumer_target(
                job->export_output_path
            );

        if (owned_consumer_target == NULL) {
            export_set_failure(
                failure,
                sizeof(failure),
                "Could not build the image-sequence filename pattern."
            );
            goto cleanup;
        }

        consumer_target = owned_consumer_target;
    } else {
        consumer_target = job->export_output_path;
    }

    export_consumer =
        mlt_factory_consumer(
            consumer_profile,
            "avformat",
            consumer_target
        );

    if (export_consumer == NULL) {
        export_set_failure(
            failure,
            sizeof(failure),
            "MLT avformat export consumer is unavailable."
        );
        goto cleanup;
    }

    mlt_properties properties =
        MLT_CONSUMER_PROPERTIES(export_consumer);

    mlt_producer metadata_source = graph.export_primary;
    if (job->export_snapshot_valid &&
        !job->export_primary_has_audio) {
        if (job->export_secondary_has_audio && graph.export_secondary != NULL) {
            metadata_source = graph.export_secondary;
        } else if (job->export_tertiary_has_audio && graph.export_tertiary != NULL) {
            metadata_source = graph.export_tertiary;
        }
    }

    if (!export_configure_consumer(
            job,
            properties,
            metadata_source,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    if (mlt_consumer_connect(
            export_consumer,
            MLT_PRODUCER_SERVICE(export_producer)) != 0) {
        export_set_failure(
            failure,
            sizeof(failure),
            "MLT could not connect the export consumer."
        );
        goto cleanup;
    }

    telemetry.consumer_real_time =
        mlt_properties_get_int(properties, "real_time");
    telemetry.consumer_buffer =
        mlt_properties_get_int(properties, "buffer");
    telemetry.consumer_prefill =
        mlt_properties_get_int(properties, "prefill");
    telemetry.consumer_ready_us = g_get_monotonic_time();

    if (!export_prepare_destination(
            job,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    destination_prepared = 1;

    const int64_t total_frames =
        out_frame - in_frame + 1;
    telemetry.total_frames = total_frames;

    telemetry.encode_started_us = g_get_monotonic_time();
    telemetry.encode_started_cpu_seconds =
        export_process_cpu_seconds(NULL);
    telemetry.last_report_us = telemetry.encode_started_us;

    if (mlt_consumer_start(export_consumer) != 0) {
        export_set_failure(
            failure,
            sizeof(failure),
            "MLT could not start the export encoder."
        );
        goto cleanup;
    }

    export_update_frame_telemetry(
        &telemetry,
        export_producer
    );
    export_write_report(
        job,
        &telemetry,
        "running",
        NULL,
        telemetry.encode_started_us
    );

    while (!mlt_consumer_is_stopped(export_consumer)) {
        if (export_cancel_was_requested()) {
            cancelled = 1;
            mlt_consumer_stop(export_consumer);
            break;
        }

        const int64_t position =
            (int64_t)mlt_producer_position(export_producer);

        const double progress =
            total_frames > 0
                ? ((double)(position + 1) / (double)total_frames)
                : 0.0;

        export_publish_progress(progress);

        export_update_frame_telemetry(
            &telemetry,
            export_producer
        );

        const gint64 now_us = g_get_monotonic_time();

        if (now_us - telemetry.last_report_us >= 1000000) {
            export_write_report(
                job,
                &telemetry,
                "running",
                NULL,
                now_us
            );
            telemetry.last_report_us = now_us;
        }

        g_usleep(50000);
    }

    telemetry.encode_finished_us = g_get_monotonic_time();
    telemetry.encode_finished_cpu_seconds =
        export_process_cpu_seconds(NULL);
    export_update_frame_telemetry(
        &telemetry,
        export_producer
    );

    /*
     * Even if the consumer stopped itself at EOF, stop() joins its worker
     * threads and flushes the muxer trailer.
     */
    mlt_consumer_stop(export_consumer);
    telemetry.flush_finished_us = g_get_monotonic_time();
    export_update_frame_telemetry(
        &telemetry,
        export_producer
    );

    if (export_cancel_was_requested()) {
        cancelled = 1;
    }

    if (!cancelled &&
        export_output_completed(
            job,
            export_producer,
            total_frames,
            failure,
            sizeof(failure))) {
        succeeded = 1;
        export_publish_progress(1.0);
    }

cleanup:
    if (export_consumer != NULL) {
        if (!mlt_consumer_is_stopped(export_consumer)) {
            mlt_consumer_stop(export_consumer);
        }
        mlt_consumer_close(export_consumer);
        export_consumer = NULL;
    }

    if (owned_consumer_profile != NULL) {
        mlt_profile_close(owned_consumer_profile);
        owned_consumer_profile = NULL;
    }

    export_graph_close(&graph);

    g_free(owned_consumer_target);
    owned_consumer_target = NULL;

    if (!succeeded &&
        destination_prepared) {
        export_remove_partial_output(job);
    }

    const gint64 report_now_us = g_get_monotonic_time();

    if (telemetry.encode_finished_us == 0 &&
        telemetry.encode_started_us > 0) {
        telemetry.encode_finished_us = report_now_us;
        telemetry.encode_finished_cpu_seconds =
            export_process_cpu_seconds(NULL);
    }

    if (telemetry.flush_finished_us == 0 &&
        telemetry.encode_finished_us > 0) {
        telemetry.flush_finished_us = report_now_us;
    }

    const char *report_status =
        cancelled
            ? "cancelled"
            : (succeeded ? "success" : "failed");
    const char *report_error =
        cancelled
            ? "Export cancelled."
            : (succeeded
                ? NULL
                : (failure[0] != '\0'
                    ? failure
                    : "Export failed."));

    if (!export_write_report(
            job,
            &telemetry,
            report_status,
            report_error,
            report_now_us)) {
        fprintf(
            stderr,
            "mlt_export: warning: could not write export report for %s\n",
            job->export_output_path != NULL
                ? job->export_output_path
                : "(unknown output)"
        );
    }

    ensure_export_lock();

    g_mutex_lock(&export_mutex);

    export_running = 0;
    export_success = succeeded;

    if (cancelled) {
        export_set_error_locked("Export cancelled.");
    } else if (succeeded) {
        export_set_error_locked(NULL);
    } else if (failure[0] != '\0') {
        export_set_error_locked(failure);
    } else {
        export_set_error_locked("Export failed.");
    }

    g_mutex_unlock(&export_mutex);

    export_job_free(job);

    return NULL;
}

/*
 * Join a completed export worker so its GThread handle never leaks. This is
 * intentionally never called while export_mutex is held.
 */
static void join_finished_export_thread(void)
{
    ensure_export_lock();

    GThread *thread = NULL;

    g_mutex_lock(&export_mutex);

    if (!export_running &&
        export_thread != NULL) {
        thread = export_thread;
        export_thread = NULL;
    }

    g_mutex_unlock(&export_mutex);

    if (thread != NULL) {
        g_thread_join(thread);
    }
}

MLT_EXPORT_API
int mlt_bridge_export_set_video_preset(int preset)
{
    if (preset != EXPORT_VIDEO_PRESET_H264_DELIVERY &&
        preset != EXPORT_VIDEO_PRESET_PRORES_422_HQ) {
        return 0;
    }

    /* A completed worker may still have a joinable GThread handle. */
    join_finished_export_thread();

    ensure_export_lock();
    g_mutex_lock(&export_mutex);

    if (export_running) {
        g_mutex_unlock(&export_mutex);
        return 0;
    }

    export_video_preset = preset;
    g_mutex_unlock(&export_mutex);
    return 1;
}

MLT_EXPORT_API
int mlt_bridge_export_set_video_frame_rate(
    int numerator,
    int denominator)
{
    if (!export_video_frame_rate_is_supported(
            numerator,
            denominator)) {
        return 0;
    }

    /* A completed worker may still have a joinable GThread handle. */
    join_finished_export_thread();

    ensure_export_lock();
    g_mutex_lock(&export_mutex);

    if (export_running) {
        g_mutex_unlock(&export_mutex);
        return 0;
    }

    export_video_frame_rate_num = numerator;
    export_video_frame_rate_den = denominator;
    g_mutex_unlock(&export_mutex);
    return 1;
}

static void cancel_export_and_join(void)
{
    ensure_export_lock();

    GThread *thread = NULL;

    g_mutex_lock(&export_mutex);

    if (export_thread != NULL) {
        export_cancel_requested = 1;
        thread = export_thread;
        export_thread = NULL;
    }

    g_mutex_unlock(&export_mutex);

    if (thread != NULL) {
        g_thread_join(thread);
    }
}

static void export_job_apply_composition_snapshot(
    ExportJob *job,
    const MltExportCompositionSnapshot *snapshot)
{
    if (job == NULL ||
        snapshot == NULL ||
        snapshot->layer_count < 1) {
        return;
    }

    const MltExportLayerSnapshot *base =
        &snapshot->layers[MLT_COMPOSITION_BASE_LAYER];

    job->export_snapshot_valid = 1;
    const int snapshot_order_valid =
        export_visual_order_is_permutation(snapshot->visual_order);
    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        job->export_visual_order[index] =
            snapshot_order_valid ? snapshot->visual_order[index] : index;
    }
    job->export_primary_has_audio = base->has_audio ? 1 : 0;
    job->export_primary_audio_gain =
        CLAMP(base->audio_gain, 0.0, 1.0);
    job->export_secondary_audio_gain = 1.0;
    job->export_secondary_opacity = 1.0;
    job->export_secondary_scale = 1.0;
    job->export_tertiary_audio_gain = 1.0;
    job->export_tertiary_opacity = 1.0;
    job->export_tertiary_scale = 1.0;

    if (snapshot->layer_count < 2) {
        return;
    }

    const MltExportLayerSnapshot *layer2 =
        &snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY];

    job->export_has_secondary = 1;
    job->export_secondary_start_frame = layer2->start_frame;
    job->export_secondary_end_frame = layer2->end_frame;
    job->export_secondary_source_in_frame = layer2->source_in_frame;
    job->export_secondary_source_out_frame = layer2->source_out_frame;
    job->export_secondary_has_audio = layer2->has_audio ? 1 : 0;
    job->export_secondary_is_still = layer2->is_still ? 1 : 0;
    job->export_secondary_alpha_mode = layer2->alpha_mode;
    job->export_secondary_audio_gain =
        CLAMP(layer2->audio_gain, 0.0, 1.0);
    job->export_secondary_opacity =
        CLAMP(layer2->opacity, 0.0, 1.0);
    job->export_secondary_x = layer2->x;
    job->export_secondary_y = layer2->y;
    job->export_secondary_scale =
        CLAMP(layer2->scale, 0.10, 3.0);

    if (snapshot->layer_count < 3) {
        return;
    }

    const MltExportLayerSnapshot *layer3 =
        &snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY];
    job->export_has_tertiary = 1;
    job->export_tertiary_start_frame = layer3->start_frame;
    job->export_tertiary_end_frame = layer3->end_frame;
    job->export_tertiary_source_in_frame = layer3->source_in_frame;
    job->export_tertiary_source_out_frame = layer3->source_out_frame;
    job->export_tertiary_has_audio = layer3->has_audio ? 1 : 0;
    job->export_tertiary_is_still = layer3->is_still ? 1 : 0;
    job->export_tertiary_alpha_mode = layer3->alpha_mode;
    job->export_tertiary_audio_gain = CLAMP(layer3->audio_gain, 0.0, 1.0);
    job->export_tertiary_opacity = CLAMP(layer3->opacity, 0.0, 1.0);
    job->export_tertiary_x = layer3->x;
    job->export_tertiary_y = layer3->y;
    job->export_tertiary_scale = CLAMP(layer3->scale, 0.10, 3.0);
}

static int launch_export_job(ExportJob *job)
{
    ensure_export_lock();

    if (job == NULL ||
        job->export_source_path == NULL ||
        job->export_source_path[0] == '\0' ||
        job->export_output_path == NULL ||
        job->export_output_path[0] == '\0' ||
        job->export_out_frame < job->export_in_frame) {
        export_job_free(job);
        g_mutex_lock(&export_mutex);
        export_set_error_locked("Invalid export request.");
        g_mutex_unlock(&export_mutex);
        return 0;
    }


    join_finished_export_thread();

    g_mutex_lock(&export_mutex);

    if (export_running || export_thread != NULL) {
        export_job_free(job);
        export_set_error_locked("An export is already running.");
        g_mutex_unlock(&export_mutex);
        return 0;
    }

    job->export_video_preset = export_video_preset;
    job->export_video_frame_rate_num = export_video_frame_rate_num;
    job->export_video_frame_rate_den = export_video_frame_rate_den;

    export_running = 1;
    export_success = 0;
    export_cancel_requested = 0;
    export_progress = 0.0;
    export_set_error_locked(NULL);

    export_thread =
        g_thread_new(
            "mlt-player-export",
            export_worker,
            job
        );

    if (export_thread == NULL) {
        export_running = 0;
        export_job_free(job);
        export_set_error_locked("Could not start the export worker.");
        g_mutex_unlock(&export_mutex);
        return 0;
    }

    g_mutex_unlock(&export_mutex);
    return 1;
}

static int start_export_job(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    MltExportKind kind)
{
    ExportJob *job = g_new0(ExportJob, 1);

    if (job == NULL) {
        ensure_export_lock();
        g_mutex_lock(&export_mutex);
        export_set_error_locked("Could not allocate the export job.");
        g_mutex_unlock(&export_mutex);
        return 0;
    }

    job->export_source_path = g_strdup(source_path);
    job->export_output_path = g_strdup(output_path);
    job->export_in_frame = in_frame;
    job->export_out_frame = out_frame;
    job->export_primary_audio_gain = 1.0;
    job->export_secondary_audio_gain = 1.0;
    job->export_secondary_opacity = 1.0;
    job->export_secondary_scale = 1.0;
    job->export_tertiary_audio_gain = 1.0;
    job->export_tertiary_opacity = 1.0;
    job->export_tertiary_scale = 1.0;
    job->export_kind = kind;

    return launch_export_job(job);
}

/*
 * POC 10.9 snapshots the open layered movie and exports from a completely
 * independent graph. kind uses MltExportKind's stable 0..3 values.
 */

void mlt_export_set_error(const char *message)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);
    export_set_error_locked(message);
    g_mutex_unlock(&export_mutex);
}

int mlt_export_start_simple(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    MltExportKind kind)
{
    if (kind < MLT_EXPORT_KIND_MP4 ||
        kind > MLT_EXPORT_KIND_WAV_AUDIO) {
        mlt_export_set_error("Invalid export request.");
        return 0;
    }

    return start_export_job(
        source_path,
        output_path,
        in_frame,
        out_frame,
        kind
    );
}

int mlt_export_start_composition(
    const MltExportCompositionSnapshot *snapshot,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    MltExportKind kind)
{
    if (snapshot == NULL ||
        snapshot->layer_count < 1 ||
        snapshot->layer_count > MLT_COMPOSITION_MAX_LAYERS ||
        !snapshot->layers[MLT_COMPOSITION_BASE_LAYER].present ||
        snapshot->layers[MLT_COMPOSITION_BASE_LAYER].path == NULL ||
        snapshot->layers[MLT_COMPOSITION_BASE_LAYER].path[0] == '\0' ||
        output_path == NULL ||
        output_path[0] == '\0' ||
        out_frame < in_frame ||
        kind < MLT_EXPORT_KIND_MP4 ||
        kind > MLT_EXPORT_KIND_WAV_AUDIO) {
        mlt_export_set_error("Invalid composition export request.");
        return 0;
    }

    for (int index = 1; index < snapshot->layer_count; index++) {
        const MltExportLayerSnapshot *layer = &snapshot->layers[index];
        if (!layer->present ||
            layer->path == NULL ||
            layer->path[0] == '\0') {
            mlt_export_set_error("An overlay layer has no exportable source path.");
            return 0;
        }
    }

    ExportJob *job = g_new0(ExportJob, 1);

    if (job == NULL) {
        mlt_export_set_error("Could not allocate the export snapshot.");
        return 0;
    }

    const MltExportLayerSnapshot *base =
        &snapshot->layers[MLT_COMPOSITION_BASE_LAYER];

    job->export_source_path = g_strdup(base->path);
    job->export_output_path = g_strdup(output_path);
    job->export_in_frame = in_frame;
    job->export_out_frame = out_frame;
    job->export_kind = kind;
    export_job_apply_composition_snapshot(job, snapshot);

    if (snapshot->layer_count >= 2) {
        job->export_secondary_path =
            g_strdup(snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY].path);
    }
    if (snapshot->layer_count >= 3) {
        job->export_tertiary_path =
            g_strdup(snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY].path);
    }

    if (job->export_source_path == NULL ||
        job->export_output_path == NULL ||
        (job->export_has_secondary && job->export_secondary_path == NULL) ||
        (job->export_has_tertiary && job->export_tertiary_path == NULL)) {
        export_job_free(job);
        mlt_export_set_error("Could not copy the composition export snapshot.");
        return 0;
    }

    return launch_export_job(job);
}

int mlt_export_derive_composition(
    const MltExportCompositionSnapshot *snapshot,
    int64_t in_frame,
    int64_t out_frame,
    MltCompositionDerivedState *state_out,
    char *error_buffer,
    int error_capacity)
{
    if (state_out != NULL) {
        memset(state_out, 0, sizeof(*state_out));
    }

    if (error_buffer != NULL && error_capacity > 0) {
        error_buffer[0] = '\0';
    }

    if (snapshot == NULL ||
        snapshot->layer_count < 1 ||
        snapshot->layer_count > MLT_COMPOSITION_MAX_LAYERS ||
        !snapshot->layers[MLT_COMPOSITION_BASE_LAYER].present ||
        snapshot->layers[MLT_COMPOSITION_BASE_LAYER].path == NULL ||
        snapshot->layers[MLT_COMPOSITION_BASE_LAYER].path[0] == '\0' ||
        state_out == NULL ||
        out_frame < in_frame ||
        (snapshot->layer_count >= 2 &&
         (!snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY].present ||
          snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY].path == NULL ||
          snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY].path[0] == '\0')) ||
        (snapshot->layer_count >= 3 &&
         (!snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY].present ||
          snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY].path == NULL ||
          snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY].path[0] == '\0'))) {
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(
                error_buffer,
                (size_t)error_capacity,
                "%s",
                "Invalid composition parity request."
            );
        }
        return 0;
    }

    ensure_export_lock();
    g_mutex_lock(&export_mutex);
    const int busy = export_running || export_thread != NULL;
    g_mutex_unlock(&export_mutex);

    if (busy) {
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(
                error_buffer,
                (size_t)error_capacity,
                "%s",
                "Composition parity cannot run while an export is active."
            );
        }
        return 0;
    }

    ExportJob job = {0};
    job.export_source_path =
        (char *)snapshot->layers[MLT_COMPOSITION_BASE_LAYER].path;
    job.export_secondary_path =
        snapshot->layer_count >= 2
            ? (char *)snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY].path
            : NULL;
    job.export_tertiary_path =
        snapshot->layer_count >= 3
            ? (char *)snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY].path
            : NULL;
    job.export_in_frame = in_frame;
    job.export_out_frame = out_frame;
    job.export_kind = MLT_EXPORT_KIND_MP4;
    export_job_apply_composition_snapshot(&job, snapshot);

    ExportGraph graph = {0};
    int64_t normalized_in = 0;
    int64_t normalized_out = -1;
    char failure[512] = "";

    const int prepared =
        export_prepare_source_graph(
            &job,
            &graph,
            &normalized_in,
            &normalized_out,
            failure,
            sizeof(failure)
        );

    if (!prepared) {
        if (error_buffer != NULL && error_capacity > 0) {
            snprintf(
                error_buffer,
                (size_t)error_capacity,
                "%s",
                failure[0] != '\0'
                    ? failure
                    : "Could not derive the export composition state."
            );
        }
        return 0;
    }

    graph.derived.range_in_frame = normalized_in;
    graph.derived.range_out_frame = normalized_out;
    *state_out = graph.derived;

    export_graph_close(&graph);
    return 1;
}

void mlt_export_cancel(void)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);

    if (export_running) {
        export_cancel_requested = 1;
    }

    g_mutex_unlock(&export_mutex);
}

int mlt_export_is_running(void)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);
    const int result = export_running;
    g_mutex_unlock(&export_mutex);

    if (!result) {
        join_finished_export_thread();
    }

    return result;
}

double mlt_export_progress(void)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);
    const double result = export_progress;
    g_mutex_unlock(&export_mutex);

    return result;
}

int mlt_export_succeeded(void)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);
    const int result = !export_running && export_success;
    g_mutex_unlock(&export_mutex);

    return result;
}

int mlt_export_error_copy(
    char *buffer,
    int capacity)
{
    ensure_export_lock();

    g_mutex_lock(&export_mutex);

    const char *source = export_error;
    const size_t length = strlen(source);
    int required = 0;

    if (length < (size_t)INT_MAX) {
        required = (int)length + 1;

        if (buffer != NULL && capacity > 0) {
            const size_t writable =
                capacity > 1 ? (size_t)(capacity - 1) : 0;
            const size_t copy_length =
                length < writable ? length : writable;

            if (copy_length > 0) {
                memcpy(buffer, source, copy_length);
            }
            buffer[copy_length] = '\0';
        }
    }

    g_mutex_unlock(&export_mutex);
    return required;
}

void mlt_export_shutdown(void)
{
    cancel_export_and_join();
}
