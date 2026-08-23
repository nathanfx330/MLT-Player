# tools/apply_poc10_timing_hardening.py
from pathlib import Path

bridge_path = Path("native/mlt_bridge.c")
text = bridge_path.read_text()


def require_once(haystack: str, needle: str, label: str) -> None:
    count = haystack.count(needle)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")


# Insert one shared Layer 2 placement/timing helper immediately before the
# export-graph builder. Preview and export keep separate MLT graphs, but they
# now share the exact rules that determine Layer 2 start, duration, held-still
# length, blank lead-in, and playlist insertion.
insert_marker = """/*
 * Build an export-only graph from a snapshot of the open movie. With one
 * layer this remains the original source-only path. With two layers it
"""
require_once(text, insert_marker, "shared-helper insertion marker")

shared_helper = r'''typedef enum _SecondaryPlacementResult {
    SECONDARY_PLACEMENT_OK = 0,
    SECONDARY_PLACEMENT_INVALID_REQUEST,
    SECONDARY_PLACEMENT_INVALID_SOURCE_LENGTH,
    SECONDARY_PLACEMENT_NO_ROOM,
    SECONDARY_PLACEMENT_SOURCE_INIT_FAILED,
    SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED,
    SECONDARY_PLACEMENT_LEAD_IN_FAILED,
    SECONDARY_PLACEMENT_APPEND_FAILED
} SecondaryPlacementResult;

/*
 * Build the Layer 2 offset playlist in exactly one place.
 *
 * The base movie remains duration-authoritative. Layer 2 is clamped to the
 * base range, held stills are extended only through the remaining base movie,
 * timed sources are clipped to the available room, and a real blank lead-in
 * represents placement after frame zero. Preview and export own independent
 * MLT objects but call this same policy function.
 */
static SecondaryPlacementResult build_secondary_playlist(
    mlt_profile target_profile,
    mlt_producer source,
    mlt_position start_frame,
    mlt_position base_length,
    int source_is_still,
    mlt_playlist *out_playlist,
    mlt_position *out_start)
{
    if (target_profile == NULL ||
        source == NULL ||
        out_playlist == NULL ||
        base_length <= 0) {
        return SECONDARY_PLACEMENT_INVALID_REQUEST;
    }

    *out_playlist = NULL;

    if (start_frame < 0) {
        start_frame = 0;
    }
    if (start_frame >= base_length) {
        start_frame = base_length - 1;
    }

    const mlt_position source_length =
        source_is_still
            ? 0
            : mlt_producer_get_length(source);

    if (!source_is_still && source_length <= 0) {
        return SECONDARY_PLACEMENT_INVALID_SOURCE_LENGTH;
    }

    const mlt_position available_length =
        base_length - start_frame;
    const mlt_position playtime =
        source_is_still
            ? available_length
            : (source_length < available_length
                   ? source_length
                   : available_length);

    if (playtime <= 0) {
        return SECONDARY_PLACEMENT_NO_ROOM;
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
        return SECONDARY_PLACEMENT_SOURCE_INIT_FAILED;
    }

    mlt_playlist playlist =
        mlt_playlist_new(target_profile);

    if (playlist == NULL) {
        return SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED;
    }

    if (start_frame > 0 &&
        mlt_playlist_blank(
            playlist,
            start_frame - 1) != 0) {
        mlt_playlist_close(playlist);
        return SECONDARY_PLACEMENT_LEAD_IN_FAILED;
    }

    if (mlt_playlist_append_io(
            playlist,
            source,
            0,
            source_out) != 0) {
        mlt_playlist_close(playlist);
        return SECONDARY_PLACEMENT_APPEND_FAILED;
    }

    *out_playlist = playlist;

    if (out_start != NULL) {
        *out_start = start_frame;
    }

    return SECONDARY_PLACEMENT_OK;
}

'''
text = text.replace(insert_marker, shared_helper + insert_marker, 1)

# Replace the export-side timing/playlist mirror.
export_fn = text.index("static int export_prepare_source_graph(")
export_start = text.index(
    "    mlt_position secondary_start =\n",
    export_fn,
)
export_end = text.index(
    "\n\n    if (job->export_secondary_has_audio &&",
    export_start,
)
export_old = text[export_start:export_end]
if "mlt_playlist_append_io" not in export_old or "secondary_playtime" not in export_old:
    raise SystemExit("export placement block did not match expected structure")

export_new = r'''    const SecondaryPlacementResult placement_result =
        build_secondary_playlist(
            graph->export_profile,
            graph->export_secondary,
            (mlt_position)job->export_secondary_start_frame,
            (mlt_position)source_length,
            job->export_secondary_is_still,
            &graph->export_secondary_playlist,
            NULL
        );

    if (placement_result != SECONDARY_PLACEMENT_OK) {
        switch (placement_result) {
            case SECONDARY_PLACEMENT_INVALID_SOURCE_LENGTH:
            case SECONDARY_PLACEMENT_NO_ROOM:
                export_set_failure(
                    failure,
                    failure_size,
                    "Layer 2 has no frames inside the base movie."
                );
                break;

            case SECONDARY_PLACEMENT_SOURCE_INIT_FAILED:
                export_set_failure(
                    failure,
                    failure_size,
                    "MLT could not initialize Layer 2 for export."
                );
                break;

            case SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED:
                export_set_failure(
                    failure,
                    failure_size,
                    "Could not create the Layer 2 export playlist."
                );
                break;

            case SECONDARY_PLACEMENT_LEAD_IN_FAILED:
                export_set_failure(
                    failure,
                    failure_size,
                    "Could not create the Layer 2 export lead-in."
                );
                break;

            case SECONDARY_PLACEMENT_APPEND_FAILED:
                export_set_failure(
                    failure,
                    failure_size,
                    "Could not place Layer 2 in the export composition."
                );
                break;

            default:
                export_set_failure(
                    failure,
                    failure_size,
                    "Layer 2 has invalid export placement."
                );
                break;
        }
        goto fail;
    }'''
text = text[:export_start] + export_new + text[export_end:]

# Replace the preview-side timing/playlist mirror.
preview_fn = text.index("int mlt_bridge_add_track(")
preview_start = text.index(
    "    const mlt_position secondary_length =\n",
    preview_fn,
)
preview_end = text.index(
    "\n\n    secondary_has_audio =",
    preview_start,
)
preview_old = text[preview_start:preview_end]
if "mlt_playlist_append_io" not in preview_old or "secondary_playtime" not in preview_old:
    raise SystemExit("preview placement block did not match expected structure")

preview_new = r'''    mlt_position pending_start = 0;

    const SecondaryPlacementResult placement_result =
        build_secondary_playlist(
            profile,
            pending_secondary,
            (mlt_position)start_frame,
            primary_length,
            secondary_still,
            &pending_secondary_playlist,
            &pending_start
        );

    if (placement_result != SECONDARY_PLACEMENT_OK) {
        switch (placement_result) {
            case SECONDARY_PLACEMENT_INVALID_SOURCE_LENGTH:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "The added video layer reports no usable duration."
                );
                break;

            case SECONDARY_PLACEMENT_NO_ROOM:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "There is no room for the added layer at that playhead."
                );
                break;

            case SECONDARY_PLACEMENT_SOURCE_INIT_FAILED:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "MLT could not initialize the added layer."
                );
                break;

            case SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "Could not create the offset playlist for layer 2."
                );
                break;

            case SECONDARY_PLACEMENT_LEAD_IN_FAILED:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "Could not create the blank lead-in for layer 2."
                );
                break;

            case SECONDARY_PLACEMENT_APPEND_FAILED:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "Could not place the added media on layer 2."
                );
                break;

            default:
                snprintf(
                    failure,
                    sizeof(failure),
                    "%s",
                    "The added layer has invalid placement."
                );
                break;
        }
        goto add_track_cleanup;
    }'''
text = text[:preview_start] + preview_new + text[preview_end:]

# Guard the central architectural intent: after the rewrite there must be one
# blank-lead-in writer and one append_io writer in the bridge, both inside the
# shared helper.
if text.count("mlt_playlist_blank(") != 1:
    raise SystemExit(
        f"expected one mlt_playlist_blank writer, found {text.count('mlt_playlist_blank(')}"
    )
if text.count("mlt_playlist_append_io(") != 1:
    raise SystemExit(
        f"expected one mlt_playlist_append_io writer, found {text.count('mlt_playlist_append_io(')}"
    )

bridge_path.write_text(text)

print("POC 10 timing hardening edits applied:")
print("  - one shared Layer 2 placement/timing helper")
print("  - one blank-lead-in implementation")
print("  - one held-still duration policy")
print("  - preview/export keep their own error messages")
print("\nNext: run tools/smoke.sh")
