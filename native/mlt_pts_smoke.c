/* native/mlt_pts_smoke.c
 *
 * Focused MP4 timestamp diagnostic.
 *
 * This program deliberately does not change exporter behavior. It enables
 * MLT debug logging, opens one controlled fixture, exports it through either
 * the simple or composition path, and exits only after that export completes.
 * tools/smoke.sh captures stderr separately for each case so warnings can be
 * correlated with the presence of an encoded audio stream.
 */

#include "mlt_bridge.h"

#include <framework/mlt_log.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int wait_for_export_completion(int timeout_ms)
{
    int elapsed_ms = 0;

    while (mlt_bridge_export_is_running() &&
           elapsed_ms < timeout_ms) {
        usleep(50000);
        elapsed_ms += 50;
    }

    return !mlt_bridge_export_is_running();
}

static void copy_export_error(
    char *buffer,
    int capacity)
{
    if (buffer == NULL || capacity <= 0) {
        return;
    }

    const int required =
        mlt_bridge_export_error_copy(
            buffer,
            capacity
        );

    if (required <= 0) {
        buffer[0] = '\0';
    }
}

static void copy_bridge_error(
    char *buffer,
    int capacity)
{
    if (buffer == NULL || capacity <= 0) {
        return;
    }

    const int required =
        mlt_bridge_last_error_copy(
            buffer,
            capacity
        );

    if (required <= 0) {
        buffer[0] = '\0';
    }
}

int main(
    int argc,
    char **argv)
{
    if (argc < 4 || argc > 5) {
        fprintf(
            stderr,
            "usage: %s <simple|composition> <media> <output.mp4> [still.png]\n",
            argv[0]
        );
        return 2;
    }

    const char *mode = argv[1];
    const char *media_path = argv[2];
    const char *output_path = argv[3];
    const char *still_path = argc > 4 ? argv[4] : NULL;

    const int use_composition =
        strcmp(mode, "composition") == 0;
    const int use_simple =
        strcmp(mode, "simple") == 0;

    if (!use_simple && !use_composition) {
        fprintf(
            stderr,
            "PTS diagnostic mode must be 'simple' or 'composition'.\n"
        );
        return 2;
    }

    /*
     * Set this before the factory is initialized. The avformat module copies
     * MLT's current log level into FFmpeg when that module initializes.
     */
    mlt_log_set_level(MLT_LOG_DEBUG);

    if (!mlt_bridge_init()) {
        char error[512] = "";
        copy_bridge_error(error, (int)sizeof(error));
        fprintf(
            stderr,
            "PTS diagnostic could not initialize MLT: %s\n",
            error
        );
        return 1;
    }

    MltBridgeEngine *engine =
        mlt_bridge_engine_create();

    if (engine == NULL ||
        !mlt_bridge_engine_activate(engine)) {
        char error[512] = "";
        copy_bridge_error(error, (int)sizeof(error));
        fprintf(
            stderr,
            "PTS diagnostic could not initialize an engine: %s\n",
            error
        );

        if (engine != NULL) {
            mlt_bridge_engine_destroy(engine);
        }

        mlt_bridge_shutdown();
        return 1;
    }

    int result = 1;

    if (!mlt_bridge_open(media_path)) {
        char error[512] = "";
        copy_bridge_error(error, (int)sizeof(error));
        fprintf(
            stderr,
            "PTS diagnostic could not open media: %s\n",
            error
        );
        goto cleanup;
    }

    const int64_t duration_frames =
        mlt_bridge_duration_frames();

    if (duration_frames <= 0) {
        fprintf(
            stderr,
            "PTS diagnostic fixture has no usable timeline.\n"
        );
        goto cleanup;
    }

    const int base_has_audio =
        mlt_bridge_track_has_audio(0);

    int layer2_added = 0;

    if (use_composition &&
        still_path != NULL &&
        still_path[0] != '\0') {
        const int64_t start_frame =
            duration_frames > 60
                ? 40
                : duration_frames / 4;

        if (!mlt_bridge_add_track(
                still_path,
                start_frame)) {
            char error[512] = "";
            copy_bridge_error(error, (int)sizeof(error));
            fprintf(
                stderr,
                "PTS diagnostic could not add still layer: %s\n",
                error
            );
            goto cleanup;
        }

        layer2_added = 1;
    }

    remove(output_path);

    const int export_started =
        use_simple
            ? mlt_bridge_export_start(
                media_path,
                output_path,
                0,
                duration_frames - 1
            )
            : mlt_bridge_export_composition_start(
                output_path,
                0,
                duration_frames - 1,
                0
            );

    if (!export_started) {
        char error[512] = "";
        copy_export_error(error, (int)sizeof(error));
        fprintf(
            stderr,
            "PTS diagnostic export did not start: %s\n",
            error
        );
        goto cleanup;
    }

    if (!wait_for_export_completion(30000)) {
        fprintf(
            stderr,
            "PTS diagnostic export timed out.\n"
        );
        mlt_bridge_export_cancel();
        goto cleanup;
    }

    if (!mlt_bridge_export_succeeded()) {
        char error[512] = "";
        copy_export_error(error, (int)sizeof(error));
        fprintf(
            stderr,
            "PTS diagnostic export failed: %s\n",
            error
        );
        goto cleanup;
    }

    printf(
        "PTS_DIAG mode=%s base_audio=%d layer2=%d frames=%lld output=%s\n",
        mode,
        base_has_audio,
        layer2_added,
        (long long)duration_frames,
        output_path
    );

    result = 0;

cleanup:
    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    return result;
}
