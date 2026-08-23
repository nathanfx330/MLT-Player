/* native/mlt_smoke.c
 *
 * Headless exercise of the bridge, with no Flutter and no window.
 *
 * The point is to separate "MLT and the bridge are misbehaving" from
 * "the Flutter integration is misbehaving". It runs the transport
 * through the same sequence the UI does, on a GLib main loop, so the
 * locking and the frame callback are under the same conditions.
 *
 * Build:
 *   gcc native/mlt_smoke.c -o native/mlt_smoke \
 *     $(pkg-config --cflags --libs mlt-framework-7 glib-2.0) \
 *     -Lbuild/linux/x64/debug/bundle/lib -lmlt_bridge \
 *     -Wl,-rpath,build/linux/x64/debug/bundle/lib
 *
 * Run:
 *   SDL_AUDIODRIVER=dummy ./native/mlt_smoke clip.mp4 [junk.txt] [still.png]
 *
 * tools/smoke.sh does all of this for you, fixtures included.
 */

#include "mlt_bridge.h"

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>

static const char *media_path = NULL;
static const char *junk_path = NULL;
static const char *still_path = NULL;

static GMainLoop *loop = NULL;
static MltBridgeEngine *engine = NULL;

static int step = 0;
static int failures = 0;

static int64_t position_before_seek = 0;

static void copy_last_error(
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

static void check_engine_isolation(void)
{
    MltBridgeEngine *primary = engine;
    const int64_t primary_position =
        mlt_bridge_position_frame();

    MltBridgeEngine *secondary =
        mlt_bridge_engine_create();

    check(
        secondary != NULL,
        "second opaque engine can be created"
    );

    if (secondary == NULL) {
        return;
    }

    check(
        mlt_bridge_engine_activate(secondary),
        "second opaque engine can be activated"
    );

    const int secondary_opened =
        mlt_bridge_open(media_path);

    check(
        secondary_opened,
        "second opaque engine opens media independently"
    );

    if (secondary_opened) {
        const int64_t length =
            mlt_bridge_duration_frames();

        const int64_t target =
            length > 6 ? 5 : (length > 1 ? length - 1 : 0);

        check(
            mlt_bridge_seek_frame(target),
            "second opaque engine seeks independently"
        );

        check(
            mlt_bridge_position_frame() == target,
            "second opaque engine reports its own playhead"
        );
    }

    check(
        mlt_bridge_engine_activate(primary),
        "primary opaque engine can be reactivated"
    );

    check(
        mlt_bridge_position_frame() == primary_position,
        "second engine does not move primary playhead"
    );

    mlt_bridge_engine_activate(secondary);
    mlt_bridge_engine_destroy(secondary);
    mlt_bridge_engine_activate(primary);
}

static gboolean run_step(
    gpointer user_data)
{
    (void)user_data;

    if (engine == NULL ||
        !mlt_bridge_engine_activate(engine)) {
        fprintf(stderr, "MLT engine is unavailable.\n");
        failures++;
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }

    switch (step++) {
    case 0:
        printf("open\n");

        check(
            mlt_bridge_open(media_path),
            "media opens"
        );

        printf(
            "  %d x %d, %.3f fps, %" G_GINT64_FORMAT " ms, "
            "aspect %.4f, still %d, audio %d\n",
            mlt_bridge_width(),
            mlt_bridge_height(),
            mlt_bridge_fps(),
            mlt_bridge_duration_ms(),
            mlt_bridge_display_aspect(),
            mlt_bridge_is_still(),
            mlt_bridge_has_audio()
        );

        check(
            mlt_bridge_width() > 0,
            "width reported"
        );

        check(
            mlt_bridge_duration_ms() > 0,
            "duration reported"
        );

        check(
            !mlt_bridge_is_playing(),
            "starts paused"
        );

        check_engine_isolation();

        printf("tractor\n");

        check(
            mlt_bridge_track_count() == 1,
            "primary movie starts as one track"
        );

        check(
            mlt_bridge_add_track(media_path),
            "second movie can be added to the tractor"
        );

        check(
            mlt_bridge_track_count() == 2,
            "tractor reports two tracks"
        );

        check(
            mlt_bridge_position_frame() == 0,
            "tractor rebuild preserves the parked playhead"
        );

        break;

    case 1:
        printf("play\n");

        check(
            mlt_bridge_play(),
            "play accepted"
        );

        check(
            mlt_bridge_is_playing(),
            "reports playing"
        );

        break;

    case 2:
        position_before_seek =
            mlt_bridge_position_ms();

        printf(
            "  position after ~1s: %" G_GINT64_FORMAT " ms\n",
            position_before_seek
        );

        check(
            position_before_seek > 200,
            "position advances while playing"
        );

        break;

    case 3:
        printf("seek while playing\n");

        check(
            mlt_bridge_seek_ms(4000),
            "seek accepted"
        );

        break;

    case 4:
        printf(
            "  position after seek: %" G_GINT64_FORMAT " ms\n",
            mlt_bridge_position_ms()
        );

        check(
            mlt_bridge_position_ms() > 3500,
            "position reflects the seek"
        );

        break;

    case 5:
        printf("pause\n");

        check(
            mlt_bridge_pause(),
            "pause accepted"
        );

        check(
            !mlt_bridge_is_playing(),
            "reports paused"
        );

        break;

    case 6: {
        const int64_t first =
            mlt_bridge_position_ms();

        printf(
            "  paused position: %" G_GINT64_FORMAT " ms\n",
            first
        );

        check(
            first == mlt_bridge_position_ms(),
            "position is stable while paused"
        );

        break;
    }

    case 7: {
        printf("seek while paused\n");

        check(
            mlt_bridge_seek_ms(1000),
            "millisecond seek accepted"
        );

        check(
            mlt_bridge_position_ms() >= 950 &&
                mlt_bridge_position_ms() <= 1100,
            "paused millisecond seek reports the requested position"
        );

        const int64_t target_frame =
            (int64_t)mlt_bridge_fps();

        check(
            mlt_bridge_seek_frame(target_frame),
            "frame-native seek accepted"
        );

        check(
            mlt_bridge_position_frame() == target_frame,
            "frame-native position round trips exactly"
        );

        break;
    }

    case 8:
        printf("volume\n");

        mlt_bridge_set_volume(0.25);

        check(
            mlt_bridge_volume() > 0.24 &&
                mlt_bridge_volume() < 0.26,
            "volume round trips"
        );

        mlt_bridge_set_volume(4.0);

        check(
            mlt_bridge_volume() == 1.0,
            "volume clamps at 1.0"
        );

        mlt_bridge_set_volume(1.0);

        break;

    case 9:
        printf("play to end\n");

        check(
            mlt_bridge_seek_ms(
                mlt_bridge_duration_ms() - 400),
            "seek near end"
        );

        check(
            mlt_bridge_play(),
            "play accepted"
        );

        break;

    case 10:
        printf(
            "  eof: %d, playing: %d\n",
            mlt_bridge_is_eof(),
            mlt_bridge_is_playing()
        );

        check(
            mlt_bridge_is_eof(),
            "end of file detected"
        );

        break;

    case 11:
        printf("replay from end\n");

        check(
            mlt_bridge_play(),
            "play after eof rewinds"
        );

        break;

    case 12:
        check(
            mlt_bridge_position_ms() <
                mlt_bridge_duration_ms() / 2,
            "playback restarted from the beginning"
        );

        break;

    case 13:
        printf("reopen the same file during playback\n");

        check(
            mlt_bridge_open(media_path),
            "reopen succeeds"
        );

        check(
            !mlt_bridge_is_playing(),
            "reopen leaves the player paused"
        );

        check(
            mlt_bridge_track_count() == 1,
            "opening a new movie resets the tractor to one track"
        );

        break;

    case 14:
        if (junk_path == NULL) {
            break;
        }

        printf("reject junk\n");

        check(
            !mlt_bridge_open(junk_path),
            "a non-media file is refused"
        );

        {
            char error[512];
            copy_last_error(error, (int)sizeof(error));

            printf(
                "  error: %s\n",
                error
            );

            check(
                error[0] != '\0',
                "an error message is reported"
            );
        }

        break;

    case 15:
        if (still_path == NULL) {
            break;
        }

        printf("still image\n");

        if (mlt_bridge_open(still_path)) {
            printf(
                "  still %d, duration %" G_GINT64_FORMAT
                " ms, frames %" G_GINT64_FORMAT "\n",
                mlt_bridge_is_still(),
                mlt_bridge_duration_ms(),
                mlt_bridge_duration_frames()
            );

            check(
                mlt_bridge_is_still(),
                "image is classified as a still"
            );

            check(
                mlt_bridge_duration_ms() == 0,
                "a still reports no timeline"
            );
        } else {
            char error[512];
            copy_last_error(error, (int)sizeof(error));

            printf(
                "  skipped, no image producer: %s\n",
                error
            );
        }

        break;

    case 16:
        printf("teardown\n");

        mlt_bridge_close_media();

        check(
            !mlt_bridge_is_playing(),
            "closed media is not playing"
        );

        check(
            mlt_bridge_position_ms() == 0,
            "closed media reports position zero"
        );

        mlt_bridge_engine_destroy(engine);
        engine = NULL;
        mlt_bridge_shutdown();

        printf(
            "\n%s (%d failures)\n",
            failures == 0 ? "PASS" : "FAIL",
            failures
        );

        g_main_loop_quit(loop);

        return G_SOURCE_REMOVE;

    default:
        g_main_loop_quit(loop);

        return G_SOURCE_REMOVE;
    }

    return G_SOURCE_CONTINUE;
}

int main(
    int argc,
    char **argv)
{
    if (argc < 2) {
        fprintf(
            stderr,
            "usage: %s <media> [non-media file] [still image]\n",
            argv[0]
        );

        return 2;
    }

    media_path = argv[1];
    junk_path = argc > 2 ? argv[2] : NULL;
    still_path = argc > 3 ? argv[3] : NULL;

    if (!mlt_bridge_init()) {
        char error[512];
        copy_last_error(error, (int)sizeof(error));

        fprintf(
            stderr,
            "MLT failed to initialize: %s\n",
            error
        );

        return 1;
    }

    engine = mlt_bridge_engine_create();

    if (engine == NULL ||
        !mlt_bridge_engine_activate(engine) ||
        !mlt_bridge_engine_set_texture_source(engine)) {
        char error[512];
        copy_last_error(error, (int)sizeof(error));

        fprintf(
            stderr,
            "MLT engine failed to initialize: %s\n",
            error
        );

        if (engine != NULL) {
            mlt_bridge_engine_destroy(engine);
            engine = NULL;
        }

        mlt_bridge_shutdown();
        return 1;
    }

    printf(
        "MLT %s\n\n",
        mlt_bridge_version()
    );

    loop =
        g_main_loop_new(NULL, FALSE);

    g_timeout_add(
        1000,
        run_step,
        NULL
    );

    g_main_loop_run(loop);

    g_main_loop_unref(loop);

    return failures == 0 ? 0 : 1;
}
