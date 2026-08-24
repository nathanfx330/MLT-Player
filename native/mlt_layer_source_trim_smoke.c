/* native/mlt_layer_source_trim_smoke.c */

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

static int states_match_source_range(
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
        a->timeline_length == b->timeline_length &&
        a->source_in_frame == b->source_in_frame &&
        a->source_out_frame == b->source_out_frame;
}

int main(
    int argc,
    char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s media-file\n", argv[0]);
        return 2;
    }

    const char *media_path = argv[1];

    printf("layer source trim\n");

    check(mlt_bridge_init(), "MLT initializes");

    MltBridgeEngine *engine = mlt_bridge_engine_create();
    check(engine != NULL, "engine can be created");

    if (engine == NULL) {
        printf("\nFAIL layer source trim (%d failures)\n", failures);
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

    const int64_t length = mlt_bridge_duration_frames();
    check(length >= 120, "test media has enough source and timeline frames");

    check(
        !mlt_bridge_add_track_bounded_source(
            media_path,
            20,
            49,
            50,
            40
        ),
        "reversed Layer 2 source range is rejected"
    );
    check(
        mlt_bridge_track_count() == 1,
        "rejected source range leaves the one-layer composition intact"
    );

    check(
        mlt_bridge_add_track_bounded_source(
            media_path,
            20,
            49,
            30,
            99
        ),
        "Layer 2 accepts independent timeline and source ranges"
    );
    check(
        mlt_bridge_layer_start_frame(1) == 20,
        "Layer 2 timeline start round trips exactly"
    );
    check(
        mlt_bridge_layer_end_frame(1) == 49,
        "Layer 2 timeline end remains capped by its placement window"
    );
    check(
        mlt_bridge_layer_source_in_frame(1) == 30,
        "Layer 2 source In round trips exactly"
    );
    check(
        mlt_bridge_layer_source_out_frame(1) == 99,
        "Layer 2 preserves source Out beyond the shorter timeline window"
    );
    check(
        mlt_bridge_layer_source_length_frames(1) >= 100,
        "Layer 2 reports its full source length"
    );

    check(
        mlt_bridge_add_layer_with_state_trimmed(
            2,
            media_path,
            80,
            119,
            10,
            29,
            0.0,
            0.0,
            1.0,
            0.65,
            0,
            0.35
        ),
        "Layer 3 stateful restore accepts a trimmed source range"
    );
    check(
        mlt_bridge_track_count() == 3,
        "trimmed Layer 3 produces a three-layer tractor"
    );
    check(
        mlt_bridge_layer_start_frame(2) == 80,
        "Layer 3 timeline start round trips exactly"
    );
    check(
        mlt_bridge_layer_end_frame(2) == 99,
        "Layer 3 ends when its shorter selected source range ends"
    );
    check(
        mlt_bridge_layer_source_in_frame(2) == 10,
        "Layer 3 source In round trips exactly"
    );
    check(
        mlt_bridge_layer_source_out_frame(2) == 29,
        "Layer 3 source Out round trips exactly"
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
        "preview/export parity can be derived for source-trimmed layers"
    );

    if (parity_ok) {
        check(
            states_match_source_range(&preview, &exported, 1),
            "Layer 2 source range matches between preview and export"
        );
        check(
            preview.layers[1].source_in_frame == 30 &&
                preview.layers[1].source_out_frame == 99 &&
                preview.layers[1].start_frame == 20 &&
                preview.layers[1].timeline_length == 50,
            "Layer 2 keeps source 30..99 inside timeline 20..49"
        );
        check(
            states_match_source_range(&preview, &exported, 2),
            "Layer 3 source range matches between preview and export"
        );
        check(
            preview.layers[2].source_in_frame == 10 &&
                preview.layers[2].source_out_frame == 29 &&
                preview.layers[2].start_frame == 80 &&
                preview.layers[2].timeline_length == 100,
            "Layer 3 keeps source 10..29 and naturally ends at timeline frame 99"
        );
    }

    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    printf(
        "\n%s layer source trim (%d failures)\n",
        failures == 0 ? "PASS" : "FAIL",
        failures
    );

    return failures == 0 ? 0 : 1;
}
