/* native/mlt_layer_order_smoke.c */

#include "mlt_bridge.h"
#include "mlt_layer_api.h"
#include "mlt_parity.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;

static void check(int condition, const char *description)
{
    printf("  [%s] %s\n", condition ? "ok" : "FAIL", description);
    if (!condition) {
        failures++;
    }
}

static int near_value(double a, double b)
{
    return fabs(a - b) < 0.000001;
}

static int visual_order_matches(
    const MltCompositionDerivedState *state,
    int bottom,
    int middle,
    int top)
{
    return state->visual_order[0] == bottom &&
        state->visual_order[1] == middle &&
        state->visual_order[2] == top;
}

static int parity_layer_matches(
    const MltCompositionDerivedState *preview,
    const MltCompositionDerivedState *exported,
    int layer_index)
{
    const MltCompositionLayerDerivedState *a = &preview->layers[layer_index];
    const MltCompositionLayerDerivedState *b = &exported->layers[layer_index];

    return a->present == b->present &&
        a->start_frame == b->start_frame &&
        a->timeline_length == b->timeline_length &&
        a->source_in_frame == b->source_in_frame &&
        a->source_out_frame == b->source_out_frame &&
        near_value(a->x, b->x) &&
        near_value(a->y, b->y) &&
        near_value(a->width, b->width) &&
        near_value(a->height, b->height) &&
        near_value(a->opacity, b->opacity) &&
        a->has_audio == b->has_audio &&
        near_value(a->audio_gain, b->audio_gain);
}

static int derive_parity(
    int64_t length,
    MltCompositionDerivedState *preview,
    MltCompositionDerivedState *exported)
{
    char error[512] = "";
    memset(preview, 0, sizeof(*preview));
    memset(exported, 0, sizeof(*exported));

    const int ok = mlt_bridge_debug_composition_parity(
        0,
        length - 1,
        preview,
        exported,
        error,
        (int)sizeof(error)
    );
    if (!ok && error[0] != '\0') {
        fprintf(stderr, "  parity error: %s\n", error);
    }
    return ok;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s media-file\n", argv[0]);
        return 2;
    }

    const char *media_path = argv[1];

    const int64_t a_start = 20;
    const int64_t a_end = 64;
    const int64_t a_source_in = 5;
    const int64_t a_source_out = 49;
    const double a_x = 11.0;
    const double a_y = 19.0;
    const double a_scale = 0.55;
    const double a_opacity = 0.35;
    const double a_audio = 0.25;

    const int64_t b_start = 70;
    const int64_t b_end = 109;
    const int64_t b_source_in = 15;
    const int64_t b_source_out = 54;
    const double b_x = 73.0;
    const double b_y = 41.0;
    const double b_scale = 0.78;
    const double b_opacity = 0.82;
    const double b_audio = 0.65;

    printf("layer order\n");

    check(mlt_bridge_init(), "MLT initializes");

    MltBridgeEngine *engine = mlt_bridge_engine_create();
    check(engine != NULL, "engine can be created");

    if (engine == NULL) {
        printf("\nFAIL layer order (%d failures)\n", failures);
        mlt_bridge_shutdown();
        return 1;
    }

    check(mlt_bridge_engine_activate(engine), "engine can be activated");
    check(mlt_bridge_open(media_path), "test media opens");

    const int64_t length = mlt_bridge_duration_frames();
    check(length >= 120, "test media has enough frames for distinct layer states");

    check(
        mlt_bridge_add_track_bounded_source(
            media_path,
            a_start,
            a_end,
            a_source_in,
            a_source_out
        ),
        "Layer 2 can be built"
    );
    check(
        mlt_bridge_set_layer_geometry(1, a_x, a_y, a_scale) &&
            mlt_bridge_set_layer_opacity(1, a_opacity) &&
            mlt_bridge_set_track_audio_gain(1, a_audio),
        "Layer 2 gets distinct geometry, opacity, and audio"
    );
    check(
        mlt_bridge_set_layer_visual_order(1, 0, 2),
        "Layer 1 can move above Layer 2 in a two-layer composition"
    );
    check(
        mlt_bridge_layer_visual_position(0) == 1 &&
            mlt_bridge_layer_visual_position(1) == 0,
        "two-layer base reorder round trips before Layer 3 exists"
    );

    MltCompositionDerivedState preview;
    MltCompositionDerivedState exported;
    check(
        derive_parity(length, &preview, &exported),
        "preview/export parity survives two-layer base reorder"
    );
    check(
        visual_order_matches(&preview, 1, 0, 2) &&
            visual_order_matches(&exported, 1, 0, 2),
        "two-layer preview and export carry the same full Z-order permutation"
    );

    check(
        mlt_bridge_add_layer_with_state_trimmed(
            2,
            media_path,
            b_start,
            b_end,
            b_source_in,
            b_source_out,
            b_x,
            b_y,
            b_scale,
            b_opacity,
            0,
            b_audio
        ),
        "Layer 3 can be added after an existing base reorder"
    );
    check(mlt_bridge_track_count() == 3, "three logical layers are present");
    check(
        mlt_bridge_set_layer_visual_order(1, 0, 2),
        "new Layer 3 can become top while the prior Layer 2/base relationship survives"
    );
    check(
        mlt_bridge_layer_visual_position(1) == 0 &&
            mlt_bridge_layer_visual_position(0) == 1 &&
            mlt_bridge_layer_visual_position(2) == 2,
        "adding Layer 3 preserves the requested two-layer relationship"
    );

    check(
        mlt_bridge_set_layer_visual_order(0, 2, 1),
        "Layer 2 can move visually above Layer 3 without swapping logical slots"
    );
    check(
        mlt_bridge_layer_visual_position(0) == 0 &&
            mlt_bridge_layer_visual_position(1) == 2 &&
            mlt_bridge_layer_visual_position(2) == 1,
        "overlay visual positions round trip"
    );
    check(
        mlt_bridge_layer_start_frame(1) == a_start &&
            mlt_bridge_layer_source_in_frame(1) == a_source_in &&
            near_value(mlt_bridge_layer_x(1), a_x) &&
            near_value(mlt_bridge_layer_opacity(1), a_opacity) &&
            near_value(mlt_bridge_track_audio_gain(1), a_audio),
        "Layer 2 keeps its complete logical state after visual reorder"
    );
    check(
        mlt_bridge_layer_start_frame(2) == b_start &&
            mlt_bridge_layer_source_in_frame(2) == b_source_in &&
            near_value(mlt_bridge_layer_x(2), b_x) &&
            near_value(mlt_bridge_layer_opacity(2), b_opacity) &&
            near_value(mlt_bridge_track_audio_gain(2), b_audio),
        "Layer 3 keeps its complete logical state after visual reorder"
    );

    check(
        derive_parity(length, &preview, &exported),
        "preview/export parity can be derived after overlay Z-order change"
    );
    check(
        visual_order_matches(&preview, 0, 2, 1) &&
            visual_order_matches(&exported, 0, 2, 1),
        "preview and export carry the same overlay Z-order"
    );
    check(
        parity_layer_matches(&preview, &exported, 1) &&
            parity_layer_matches(&preview, &exported, 2),
        "logical overlay state still matches between preview and export"
    );

    check(
        mlt_bridge_set_layer_visual_order(1, 0, 2),
        "Layer 1 can move visually above Layer 2 while remaining logical base"
    );
    check(
        mlt_bridge_layer_visual_position(0) == 1 &&
            mlt_bridge_layer_visual_position(1) == 0 &&
            mlt_bridge_layer_visual_position(2) == 2,
        "base-middle visual positions round trip"
    );
    check(
        mlt_bridge_duration_frames() == length &&
            mlt_bridge_layer_start_frame(0) == 0,
        "Layer 1 still owns frame zero and movie duration after moving visually"
    );
    check(
        derive_parity(length, &preview, &exported),
        "preview/export parity survives Layer 1 in the middle"
    );
    check(
        visual_order_matches(&preview, 1, 0, 2) &&
            visual_order_matches(&exported, 1, 0, 2),
        "preview and export agree with Layer 1 in the middle"
    );

    check(
        mlt_bridge_set_layer_visual_order(1, 2, 0),
        "Layer 1 can move to the visual top"
    );
    check(
        mlt_bridge_layer_visual_position(0) == 2,
        "Layer 1 reports the top visual position"
    );
    check(
        derive_parity(length, &preview, &exported),
        "preview/export parity survives Layer 1 on top"
    );
    check(
        visual_order_matches(&preview, 1, 2, 0) &&
            visual_order_matches(&exported, 1, 2, 0),
        "preview and export agree with Layer 1 on top"
    );
    check(
        parity_layer_matches(&preview, &exported, 0) &&
            parity_layer_matches(&preview, &exported, 1) &&
            parity_layer_matches(&preview, &exported, 2),
        "all logical layer state remains parity-clean with reordered base"
    );

    check(
        !mlt_bridge_set_layer_visual_order(0, 0, 2),
        "invalid duplicate visual order is rejected"
    );
    check(
        mlt_bridge_track_count() == 3 &&
            mlt_bridge_layer_visual_position(0) == 2,
        "rejected order leaves the existing composition intact"
    );

    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    printf(
        "\n%s layer order (%d failures)\n",
        failures == 0 ? "PASS" : "FAIL",
        failures
    );

    return failures == 0 ? 0 : 1;
}
