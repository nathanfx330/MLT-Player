/* native/mlt_thumbnail_smoke.c */

#include "mlt_bridge.h"
#include "mlt_thumbnail.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib.h>
#include <glib/gstdio.h>

#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>

static int failures = 0;

static void check(int condition, const char *message)
{
    if (condition) {
        printf("  [ok] %s\n", message);
    } else {
        printf("  [FAIL] %s\n", message);
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

static void check_jpeg_geometry(
    const char *path,
    int expected_width,
    int expected_height)
{
    GError *error = NULL;
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file(path, &error);

    check(pixbuf != NULL, "generated thumbnail is a readable image");

    if (pixbuf != NULL) {
        check(
            gdk_pixbuf_get_width(pixbuf) == expected_width,
            "generated thumbnail has the requested width"
        );
        check(
            gdk_pixbuf_get_height(pixbuf) == expected_height,
            "generated thumbnail has the requested height"
        );
        g_object_unref(pixbuf);
    }

    if (error != NULL) {
        g_error_free(error);
    }
}

typedef struct _ConcurrentThumbnailJob {
    const char *source_path;
    char *output_path;
    int succeeded;
    int64_t selected_frame;
    char error[512];
} ConcurrentThumbnailJob;

static gpointer run_concurrent_thumbnail(gpointer data)
{
    ConcurrentThumbnailJob *job = (ConcurrentThumbnailJob *)data;

    job->selected_frame = -1;
    job->error[0] = '\0';
    job->succeeded = mlt_thumbnail_generate(
        job->source_path,
        job->output_path,
        480,
        270,
        &job->selected_frame,
        job->error,
        (int)sizeof(job->error)
    );

    return NULL;
}

static void check_concurrent_generation(
    const char *video_path,
    const char *video_output)
{
    enum { JOB_COUNT = 4 };
    ConcurrentThumbnailJob jobs[JOB_COUNT];
    GThread *threads[JOB_COUNT] = {NULL, NULL, NULL, NULL};

    for (int index = 0; index < JOB_COUNT; index++) {
        jobs[index].source_path = video_path;
        jobs[index].output_path =
            g_strdup_printf("%s.concurrent-%d.jpg", video_output, index);
        jobs[index].succeeded = 0;
        jobs[index].selected_frame = -1;
        jobs[index].error[0] = '\0';

        threads[index] = g_thread_new(
            "thumbnail-smoke-worker",
            run_concurrent_thumbnail,
            &jobs[index]
        );
    }

    int all_succeeded = 1;
    int all_outputs = 1;
    int all_representative = 1;

    for (int index = 0; index < JOB_COUNT; index++) {
        if (threads[index] != NULL) {
            g_thread_join(threads[index]);
        } else {
            all_succeeded = 0;
        }

        if (!jobs[index].succeeded) {
            all_succeeded = 0;
            if (jobs[index].error[0] != '\0') {
                fprintf(
                    stderr,
                    "  concurrent thumbnail %d error: %s\n",
                    index,
                    jobs[index].error
                );
            }
        }

        if (!file_has_data(jobs[index].output_path)) {
            all_outputs = 0;
        }

        if (jobs[index].selected_frame < 50) {
            all_representative = 0;
        }
    }

    check(
        all_succeeded,
        "concurrent callers complete safely through serialized native generation"
    );
    check(
        all_outputs,
        "concurrent callers each publish a thumbnail"
    );
    check(
        all_representative,
        "concurrent callers retain representative-frame selection"
    );

    for (int index = 0; index < JOB_COUNT; index++) {
        if (jobs[index].output_path != NULL) {
            remove(jobs[index].output_path);
            g_free(jobs[index].output_path);
        }
    }
}

static void check_storyboard_batch_generation(const char *video_path)
{
    GError *directory_error = NULL;
    char *batch_directory =
        g_dir_make_tmp("mlt-thumbnail-batch-XXXXXX", &directory_error);

    check(
        batch_directory != NULL,
        "storyboard batch temporary directory is created"
    );

    if (batch_directory == NULL) {
        if (directory_error != NULL) {
            fprintf(stderr, "  batch directory error: %s\n", directory_error->message);
            g_error_free(directory_error);
        }
        return;
    }

    if (directory_error != NULL) {
        g_error_free(directory_error);
    }

    const int64_t frames[] = {25, 75, 125};
    char error[512] = {0};
    int generated_count = 0;

    const int batch_ok = mlt_thumbnail_generate_frame_batch(
        video_path,
        batch_directory,
        256,
        144,
        frames,
        (int)(sizeof(frames) / sizeof(frames[0])),
        &generated_count,
        error,
        (int)sizeof(error)
    );

    if (!batch_ok && error[0] != '\0') {
        fprintf(stderr, "  storyboard batch error: %s\n", error);
    }

    check(batch_ok != 0, "storyboard batch opens one MLT generation session");
    check(generated_count == 3, "storyboard batch publishes every requested frame");

    int all_outputs = 1;
    for (int index = 0; index < 3; index++) {
        char *path = g_strdup_printf("%s%c%d.jpg", batch_directory, G_DIR_SEPARATOR, index);
        if (path == NULL || !file_has_data(path)) {
            all_outputs = 0;
        }
        if (path != NULL && file_has_data(path)) {
            check_jpeg_geometry(path, 256, 144);
            g_remove(path);
        }
        g_free(path);
    }

    check(all_outputs, "storyboard batch atomically publishes indexed JPEG outputs");
    check(
        g_rmdir(batch_directory) == 0,
        "storyboard batch temporary directory cleans up"
    );
    g_free(batch_directory);
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(
            stderr,
            "usage: %s <video> <still> <video-jpeg> <still-jpeg>\n",
            argv[0]
        );
        return 2;
    }

    const char *video_path = argv[1];
    const char *still_path = argv[2];
    const char *video_output = argv[3];
    const char *still_output = argv[4];

    printf("MLT-native thumbnail smoke\n");

    check(mlt_bridge_init() != 0, "MLT initializes");

    char error[512] = {0};
    int64_t selected_frame = -1;

    const int video_ok = mlt_thumbnail_generate(
        video_path,
        video_output,
        480,
        270,
        &selected_frame,
        error,
        (int)sizeof(error)
    );

    if (!video_ok && error[0] != '\0') {
        fprintf(stderr, "  video thumbnail error: %s\n", error);
    }

    check(video_ok != 0, "video thumbnail generation succeeds through MLT");
    check(file_has_data(video_output), "video thumbnail output has data");
    check(
        selected_frame >= 50,
        "representative-frame selection skips the two-second black leader"
    );

    if (file_has_data(video_output)) {
        check_jpeg_geometry(video_output, 480, 270);
    }

    /* Storyboard/Visual Time asks for a deterministic source frame. */
    char *exact_output =
        g_strdup_printf("%s.exact.jpg", video_output);
    if (exact_output != NULL) {
        remove(exact_output);
    }

    error[0] = '\0';
    selected_frame = -1;
    const int exact_ok =
        exact_output != NULL &&
        mlt_thumbnail_generate_at_frame(
            video_path,
            exact_output,
            256,
            144,
            75,
            &selected_frame,
            error,
            (int)sizeof(error)
        ) != 0;

    if (!exact_ok && error[0] != '\0') {
        fprintf(stderr, "  exact-frame thumbnail error: %s\n", error);
    }

    check(exact_ok, "explicit storyboard frame generation succeeds through MLT");
    check(selected_frame == 75, "storyboard generation preserves the requested source frame");
    check(
        exact_output != NULL && file_has_data(exact_output),
        "storyboard generation publishes thumbnail output"
    );
    if (exact_output != NULL && file_has_data(exact_output)) {
        check_jpeg_geometry(exact_output, 256, 144);
    }
    if (exact_output != NULL) {
        remove(exact_output);
        g_free(exact_output);
    }

    check_storyboard_batch_generation(video_path);

    error[0] = '\0';
    selected_frame = -1;

    const int still_ok = mlt_thumbnail_generate(
        still_path,
        still_output,
        480,
        270,
        &selected_frame,
        error,
        (int)sizeof(error)
    );

    if (!still_ok && error[0] != '\0') {
        fprintf(stderr, "  still thumbnail error: %s\n", error);
    }

    check(still_ok != 0, "still thumbnail generation succeeds through MLT");
    check(file_has_data(still_output), "still thumbnail output has data");
    check(selected_frame == 0, "still thumbnail uses frame zero");

    if (file_has_data(still_output)) {
        check_jpeg_geometry(still_output, 480, 270);
    }

    error[0] = '\0';
    selected_frame = -1;

    check(
        mlt_thumbnail_generate(
            "/definitely/not/a/real/media/file.mp4",
            video_output,
            480,
            270,
            &selected_frame,
            error,
            (int)sizeof(error)
        ) == 0,
        "missing media fails closed"
    );
    check(error[0] != '\0', "thumbnail failure returns a diagnostic");

    /*
     * Regression for the process-wide serialization lock: malformed arguments
     * must fail before the mutex is acquired so the next valid request cannot
     * be poisoned by an unreleased lock.
     */
    error[0] = '\0';
    selected_frame = -1;
    check(
        mlt_thumbnail_generate(
            video_path,
            video_output,
            0,
            270,
            &selected_frame,
            error,
            (int)sizeof(error)
        ) == 0,
        "invalid thumbnail dimensions fail before generation"
    );
    check(
        error[0] != '\0',
        "invalid thumbnail dimensions return a diagnostic"
    );

    char *recovery_output =
        g_strdup_printf("%s.recovery.jpg", video_output);
    if (recovery_output != NULL) {
        remove(recovery_output);
    }

    error[0] = '\0';
    selected_frame = -1;
    const int recovery_ok =
        recovery_output != NULL &&
        mlt_thumbnail_generate(
            video_path,
            recovery_output,
            480,
            270,
            &selected_frame,
            error,
            (int)sizeof(error)
        ) != 0;
    check(
        recovery_ok,
        "valid generation still succeeds after an invalid request"
    );
    check(
        recovery_output != NULL && file_has_data(recovery_output),
        "post-failure generation publishes fresh thumbnail output"
    );

    if (recovery_output != NULL) {
        remove(recovery_output);
        g_free(recovery_output);
    }

    check_concurrent_generation(video_path, video_output);

    mlt_bridge_shutdown();

    printf("\n%s thumbnail smoke (%d failures)\n",
           failures == 0 ? "PASS" : "FAIL",
           failures);

    return failures == 0 ? 0 : 1;
}
