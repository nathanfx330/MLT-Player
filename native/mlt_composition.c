/* native/mlt_composition.c */
#include "mlt_composition.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

int mlt_composition_secondary_base_size(
    mlt_profile target_profile,
    mlt_producer source,
    int source_is_still,
    double *out_width,
    double *out_height)
{
    if (target_profile == NULL ||
        source == NULL ||
        out_width == NULL ||
        out_height == NULL ||
        target_profile->width <= 0 ||
        target_profile->height <= 0) {
        return 0;
    }

    mlt_properties properties =
        MLT_PRODUCER_PROPERTIES(source);

    int source_width =
        mlt_properties_get_int(
            properties,
            "meta.media.width"
        );
    int source_height =
        mlt_properties_get_int(
            properties,
            "meta.media.height"
        );

    if (source_width <= 0) {
        source_width =
            mlt_properties_get_int(
                properties,
                "width"
            );
    }
    if (source_height <= 0) {
        source_height =
            mlt_properties_get_int(
                properties,
                "height"
            );
    }

    if (source_width <= 0 || source_height <= 0) {
        return 0;
    }

    double source_sar =
        mlt_properties_get_double(
            properties,
            "aspect_ratio"
        );
    if (!isfinite(source_sar) || source_sar <= 0.0) {
        source_sar = 1.0;
    }

    double output_sar =
        mlt_profile_sar(target_profile);
    if (!isfinite(output_sar) || output_sar <= 0.0) {
        output_sar = 1.0;
    }

    double display_width =
        (double)source_width *
        source_sar /
        output_sar;
    double display_height =
        (double)source_height;

    if (!isfinite(display_width) ||
        !isfinite(display_height) ||
        display_width <= 0.0 ||
        display_height <= 0.0) {
        return 0;
    }

    const double canvas_width =
        (double)target_profile->width;
    const double canvas_height =
        (double)target_profile->height;

    double fit =
        canvas_width / display_width;
    const double height_fit =
        canvas_height / display_height;

    if (height_fit < fit) {
        fit = height_fit;
    }

    if (source_is_still && fit > 1.0) {
        fit = 1.0;
    }

    if (!isfinite(fit) || fit <= 0.0) {
        return 0;
    }

    display_width *= fit;
    display_height *= fit;

    if (display_width < 1.0) {
        display_width = 1.0;
    }
    if (display_height < 1.0) {
        display_height = 1.0;
    }

    *out_width = display_width;
    *out_height = display_height;
    return 1;
}

MltSecondaryPlacementResult mlt_composition_build_secondary_playlist(
    mlt_profile target_profile,
    mlt_producer source,
    mlt_position start_frame,
    mlt_position base_length,
    int source_is_still,
    mlt_playlist *playlist_out,
    mlt_position *normalized_start_out)
{
    if (playlist_out == NULL) {
        return MLT_SECONDARY_PLACEMENT_INVALID_ARGUMENT;
    }

    *playlist_out = NULL;

    if (normalized_start_out != NULL) {
        *normalized_start_out = 0;
    }

    if (target_profile == NULL ||
        source == NULL ||
        base_length <= 0) {
        return MLT_SECONDARY_PLACEMENT_INVALID_ARGUMENT;
    }

    mlt_position normalized_start = start_frame;

    if (normalized_start < 0) {
        normalized_start = 0;
    }
    if (normalized_start >= base_length) {
        normalized_start = base_length - 1;
    }

    const mlt_position available_length =
        base_length - normalized_start;

    const mlt_position source_length =
        source_is_still
            ? 0
            : mlt_producer_get_length(source);

    if (!source_is_still &&
        source_length <= 0) {
        return MLT_SECONDARY_PLACEMENT_NO_DURATION;
    }

    const mlt_position playtime =
        source_is_still
            ? available_length
            : (source_length < available_length
                   ? source_length
                   : available_length);

    if (playtime <= 0) {
        return MLT_SECONDARY_PLACEMENT_NO_ROOM;
    }

    const mlt_position source_out =
        playtime - 1;

    if (source_is_still) {
        mlt_properties_set_position(
            MLT_PRODUCER_PROPERTIES(source),
            "length",
            playtime
        );
    }

    if (mlt_producer_set_in_and_out(
            source,
            0,
            source_out) != 0 ||
        mlt_producer_seek(source, 0) != 0 ||
        mlt_producer_set_speed(source, 0.0) != 0) {
        return MLT_SECONDARY_PLACEMENT_SOURCE_INIT_FAILED;
    }

    mlt_playlist playlist =
        mlt_playlist_new(target_profile);

    if (playlist == NULL) {
        return MLT_SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED;
    }

    if (normalized_start > 0 &&
        mlt_playlist_blank(
            playlist,
            normalized_start - 1) != 0) {
        mlt_playlist_close(playlist);
        return MLT_SECONDARY_PLACEMENT_LEAD_IN_FAILED;
    }

    if (mlt_playlist_append_io(
            playlist,
            source,
            0,
            source_out) != 0) {
        mlt_playlist_close(playlist);
        return MLT_SECONDARY_PLACEMENT_APPEND_FAILED;
    }

    *playlist_out = playlist;

    if (normalized_start_out != NULL) {
        *normalized_start_out = normalized_start;
    }

    return MLT_SECONDARY_PLACEMENT_OK;
}

int mlt_composition_set_geometry(
    mlt_transition transition,
    double x,
    double y,
    double width,
    double height,
    double opacity)
{
    if (transition == NULL ||
        !isfinite(x) ||
        !isfinite(y) ||
        !isfinite(width) ||
        !isfinite(height) ||
        !isfinite(opacity) ||
        width <= 0.0 ||
        height <= 0.0 ||
        opacity < 0.0 ||
        opacity > 1.0) {
        return 0;
    }

    char geometry[160];
    snprintf(
        geometry,
        sizeof(geometry),
        "%.6f/%.6f:%.6fx%.6f:%.6f",
        x,
        y,
        width,
        height,
        opacity
    );

    mlt_properties_set(
        MLT_TRANSITION_PROPERTIES(transition),
        "geometry",
        geometry
    );

    return 1;
}

int mlt_composition_configure_transition(
    mlt_transition transition,
    double x,
    double y,
    double width,
    double height,
    double opacity)
{
    if (transition == NULL) {
        return 0;
    }

    mlt_properties properties =
        MLT_TRANSITION_PROPERTIES(transition);

    mlt_properties_set_int(properties, "always_active", 1);
    mlt_properties_set_int(properties, "progressive", 1);
    mlt_properties_set_int(properties, "invert", 0);
    mlt_properties_set_int(properties, "aligned", 1);
    mlt_properties_set_int(properties, "fill", 1);
    mlt_properties_set_int(properties, "distort", 0);
    mlt_properties_set(properties, "halign", "left");
    mlt_properties_set(properties, "valign", "top");

    return mlt_composition_set_geometry(
        transition,
        x,
        y,
        width,
        height,
        opacity
    );
}

int mlt_composition_get_geometry(
    mlt_transition transition,
    double *x_out,
    double *y_out,
    double *width_out,
    double *height_out,
    double *opacity_out)
{
    if (transition == NULL ||
        x_out == NULL ||
        y_out == NULL ||
        width_out == NULL ||
        height_out == NULL ||
        opacity_out == NULL) {
        return 0;
    }

    const char *geometry =
        mlt_properties_get(
            MLT_TRANSITION_PROPERTIES(transition),
            "geometry"
        );

    if (geometry == NULL || geometry[0] == '\0') {
        return 0;
    }

    double x = 0.0;
    double y = 0.0;
    double width = 0.0;
    double height = 0.0;
    double opacity = 0.0;

    if (sscanf(
            geometry,
            "%lf/%lf:%lfx%lf:%lf",
            &x,
            &y,
            &width,
            &height,
            &opacity) != 5 ||
        !isfinite(x) ||
        !isfinite(y) ||
        !isfinite(width) ||
        !isfinite(height) ||
        !isfinite(opacity) ||
        width <= 0.0 ||
        height <= 0.0 ||
        opacity < 0.0 ||
        opacity > 1.0) {
        return 0;
    }

    *x_out = x;
    *y_out = y;
    *width_out = width;
    *height_out = height;
    *opacity_out = opacity;
    return 1;
}

static int alpha_unpremultiply_get_image(
    mlt_frame frame,
    uint8_t **image,
    mlt_image_format *format,
    int *width,
    int *height,
    int writable)
{
    (void)writable;

    mlt_filter filter =
        (mlt_filter)mlt_frame_pop_service(frame);

    const mlt_image_format requested_format =
        *format;

    *format = mlt_image_rgba;

    int error =
        mlt_frame_get_image(
            frame,
            image,
            format,
            width,
            height,
            1
        );

    if (error != 0 ||
        image == NULL ||
        *image == NULL ||
        *format != mlt_image_rgba ||
        *width <= 0 ||
        *height <= 0) {
        return error;
    }

    if (mlt_properties_get_int(
            MLT_FILTER_PROPERTIES(filter),
            "mlt_player_alpha_mode") != 2) {
        return error;
    }

    const size_t pixels =
        (size_t)(*width) * (size_t)(*height);

    for (size_t index = 0; index < pixels; index++) {
        uint8_t *pixel =
            *image + index * 4;
        const unsigned int alpha =
            pixel[3];

        if (alpha == 0) {
            pixel[0] = 0;
            pixel[1] = 0;
            pixel[2] = 0;
            continue;
        }

        if (alpha >= 255) {
            continue;
        }

        for (int channel = 0; channel < 3; channel++) {
            const unsigned int expanded =
                ((unsigned int)pixel[channel] * 255u + alpha / 2u) /
                alpha;
            pixel[channel] =
                (uint8_t)(expanded > 255u ? 255u : expanded);
        }
    }

    if (requested_format != mlt_image_none &&
        requested_format != mlt_image_movit &&
        requested_format != mlt_image_rgba) {
        if (frame->convert_image == NULL) {
            return 1;
        }

        error =
            frame->convert_image(
                frame,
                image,
                format,
                requested_format
            );
    }

    return error;
}

static mlt_frame alpha_interpret_process(
    mlt_filter filter,
    mlt_frame frame)
{
    mlt_frame_push_service(frame, filter);
    mlt_frame_push_get_image(
        frame,
        alpha_unpremultiply_get_image
    );
    return frame;
}

mlt_filter mlt_composition_attach_alpha_filter(
    mlt_producer target,
    int mode)
{
    if (target == NULL || mode < 0 || mode > 2) {
        return NULL;
    }

    mlt_filter filter =
        mlt_filter_new();

    if (filter == NULL) {
        return NULL;
    }

    filter->process =
        alpha_interpret_process;

    mlt_properties_set_int(
        MLT_FILTER_PROPERTIES(filter),
        "mlt_player_alpha_mode",
        mode
    );
    mlt_properties_set_int(
        MLT_FILTER_PROPERTIES(filter),
        "disable",
        mode == 2 ? 0 : 1
    );

    if (mlt_producer_attach(
            target,
            filter) != 0) {
        mlt_filter_close(filter);
        return NULL;
    }

    mlt_filter_close(filter);
    return filter;
}

int mlt_composition_apply_alpha_mode(
    mlt_filter filter,
    int mode)
{
    if (filter == NULL || mode < 0 || mode > 2) {
        return 0;
    }

    mlt_service_lock(
        MLT_FILTER_SERVICE(filter)
    );

    mlt_properties_set_int(
        MLT_FILTER_PROPERTIES(filter),
        "mlt_player_alpha_mode",
        mode
    );
    mlt_properties_set_int(
        MLT_FILTER_PROPERTIES(filter),
        "disable",
        mode == 2 ? 0 : 1
    );

    mlt_service_unlock(
        MLT_FILTER_SERVICE(filter)
    );

    return 1;
}
