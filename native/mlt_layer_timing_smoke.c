/* native/mlt_layer_timing_smoke.c */

#include "mlt_bridge.h"
#include "mlt_layer_api.h"
#include "mlt_parity.h"

#include <stdint.h>
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

static int states_match_timing(
    const MltCompositionDerivedState *preview,
    const MltCompositionDerivedState *exported,
    int layer_index)
{
    const MltCompositionLayerDerivedState *a =
        &preview->layers[layer_index];
    const MltCompositionLayerDerivedState *b =
        &exported->layers[layer_index];

    return a->present &&
        b->present &&
        a->start_frame == b->start_frame &&
        a->timeline_length == b->timeline_length;
}

int main(
    int argc,
    char **argv)
{
    if (argc < 2) {
        fprintf(
            stderr,
            "usage: %s media-file\n",
            argv[0]
        );
        return 2;
    }

    const char *media_path = argv[1];

    printf("layer timing\n");

    check(mlt_bridge_init(), "MLT initializes");

    MltBridgeEngine *engine =
        mlt_bridge_engine_create();
    check(engine != NULL, "engine can be created");

    if (engine == NULL) {
        printf("\nFAIL layer timing (%d failures)\n", failures);
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

    const int64_t length =
        mlt_bridge_duration_frames();
    check(length >= 120, "test media has enough timeline for bounded layers");

    check(
        !mlt_bridge_add_track_bounded(
            media_path,
            80,
            60
        ),
        "reversed Layer 2 timing is rejected"
    );
    check(
        mlt_bridge_track_count() == 1,
        "rejected timing leaves the one-layer composition intact"
    );

    check(
        mlt_bridge_add_track_bounded(
            media_path,
            25,
            74
        ),
        "Layer 2 can be added with explicit start and end"
    );
    check(
        mlt_bridge_layer_start_frame(1) == 25,
        "Layer 2 start frame round trips exactly"
    );
    check(
        mlt_bridge_layer_end_frame(1) == 74,
        "Layer 2 end frame round trips exactly"
    );

    check(
        mlt_bridge_add_layer_with_state(
            2,
            media_path,
            60,
            99,
            0.0,
            0.0,
            1.0,
            0.65,
            0,
            0.35
        ),
        "Layer 3 stateful restore accepts bounded timing"
    );
    check(
        mlt_bridge_track_count() == 3,
        "bounded Layer 3 produces a three-layer tractor"
    );
    check(
        mlt_bridge_layer_start_frame(2) == 60,
        "Layer 3 start frame round trips exactly"
    );
    check(
        mlt_bridge_layer_end_frame(2) == 99,
        "Layer 3 end frame round trips exactly"
    );

    MltCompositionDerivedState preview;
    MltCompositionDerivedState exported;
    char error[512];

    memset(&preview, 0, sizeof(preview));
    memset(&exported, 0, sizeof(exported));
    memset(error, 0, sizeof(error));

    const int parity_ok =
        mlt_bridge_debug_composition_parity(
            0,
            length - 1,
            &preview,
            &exported,
            error,
            (int)sizeof(error)
        );

    if (!parity_ok && error[0] != '\0') {
        fprintf(stderr, "  parity error: %s\n", error);
    }

    check(
        parity_ok,
        "preview/export parity can be derived for bounded layers"
    );

    if (parity_ok) {
        check(
            states_match_timing(&preview, &exported, 1),
            "Layer 2 timing matches between preview and export"
        );
        check(
            preview.layers[1].start_frame == 25 &&
                preview.layers[1].timeline_length == 75,
            "Layer 2 occupies timeline frames 25 through 74"
        );
        check(
            states_match_timing(&preview, &exported, 2),
            "Layer 3 timing matches between preview and export"
        );
        check(
            preview.layers[2].start_frame == 60 &&
                preview.layers[2].timeline_length == 100,
            "Layer 3 occupies timeline frames 60 through 99"
        );
    }

    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    printf(
        "\n%s layer timing (%d failures)\n",
        failures == 0 ? "PASS" : "FAIL",
        failures
    );

    return failures == 0 ? 0 : 1;
}
