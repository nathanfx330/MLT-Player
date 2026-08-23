/* native/mlt_guard_smoke.c
 *
 * Regression probe for public bridge calls made with no active engine.
 * These calls must fail closed with neutral values instead of dereferencing
 * the thread-local engine pointer after teardown.
 */

#include "mlt_bridge.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

static void check(
    int condition,
    const char *description)
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

int main(void)
{
    printf("no-active-engine guards\n");

    check(
        mlt_bridge_init(),
        "MLT initializes"
    );

    MltBridgeEngine *engine =
        mlt_bridge_engine_create();

    check(
        engine != NULL,
        "engine can be created"
    );

    if (engine == NULL) {
        mlt_bridge_shutdown();
        return 1;
    }

    check(
        mlt_bridge_engine_activate(engine),
        "engine can be activated"
    );

    /*
     * Destroying the caller's active engine intentionally clears the TLS
     * activation slot. Every operation below therefore exercises the guard,
     * not a normal empty-media state.
     */
    mlt_bridge_engine_destroy(engine);

    check(
        !mlt_bridge_open("/definitely/not/a/media/file.mp4"),
        "open fails closed without an active engine"
    );

    check(
        !mlt_bridge_play(),
        "play fails closed without an active engine"
    );

    check(
        !mlt_bridge_seek_frame(12),
        "seek fails closed without an active engine"
    );

    check(
        mlt_bridge_width() == 0 &&
            mlt_bridge_height() == 0 &&
            mlt_bridge_duration_frames() == 0,
        "media getters return neutral values without an active engine"
    );

    check(
        mlt_bridge_secondary_start_frame() == -1 &&
            mlt_bridge_video_stream_index() == -1 &&
            mlt_bridge_audio_stream_index() == -1,
        "sentinel getters stay meaningful without an active engine"
    );

    check(
        mlt_bridge_secondary_scale() == 1.0 &&
            mlt_bridge_volume() == 1.0,
        "identity-value getters remain safe without an active engine"
    );

    char value[32] = "not-empty";
    const int required =
        mlt_bridge_video_codec_name_copy(
            value,
            (int)sizeof(value)
        );

    check(
        required == 1 &&
            value[0] == '\0',
        "string getters return an empty string without an active engine"
    );

    /*
     * Void operations are included because these were previously just as
     * capable of dereferencing NULL as integer-returning entry points.
     */
    mlt_bridge_set_volume(0.5);
    mlt_bridge_close_media();

    char error[128] = "";
    mlt_bridge_last_error_copy(
        error,
        (int)sizeof(error)
    );

    check(
        strstr(error, "No active MLT engine") != NULL,
        "last error explains the missing active engine"
    );

    MltBridgeEngine *replacement =
        mlt_bridge_engine_create();

    check(
        replacement != NULL,
        "a new engine can be created after guarded teardown calls"
    );

    if (replacement != NULL) {
        check(
            mlt_bridge_engine_activate(replacement),
            "a replacement engine can be activated"
        );

        check(
            mlt_bridge_width() == 0,
            "replacement engine starts in a clean empty-media state"
        );

        mlt_bridge_engine_destroy(replacement);
    }

    mlt_bridge_shutdown();

    if (failures == 0) {
        printf("\nPASS guards (0 failures)\n");
        return 0;
    }

    printf(
        "\nFAIL guards (%d failure%s)\n",
        failures,
        failures == 1 ? "" : "s"
    );

    return 1;
}
