/* native/mlt_export_preset_smoke.c */

#include "mlt_bridge.h"

#include <glib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

/* Opaque engine APIs are part of the current bridge ABI. */
typedef struct _MltBridgeEngine MltBridgeEngine;
extern MltBridgeEngine *mlt_bridge_engine_create(void);
extern int mlt_bridge_engine_activate(MltBridgeEngine *engine);
extern void mlt_bridge_engine_destroy(MltBridgeEngine *engine);
extern int mlt_bridge_export_composition_start(
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    int kind
);

/* Purpose-preset ABI added by native/mlt_export.c. */
extern int mlt_bridge_export_set_video_preset(int preset);

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

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s MEDIA OUTPUT.mov\n", argv[0]);
        return 2;
    }

    const char *media_path = argv[1];
    const char *output_path = argv[2];

    printf("video export presets\n");

    check(mlt_bridge_init(), "MLT initializes");

    MltBridgeEngine *engine = mlt_bridge_engine_create();
    check(engine != NULL, "engine can be created");

    if (engine == NULL) {
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
    check(duration > 0, "test media has a timeline");

    check(
        !mlt_bridge_export_set_video_preset(-1),
        "invalid preset is rejected"
    );

    check(
        mlt_bridge_export_set_video_preset(1),
        "ProRes 422 HQ Master preset is accepted"
    );

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
        "ProRes master export starts"
    );

    check(
        wait_for_export_completion(30000),
        "ProRes master export completes"
    );

    check(
        mlt_bridge_export_succeeded(),
        "ProRes master export reports success"
    );

    check(
        file_has_data(output_path),
        "ProRes master export writes output"
    );

    check(
        mlt_bridge_export_set_video_preset(0),
        "H.264 Delivery preset can be restored"
    );

    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    if (failures == 0) {
        printf("\nPASS video export presets (0 failures)\n");
        return 0;
    }

    printf(
        "\nFAIL video export presets (%d %s)\n",
        failures,
        failures == 1 ? "failure" : "failures"
    );
    return 1;
}
