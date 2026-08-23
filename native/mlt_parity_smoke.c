/* native/mlt_parity_smoke.c */

#include "mlt_bridge.h"
#include "mlt_parity.h"
#include "mlt_layer_api.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
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

static int nearly_equal(
    double a,
    double b,
    double tolerance)
{
    return isfinite(a) &&
        isfinite(b) &&
        fabs(a - b) <= tolerance;
}

static void print_state(
    const char *label,
    const MltCompositionDerivedState *state)
{
    printf(
        "  %s: %dx%d %.6f fps, length %lld, range %lld..%lld, "
        "L2 start %lld, L2 timeline %lld, base %.3fx%.3f, "
        "rect %.3f/%.3f %.3fx%.3f @ %.3f, gains %.3f/%.3f, "
        "still %d, alpha %d\n",
        label,
        state->profile_width,
        state->profile_height,
        state->profile_fps,
        (long long)state->composition_length,
        (long long)state->range_in_frame,
        (long long)state->range_out_frame,
        (long long)state->layer2_start_frame,
        (long long)state->layer2_timeline_length,
        state->layer2_base_width,
        state->layer2_base_height,
        state->layer2_x,
        state->layer2_y,
        state->layer2_width,
        state->layer2_height,
        state->layer2_opacity,
        state->base_audio_gain,
        state->layer2_audio_gain,
        state->layer2_is_still,
        state->layer2_alpha_mode
    );

    if (state->layer_count >= 3) {
        const MltCompositionLayerDerivedState *layer3 =
            &state->layers[MLT_COMPOSITION_SECOND_OVERLAY];
        printf(
            "      L3 start %lld, timeline %lld, base %.3fx%.3f, "
            "rect %.3f/%.3f %.3fx%.3f @ %.3f, gain %.3f, still %d, alpha %d\n",
            (long long)layer3->start_frame,
            (long long)layer3->timeline_length,
            layer3->base_width,
            layer3->base_height,
            layer3->x,
            layer3->y,
            layer3->width,
            layer3->height,
            layer3->opacity,
            layer3->audio_gain,
            layer3->is_still,
            layer3->alpha_mode
        );
    }
}

static void compare_indexed_layers(
    const MltCompositionDerivedState *preview,
    const MltCompositionDerivedState *exported)
{
    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        const MltCompositionLayerDerivedState *a = &preview->layers[index];
        const MltCompositionLayerDerivedState *b = &exported->layers[index];

        char label[96];
        snprintf(
            label,
            sizeof(label),
            "indexed Layer %d presence matches",
            index + 1
        );
        check(a->present == b->present, label);

        if (!a->present && !b->present) {
            continue;
        }

        snprintf(
            label,
            sizeof(label),
            "indexed Layer %d timing/type matches",
            index + 1
        );
        check(
            a->start_frame == b->start_frame &&
                a->timeline_length == b->timeline_length &&
                a->is_still == b->is_still &&
                a->alpha_mode == b->alpha_mode,
            label
        );

        snprintf(
            label,
            sizeof(label),
            "indexed Layer %d geometry matches",
            index + 1
        );
        check(
            nearly_equal(a->base_width, b->base_width, 0.000001) &&
                nearly_equal(a->base_height, b->base_height, 0.000001) &&
                nearly_equal(a->x, b->x, 0.000001) &&
                nearly_equal(a->y, b->y, 0.000001) &&
                nearly_equal(a->width, b->width, 0.000001) &&
                nearly_equal(a->height, b->height, 0.000001) &&
                nearly_equal(a->opacity, b->opacity, 0.000001),
            label
        );

        snprintf(
            label,
            sizeof(label),
            "indexed Layer %d audio matches",
            index + 1
        );
        check(
            a->has_audio == b->has_audio &&
                nearly_equal(a->audio_gain, b->audio_gain, 0.000001),
            label
        );
    }

    if (preview->layer_count >= 3 || exported->layer_count >= 3) {
        check(
            preview->layers[2].present && exported->layers[2].present,
            "Layer 3 is present in both preview and export"
        );
    } else {
        check(
            !preview->layers[2].present && !exported->layers[2].present,
            "unused Layer 3 slot stays empty"
        );
    }

    check(
        preview->layers[1].start_frame == preview->layer2_start_frame &&
            exported->layers[1].start_frame == exported->layer2_start_frame &&
            nearly_equal(
                preview->layers[1].opacity,
                preview->layer2_opacity,
                0.000001) &&
            nearly_equal(
                exported->layers[1].opacity,
                exported->layer2_opacity,
                0.000001),
        "indexed Layer 2 view matches the compatibility diagnostics"
    );
}

static void compare_states(
    const MltCompositionDerivedState *preview,
    const MltCompositionDerivedState *exported)
{
    check(
        preview->valid && exported->valid,
        "preview and export derived states are valid"
    );

    check(
        preview->layer_count == exported->layer_count,
        "layer count matches"
    );

    compare_indexed_layers(preview, exported);

    check(
        preview->profile_width == exported->profile_width &&
            preview->profile_height == exported->profile_height,
        "profile dimensions match"
    );

    check(
        nearly_equal(preview->profile_fps, exported->profile_fps, 0.000001),
        "profile frame rate matches"
    );

    check(
        preview->composition_length == exported->composition_length,
        "composition length matches"
    );

    check(
        preview->range_in_frame == exported->range_in_frame &&
            preview->range_out_frame == exported->range_out_frame,
        "normalized export range matches"
    );

    check(
        preview->layer2_start_frame == exported->layer2_start_frame,
        "normalized Layer 2 start matches"
    );

    check(
        preview->layer2_timeline_length == exported->layer2_timeline_length,
        "Layer 2 playlist length matches"
    );

    check(
        preview->layer2_is_still == exported->layer2_is_still,
        "Layer 2 timed/still classification matches"
    );

    check(
        preview->layer2_alpha_mode == exported->layer2_alpha_mode,
        "Layer 2 alpha mode matches"
    );

    check(
        nearly_equal(
            preview->layer2_base_width,
            exported->layer2_base_width,
            0.000001) &&
        nearly_equal(
            preview->layer2_base_height,
            exported->layer2_base_height,
            0.000001),
        "Layer 2 base presentation size matches"
    );

    check(
        nearly_equal(preview->layer2_x, exported->layer2_x, 0.000001) &&
            nearly_equal(preview->layer2_y, exported->layer2_y, 0.000001) &&
            nearly_equal(preview->layer2_width, exported->layer2_width, 0.000001) &&
            nearly_equal(preview->layer2_height, exported->layer2_height, 0.000001) &&
            nearly_equal(preview->layer2_opacity, exported->layer2_opacity, 0.000001),
        "Layer 2 composite rectangle and opacity match"
    );

    check(
        preview->base_has_audio == exported->base_has_audio &&
            preview->layer2_has_audio == exported->layer2_has_audio,
        "track audio presence matches"
    );

    check(
        nearly_equal(preview->base_audio_gain, exported->base_audio_gain, 0.000001) &&
            nearly_equal(preview->layer2_audio_gain, exported->layer2_audio_gain, 0.000001),
        "effective track gains match"
    );

    if (preview->layer2_is_still || exported->layer2_is_still) {
        check(
            preview->layer2_timeline_length == preview->composition_length &&
                exported->layer2_timeline_length == exported->composition_length,
            "held still reaches the composition final frame"
        );
    }
}

static int run_parity_check(
    int64_t in_frame,
    int64_t out_frame)
{
    MltCompositionDerivedState preview = {0};
    MltCompositionDerivedState exported = {0};
    char error[512] = "";

    const int derived =
        mlt_bridge_debug_composition_parity(
            in_frame,
            out_frame,
            &preview,
            &exported,
            error,
            (int)sizeof(error)
        );

    check(
        derived,
        "preview/export parity state can be derived"
    );

    if (!derived) {
        printf("  parity error: %s\n", error);
        return 0;
    }

    print_state("preview", &preview);
    print_state("export ", &exported);
    compare_states(&preview, &exported);
    return 1;
}

static int open_base(
    const char *media_path)
{
    check(
        mlt_bridge_open(media_path),
        "base movie opens"
    );

    return mlt_bridge_duration_frames() > 0;
}

static void run_timed_layer_case(
    const char *media_path)
{
    printf("timed-layer parity\n");

    if (!open_base(media_path)) {
        check(0, "base movie has a usable duration");
        return;
    }

    const int64_t length = mlt_bridge_duration_frames();
    const int64_t start = length > 60 ? 40 : length / 4;

    check(
        mlt_bridge_add_track(media_path, start),
        "timed Layer 2 can be added"
    );

    check(
        mlt_bridge_set_secondary_geometry(17.0, 23.0, 0.5),
        "timed Layer 2 geometry is configured"
    );

    check(
        mlt_bridge_set_secondary_opacity(0.35),
        "timed Layer 2 opacity is configured"
    );

    if (mlt_bridge_track_has_audio(0)) {
        check(
            mlt_bridge_set_track_audio_gain(0, 0.40),
            "base audio gain is configured"
        );
    }

    if (mlt_bridge_track_has_audio(1)) {
        check(
            mlt_bridge_set_track_audio_gain(1, 0.25),
            "Layer 2 audio gain is configured"
        );
    }

    const int64_t in_frame = length > 20 ? 5 : 0;
    const int64_t out_frame = length > 20 ? length - 7 : length - 1;

    if (run_parity_check(in_frame, out_frame)) {
        check(
            !mlt_bridge_secondary_is_still(),
            "timed fixture remains timed in preview"
        );
    }
}

static void run_still_layer_case(
    const char *media_path,
    const char *still_path)
{
    if (still_path == NULL || still_path[0] == '\0') {
        return;
    }

    printf("still-layer parity\n");

    if (!open_base(media_path)) {
        check(0, "base movie reopens for still parity");
        return;
    }

    const int64_t length = mlt_bridge_duration_frames();
    const int64_t start = length > 60 ? 40 : length / 4;

    check(
        mlt_bridge_add_track(still_path, start),
        "still Layer 2 can be added"
    );

    check(
        mlt_bridge_set_secondary_geometry(48.0, 24.0, 0.5),
        "still Layer 2 geometry is configured"
    );

    check(
        mlt_bridge_set_secondary_opacity(0.60),
        "still Layer 2 opacity is configured"
    );

    check(
        mlt_bridge_set_secondary_alpha_mode(2),
        "still Layer 2 uses a non-default alpha mode"
    );

    if (mlt_bridge_track_has_audio(0)) {
        check(
            mlt_bridge_set_track_audio_gain(0, 0.55),
            "base audio gain is changed for still parity"
        );
    }

    if (run_parity_check(0, length - 1)) {
        check(
            mlt_bridge_secondary_is_still(),
            "still fixture remains a held still in preview"
        );
    }
}

static void run_three_layer_timed_case(
    const char *media_path)
{
    printf("three-layer timed parity\n");

    if (!open_base(media_path)) {
        check(0, "base movie reopens for three-layer timed parity");
        return;
    }

    const int64_t length = mlt_bridge_duration_frames();
    const int64_t start2 = length > 80 ? 25 : length / 5;
    const int64_t start3 = length > 100 ? 55 : length / 2;

    check(
        mlt_bridge_add_track(media_path, start2),
        "timed Layer 2 can be added for three-layer parity"
    );
    check(
        mlt_bridge_set_secondary_geometry(31.0, 19.0, 0.70),
        "Layer 2 keeps independent geometry before Layer 3"
    );
    check(
        mlt_bridge_set_secondary_opacity(0.45),
        "Layer 2 keeps independent opacity before Layer 3"
    );

    check(
        mlt_bridge_add_track(media_path, start3),
        "timed Layer 3 can be added"
    );
    check(
        mlt_bridge_track_count() == 3,
        "preview tractor reports three layers"
    );
    check(
        !mlt_bridge_add_track(media_path, start3),
        "a fourth layer is rejected without disturbing the composition"
    );
    check(
        mlt_bridge_track_count() == 3,
        "rejected fourth layer leaves the three-layer tractor intact"
    );
    check(
        mlt_bridge_layer_start_frame(2) == start3,
        "Layer 3 records its exact insertion frame"
    );
    check(
        mlt_bridge_set_layer_geometry(2, 73.0, 41.0, 0.40),
        "Layer 3 accepts independent geometry"
    );
    check(
        mlt_bridge_set_layer_opacity(2, 0.65),
        "Layer 3 accepts independent opacity"
    );

    if (mlt_bridge_track_has_audio(0)) {
        check(mlt_bridge_set_track_audio_gain(0, 0.80), "Layer 1 gain is configured");
    }
    if (mlt_bridge_track_has_audio(1)) {
        check(mlt_bridge_set_track_audio_gain(1, 0.50), "Layer 2 gain is configured");
    }
    if (mlt_bridge_track_has_audio(2)) {
        check(mlt_bridge_set_track_audio_gain(2, 0.30), "Layer 3 gain is configured");
    }

    if (run_parity_check(3, length - 4)) {
        check(
            !mlt_bridge_layer_is_still(2),
            "timed Layer 3 remains timed in preview"
        );
    }
}

static void run_three_layer_still_case(
    const char *media_path,
    const char *still_path)
{
    if (still_path == NULL || still_path[0] == '\0') {
        return;
    }

    printf("three-layer still parity\n");

    if (!open_base(media_path)) {
        check(0, "base movie reopens for three-layer still parity");
        return;
    }

    const int64_t length = mlt_bridge_duration_frames();
    const int64_t start2 = length > 80 ? 20 : length / 5;
    const int64_t start3 = length > 100 ? 60 : length / 2;

    check(
        mlt_bridge_add_track(media_path, start2),
        "timed Layer 2 can be added under a still Layer 3"
    );
    check(
        mlt_bridge_add_track(still_path, start3),
        "still Layer 3 can be added"
    );
    check(
        mlt_bridge_layer_is_still(2),
        "Layer 3 is classified as a held still"
    );
    check(
        mlt_bridge_layer_has_alpha(2),
        "Layer 3 alpha is detected"
    );
    check(
        mlt_bridge_set_layer_geometry(2, 82.0, 36.0, 0.35),
        "still Layer 3 accepts independent geometry"
    );
    check(
        mlt_bridge_set_layer_opacity(2, 0.52),
        "still Layer 3 accepts independent opacity"
    );
    check(
        mlt_bridge_set_layer_alpha_mode(2, 2),
        "still Layer 3 accepts premultiplied alpha mode"
    );
    check(
        mlt_bridge_layer_alpha_mode(2) == 2,
        "Layer 3 alpha mode round trips"
    );

    if (run_parity_check(0, length - 1)) {
        MltCompositionDerivedState preview = {0};
        MltCompositionDerivedState exported = {0};
        char error[512] = "";
        if (mlt_bridge_debug_composition_parity(
                0,
                length - 1,
                &preview,
                &exported,
                error,
                (int)sizeof(error))) {
            check(
                preview.layers[2].timeline_length == preview.composition_length &&
                    exported.layers[2].timeline_length == exported.composition_length,
                "held Layer 3 reaches the composition final frame"
            );
        }
    }
}

int main(
    int argc,
    char **argv)
{
    if (argc < 2) {
        fprintf(
            stderr,
            "usage: %s <media> [alpha-still.png]\n",
            argv[0]
        );
        return 2;
    }

    const char *media_path = argv[1];
    const char *still_path = argc > 2 ? argv[2] : NULL;

    if (!mlt_bridge_init()) {
        fprintf(stderr, "MLT failed to initialize.\n");
        return 1;
    }

    MltBridgeEngine *engine = mlt_bridge_engine_create();

    if (engine == NULL ||
        !mlt_bridge_engine_activate(engine)) {
        fprintf(stderr, "MLT parity engine failed to initialize.\n");

        if (engine != NULL) {
            mlt_bridge_engine_destroy(engine);
        }

        mlt_bridge_shutdown();
        return 1;
    }

    printf("\npreview/export parity\n");

    run_timed_layer_case(media_path);
    run_still_layer_case(media_path, still_path);
    run_three_layer_timed_case(media_path);
    run_three_layer_still_case(media_path, still_path);

    mlt_bridge_close_media();
    mlt_bridge_engine_destroy(engine);
    mlt_bridge_shutdown();

    printf(
        "\n%s parity (%d failures)\n",
        failures == 0 ? "PASS" : "FAIL",
        failures
    );

    return failures == 0 ? 0 : 1;
}
