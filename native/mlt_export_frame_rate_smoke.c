/* native/mlt_export_frame_rate_smoke.c */

#include "mlt_bridge.h"
#include "mlt_layer_api.h"

#include <glib.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>

/* Export-output policy ABI from native/mlt_export.c. */
extern int mlt_bridge_export_set_video_preset(int preset);
extern int mlt_bridge_export_set_video_frame_rate(
    int numerator,
    int denominator
);

static int failures = 0;

static void check(int condition, const char *description)
{
    printf(
        "  [%s] %s\n",
        condition ? "ok" : "FAIL",
        description
    );

    if (!condition) {
        failures++;
    }
}

static int file_has_data(const char *path)
{
    struct stat info;
    return path != NULL &&
        stat(path, &info) == 0 &&
        info.st_size > 0;
}

static int wait_for_export_completion(int timeout_ms)
{
    const gint64 deadline =
        g_get_monotonic_time() + ((gint64)timeout_ms * 1000);

    while (mlt_bridge_export_is_running() &&
           g_get_monotonic_time() < deadline) {
        g_usleep(50000);
    }

    return !mlt_bridge_export_is_running();
}

static int command_exit_code(const char *command)
{
    if (command == NULL || command[0] == '\0') {
        return -1;
    }

    const int status = system(command);

    if (status == -1 || !WIFEXITED(status)) {
        return -1;
    }

    return WEXITSTATUS(status);
}

static int generate_overlay_fixture(
    const char *path,
    int width,
    int height)
{
    if (path == NULL || width <= 0 || height <= 0) {
        return 0;
    }

    char *quoted_path = g_shell_quote(path);
    if (quoted_path == NULL) {
        return 0;
    }

    /*
     * 150 frames at 25 fps. Frames 0..37 are yellow; frames 38..149 are
     * magenta. Source In is later set to frame 40. When that boundary is
     * correctly conformed to 30000/1001, the first visible overlay frame is
     * magenta. If Source In were incorrectly left at frame 40 in the output
     * profile, it would still land in the yellow section.
     */
    char *command = g_strdup_printf(
        "ffmpeg -hide_banner -loglevel error -y "
        "-f lavfi -i 'color=c=yellow:s=%dx%d:r=25:d=1.52' "
        "-f lavfi -i 'color=c=magenta:s=%dx%d:r=25:d=4.48' "
        "-filter_complex '[0:v][1:v]concat=n=2:v=1:a=0,format=yuv420p[v]' "
        "-map '[v]' -an -c:v libx264 -preset ultrafast -crf 0 %s",
        width,
        height,
        width,
        height,
        quoted_path
    );

    g_free(quoted_path);

    if (command == NULL) {
        return 0;
    }

    const int result = command_exit_code(command) == 0;
    g_free(command);

    return result && file_has_data(path);
}

/*
 * Return 1 when the selected encoded output frame is predominantly magenta,
 * 0 when it is not, and -1 when the frame could not be sampled.
 *
 * Scaling the selected frame to 1x1 with area averaging makes this robust to
 * H.264 quantization while still strongly separating the full-frame magenta
 * overlay from the generated testsrc2 base movie.
 */
static int frame_is_magenta(
    const char *path,
    int frame)
{
    if (path == NULL || frame < 0) {
        return -1;
    }

    char *quoted_path = g_shell_quote(path);
    if (quoted_path == NULL) {
        return -1;
    }

    char *command = g_strdup_printf(
        "ffmpeg -hide_banner -loglevel error -i %s "
        "-vf \"select='eq(n\\,%d)',scale=1:1:flags=area,format=rgb24\" "
        "-frames:v 1 -fps_mode passthrough -f rawvideo - 2>/dev/null | "
        "od -An -tu1 -N3 | "
        "awk '{ if (NF < 3) exit 2; "
        "exit !( $1 > 150 && $2 < 110 && $3 > 150 ) }'",
        quoted_path,
        frame
    );

    g_free(quoted_path);

    if (command == NULL) {
        return -1;
    }

    const int exit_code = command_exit_code(command);
    g_free(command);

    if (exit_code == 0) {
        return 1;
    }
    if (exit_code == 1) {
        return 0;
    }
    return -1;
}

static int run_simple_one_second_export(
    const char *output_path,
    int64_t duration)
{
    remove(output_path);

    const int64_t out_frame =
        duration > 25 ? 24 : duration - 1;

    check(
        out_frame >= 0 &&
        mlt_bridge_export_composition_start(
            output_path,
            0,
            out_frame,
            0
        ),
        "29.97 fps conform export starts"
    );

    check(
        wait_for_export_completion(30000),
        "29.97 fps conform export completes"
    );

    check(
        mlt_bridge_export_succeeded(),
        "29.97 fps conform export reports success"
    );

    check(
        file_has_data(output_path),
        "29.97 fps conform export writes output"
    );

    return mlt_bridge_export_succeeded() &&
        file_has_data(output_path);
}

static int run_layered_conform_export(
    const char *media_path,
    const char *overlay_path,
    const char *layered_output_path,
    int64_t duration)
{
    check(
        mlt_bridge_open(media_path),
        "base media reopens for layered conform coverage"
    );

    check(
        mlt_bridge_add_track_bounded_source(
            overlay_path,
            100,
            130,
            40,
            149
        ),
        "Layer 2 combines bounded timeline and source trim"
    );
    check(
        mlt_bridge_layer_start_frame(1) == 100 &&
        mlt_bridge_layer_end_frame(1) == 130 &&
        mlt_bridge_layer_source_in_frame(1) == 40 &&
        mlt_bridge_layer_source_out_frame(1) == 149,
        "Layer 2 source-rate START/END and SOURCE IN/OUT are exact"
    );

    check(
        mlt_bridge_add_layer_with_state_trimmed(
            2,
            overlay_path,
            20,
            149,
            40,
            90,
            0.0,
            0.0,
            1.0,
            1.0,
            0,
            1.0
        ),
        "Layer 3 combines long timeline window and shorter source trim"
    );
    check(
        mlt_bridge_track_count() == 3,
        "layered conform fixture has three logical layers"
    );
    check(
        mlt_bridge_layer_start_frame(2) == 20 &&
        mlt_bridge_layer_end_frame(2) == 70 &&
        mlt_bridge_layer_source_in_frame(2) == 40 &&
        mlt_bridge_layer_source_out_frame(2) == 90,
        "Layer 3 ends at source frame 90 before its requested timeline END"
    );

    check(
        mlt_bridge_export_set_video_frame_rate(30000, 1001),
        "29.97 fps conform remains selected for layered export"
    );

    remove(layered_output_path);

    check(
        mlt_bridge_export_composition_start(
            layered_output_path,
            0,
            duration - 1,
            0
        ),
        "layered 29.97 fps conform export starts"
    );
    check(
        wait_for_export_completion(30000),
        "layered 29.97 fps conform export completes"
    );
    check(
        mlt_bridge_export_succeeded(),
        "layered 29.97 fps conform export reports success"
    );
    check(
        file_has_data(layered_output_path),
        "layered 29.97 fps conform writes output"
    );

    if (!mlt_bridge_export_succeeded() ||
        !file_has_data(layered_output_path)) {
        return 0;
    }

    /*
     * Source-rate Layer 3 START 20 -> output frame 24.
     * Its source 40..90 becomes output-profile source 48..108, a 61-frame
     * selected range, so it occupies movie frames 24..84 and disappears at 85.
     */
    const int frame22 = frame_is_magenta(layered_output_path, 22);
    const int frame24 = frame_is_magenta(layered_output_path, 24);
    const int frame80 = frame_is_magenta(layered_output_path, 80);
    const int frame85 = frame_is_magenta(layered_output_path, 85);

    check(
        frame22 == 0,
        "Layer 3 START is not left at source frame 20"
    );
    check(
        frame24 == 1,
        "Layer 3 START 20 conforms to output frame 24 and SOURCE IN lands in magenta"
    );
    check(
        frame80 == 1,
        "Layer 3 SOURCE OUT is scaled instead of ending at an unscaled output frame"
    );
    check(
        frame85 == 0,
        "Layer 3 conformed source range ends after output frame 84"
    );

    /*
     * Source-rate Layer 2 START 100 -> output frame 120.
     * Inclusive END 130 converts by exclusive boundary 131 -> 157, so the
     * final visible output frame is 156 and frame 157 returns to the base.
     */
    const int frame118 = frame_is_magenta(layered_output_path, 118);
    const int frame120 = frame_is_magenta(layered_output_path, 120);
    const int frame156 = frame_is_magenta(layered_output_path, 156);
    const int frame157 = frame_is_magenta(layered_output_path, 157);

    check(
        frame118 == 0,
        "Layer 2 START is not left at source frame 100"
    );
    check(
        frame120 == 1,
        "Layer 2 START 100 conforms to output frame 120 and SOURCE IN lands in magenta"
    );
    check(
        frame156 == 1,
        "Layer 2 inclusive END survives through conformed output frame 156"
    );
    check(
        frame157 == 0,
        "Layer 2 inclusive END 130 converts to output END 156"
    );

    return frame22 == 0 &&
        frame24 == 1 &&
        frame80 == 1 &&
        frame85 == 0 &&
        frame118 == 0 &&
        frame120 == 1 &&
        frame156 == 1 &&
        frame157 == 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s MEDIA OUTPUT.mp4\n", argv[0]);
        return 2;
    }

    const char *media_path = argv[1];
    const char *output_path = argv[2];

    char *overlay_path =
        g_strdup_printf("%s.layered-fixture.mp4", output_path);
    char *layered_output_path =
        g_strdup_printf("%s.layered.mp4", output_path);

    if (overlay_path == NULL || layered_output_path == NULL) {
        g_free(overlay_path);
        g_free(layered_output_path);
        return 1;
    }

    printf("video export frame rate\n");

    check(mlt_bridge_init(), "MLT initializes");

    MltBridgeEngine *engine = mlt_bridge_engine_create();
    check(engine != NULL, "engine can be created");

    if (engine == NULL) {
        g_free(overlay_path);
        g_free(layered_output_path);
        mlt_bridge_shutdown();
        return 1;
    }

    check(
        mlt_bridge_engine_activate(engine),
        "engine can be activated"
    );

    check(
        mlt_bridge_open(media_path),
        "test media opens"
    );

    const int64_t duration = mlt_bridge_duration_frames();
    const double source_fps = mlt_bridge_fps();
    const int width = mlt_bridge_width();
    const int height = mlt_bridge_height();

    check(duration >= 150, "test media has enough timeline for layered conform");
    check(
        fabs(source_fps - 25.0) < 0.001,
        "frame-rate fixture is 25 fps"
    );
    check(
        width > 0 && height > 0,
        "frame-rate fixture has valid video dimensions"
    );

    check(
        !mlt_bridge_export_set_video_frame_rate(24, 0),
        "invalid frame-rate rational is rejected"
    );

    check(
        !mlt_bridge_export_set_video_frame_rate(27, 1),
        "unsupported frame rate is rejected"
    );

    check(
        mlt_bridge_export_set_video_preset(0),
        "H.264 Delivery preset is selected"
    );

    check(
        mlt_bridge_export_set_video_frame_rate(30000, 1001),
        "29.97 fps conform is accepted"
    );

    /* Preserve the original one-source one-second conform regression. */
    if (duration > 0) {
        run_simple_one_second_export(output_path, duration);
    }

    const int fixture_ready =
        duration >= 150 &&
        fabs(source_fps - 25.0) < 0.001 &&
        width > 0 &&
        height > 0 &&
        generate_overlay_fixture(
            overlay_path,
            width,
            height
        );

    check(
        fixture_ready,
        "two-color overlay fixture is generated for layered conform coverage"
    );

    if (fixture_ready) {
        run_layered_conform_export(
            media_path,
            overlay_path,
            layered_output_path,
            duration
        );
    }

    check(
        mlt_bridge_export_set_video_frame_rate(0, 1),
        "Source frame rate can be restored"
    );

    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    remove(overlay_path);
    remove(layered_output_path);
    g_free(overlay_path);
    g_free(layered_output_path);

    if (failures == 0) {
        printf("\nPASS video export frame rate (0 failures)\n");
        return 0;
    }

    printf(
        "\nFAIL video export frame rate (%d %s)\n",
        failures,
        failures == 1 ? "failure" : "failures"
    );
    return 1;
}
