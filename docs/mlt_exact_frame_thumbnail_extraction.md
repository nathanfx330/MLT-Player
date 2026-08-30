<!-- docs/mlt_exact_frame_thumbnail_extraction.md -->

# Efficient Exact Frame Thumbnail Extraction with MLT

## Purpose

Applications that build storyboards, contact sheets, media browsers, or visual indexes often need many exact frames from the same source media.

A simple implementation can generate each thumbnail as an independent MLT operation:

1. Create a profile.
2. Open the source.
3. Probe the source profile.
4. Close the probe producer.
5. Reopen the source using the detected profile.
6. Seek to one requested frame.
7. Decode that frame.
8. Close the producer and profile.
9. Repeat the entire process for the next thumbnail.

This works, but it repeats source discovery and producer setup for every requested frame.

For multiple thumbnails from the same media source, a more efficient pattern is to open and probe the source once, reopen it once with the detected source profile, and then reuse that producer for a sequence of exact frame requests.

The general pattern is:

```text
initialize MLT

create temporary profile
open probe producer
derive profile from producer
close probe producer

open working producer using detected profile

for each requested source frame:
    seek producer
    request frame
    decode image
    consume or publish thumbnail
    close frame

close working producer
close profile
```

This approach reduces repeated source initialization while preserving exact source frame selection.

---

## 1. Probe the Source Profile Before Extraction

Do not assume that the application's default MLT profile matches the source media.

A source may have a frame rate, dimensions, or other timing characteristics that differ from the default profile. If a producer is opened using an unrelated profile, source timing can be interpreted incorrectly.

A reliable source opening sequence is:

```c
mlt_profile profile = mlt_profile_init(NULL);

mlt_producer probe = mlt_factory_producer(
    profile,
    NULL,
    source_path
);

if (probe == NULL) {
    /* handle failure */
}

mlt_profile_from_producer(profile, probe);

mlt_producer_close(probe);
```

After deriving the source profile, reopen the producer using the updated profile:

```c
mlt_producer producer = mlt_factory_producer(
    profile,
    NULL,
    source_path
);

if (producer == NULL) {
    /* handle failure */
}
```

Reopening matters because a producer may already have configured itself according to the profile that existed when it was first constructed.

For source accurate extraction, the producer used for real frame requests should therefore be created after the source profile has been established.

---

## 2. Reuse One Producer for Multiple Exact Frames

Once the working producer has been opened, multiple source frames can be extracted without reopening the media for every thumbnail.

For each requested frame:

```c
mlt_producer_seek(producer, requested_frame);

mlt_frame frame = NULL;

if (mlt_service_get_frame(
        MLT_PRODUCER_SERVICE(producer),
        &frame,
        0
    ) != 0 ||
    frame == NULL) {
    /* handle frame request failure */
}
```

Then request an image from the frame:

```c
uint8_t *image = NULL;
mlt_image_format format = mlt_image_rgb24;
int width = requested_width;
int height = requested_height;

if (mlt_frame_get_image(
        frame,
        &image,
        &format,
        &width,
        &height,
        0
    ) != 0 ||
    image == NULL) {
    /* handle decode failure */
}
```

After the thumbnail has been consumed or written:

```c
mlt_frame_close(frame);
```

The same producer can then seek to the next requested frame.

At the end of the batch:

```c
mlt_producer_close(producer);
mlt_profile_close(profile);
```

The important distinction is that the frame object is short lived, while the producer and profile remain alive for the whole extraction session.

---

## 3. Preserve Exact Source Frame Requests

Storyboard generation often requires exact source frame selection rather than an approximate thumbnail chosen from a time interval.

Treat requested frames as source frame numbers and keep that unit consistent throughout the extraction path.

For example:

```text
requested frames:

120
240
360
480
```

should remain frame requests rather than being converted back and forth through rounded time values unless the application specifically requires time based addressing.

A useful verification during development is to compare the requested frame with the frame position returned by the producer or frame.

This helps catch accidental profile mismatches or frame rate conversion.

---

## 4. Batch Extraction Reduces Repeated Source Setup

Consider a storyboard requesting 60 thumbnails.

A per thumbnail implementation may perform approximately:

```text
60 profile initializations
60 source probes
60 probe closes
60 producer reopens
60 producer closes
```

A batch implementation can reduce that to approximately:

```text
1 profile initialization
1 source probe
1 probe close
1 producer open
60 seeks and frame requests
1 producer close
1 profile close
```

The decode work for each requested frame still exists.

The improvement comes from avoiding repeated producer construction, source probing, and profile setup for the same media file.

This can make a substantial difference in applications that display many thumbnails at once.

---

## 5. Keep Batch Sizes Bounded in Interactive Applications

An application does not necessarily need to process every pending thumbnail in one enormous native call.

A bounded batch can provide a useful compromise between setup efficiency and responsiveness.

For example:

```text
pending requests: 53
native batch size: 8
```

The application can process:

```text
8
8
8
8
8
8
5
```

This retains most of the benefit of producer reuse while allowing cancellation, source changes, and UI updates between batches.

The ideal batch size is application dependent.

For an interactive storyboard, a small batch can also improve perceived latency because early thumbnails can become available before the entire storyboard has completed.

---

## 6. Publish Thumbnail Files Atomically

This is an application level recommendation rather than an MLT requirement.

If thumbnail generation happens on a background worker while the UI watches for output files, avoid exposing a partially written image.

One simple pattern is:

```text
0.part.jpg
```

followed by an atomic rename after the image writer completes successfully:

```text
0.jpg
```

The UI should only consume the final filename.

For indexed batch output, a temporary directory can contain:

```text
0.jpg
1.jpg
2.jpg
3.jpg
```

where each index corresponds to the same index in the requested frame list.

This makes it possible for the application to publish individual completed thumbnails progressively while the native batch is still running.

---

## 7. Individual Frame Failure Does Not Need to Abort the Entire Batch

A media source can contain a frame that fails to decode even when other requested frames are usable.

For storyboard generation, it is often more useful to continue processing the remaining requests.

A batch API can therefore track:

```text
number of requested frames
number of successfully generated frames
first diagnostic error
```

and continue after an individual frame failure.

The application can then display all successful thumbnails while retaining a useful diagnostic for failed frames.

Whether a partial batch should be considered successful is an application policy decision.

---

## 8. Cancellation and Source Changes

Interactive media applications frequently replace one thumbnail session with another.

Examples include:

```text
open a new video
change storyboard interval
switch between storyboard and bookmarks
close the media
```

A practical application architecture should associate thumbnail requests with a source generation or session identifier.

Before publishing a completed thumbnail, verify that the result still belongs to the currently active source session.

Conceptually:

```text
request:
    source path
    source generation
    requested frame
    destination

completion:
    if request generation != active generation:
        discard result
```

This prevents stale work from a previous source from appearing in the current UI.

This session management belongs to the application rather than MLT itself.

---

## 9. Concurrency Caution

The following is an implementation observation, not a general statement about MLT thread safety.

During development of an application that generates background thumbnails, multiple independent thumbnail generation graphs were initially allowed to enter MLT concurrently.

Intermittent crashes were observed in optimized standalone builds.

Serializing native thumbnail generation eliminated those crashes in that application.

Because this behavior has not been reduced to a minimal upstream MLT test case, applications should not interpret this observation as proof that MLT producers in general cannot be used concurrently.

The exact concurrency guarantees can depend on:

```text
producer type
consumer type
service implementation
FFmpeg integration
shared global state
application lifecycle
platform
build configuration
```

Until the application's exact concurrency model has been validated, a conservative thumbnail implementation can serialize native generation while still gaining substantial performance from reusing one producer for multiple frame requests.

A useful upstream documentation question is:

> What concurrency guarantees should applications assume when constructing, seeking, and evaluating multiple independent producer graphs from different threads?

Clarifying this explicitly in MLT developer documentation would help application authors choose between parallel workers, service level locking, and process wide serialization.

---

## 10. Example Batch Algorithm

A complete application specific implementation will need error handling and image output code, but the extraction structure can remain small:

```c
int generate_thumbnail_batch(
    const char *source_path,
    const int64_t *requested_frames,
    int frame_count
) {
    mlt_profile profile = NULL;
    mlt_producer probe = NULL;
    mlt_producer producer = NULL;

    profile = mlt_profile_init(NULL);
    if (profile == NULL) {
        return 0;
    }

    probe = mlt_factory_producer(
        profile,
        NULL,
        source_path
    );

    if (probe == NULL) {
        mlt_profile_close(profile);
        return 0;
    }

    mlt_profile_from_producer(profile, probe);
    mlt_producer_close(probe);
    probe = NULL;

    producer = mlt_factory_producer(
        profile,
        NULL,
        source_path
    );

    if (producer == NULL) {
        mlt_profile_close(profile);
        return 0;
    }

    for (int i = 0; i < frame_count; i++) {
        mlt_frame frame = NULL;

        mlt_producer_seek(
            producer,
            requested_frames[i]
        );

        if (mlt_service_get_frame(
                MLT_PRODUCER_SERVICE(producer),
                &frame,
                0
            ) != 0 ||
            frame == NULL) {
            continue;
        }

        uint8_t *image = NULL;
        mlt_image_format format = mlt_image_rgb24;
        int width = 256;
        int height = 144;

        if (mlt_frame_get_image(
                frame,
                &image,
                &format,
                &width,
                &height,
                0
            ) == 0 &&
            image != NULL) {
            /*
             * Consume or write the decoded image here.
             */
        }

        mlt_frame_close(frame);
    }

    mlt_producer_close(producer);
    mlt_profile_close(profile);

    return 1;
}
```

This example intentionally omits image encoding so that the MLT lifecycle remains clear.

Applications can write JPEG, PNG, raw RGB, or pass the decoded frame directly to another subsystem.

---

## 11. What Belongs in MLT Documentation

The broadly reusable MLT concepts are:

1. Probe the real source profile before source accurate extraction.
2. Reopen the working producer after deriving the source profile.
3. Reuse one producer for multiple exact frame requests from the same source.
4. Seek and request a new frame for each thumbnail.
5. Keep frame objects short lived while retaining the producer for the batch.
6. Clearly document the expected concurrency model for independent producer graphs.

The following concerns are useful application patterns but should not be presented as MLT requirements:

```text
atomic JPEG publication
temporary batch directories
UI polling
cache naming
generation IDs
request deduplication
batch size
application level cancellation
```

Separating these concerns keeps the MLT example focused while still giving application developers a practical path to efficient storyboard generation.

---

## 12. Validation Performed in MLT Player

The pattern above was implemented in MLT Player for Storyboard thumbnail generation.

The test coverage included:

```text
exact frame generation
multiple exact frames through one native generation session
indexed batch output
atomic publication of completed JPEG files
temporary batch directory cleanup
missing media failure
invalid dimension failure
successful generation after a failed request
serialized concurrent callers
source session invalidation
duplicate request deduplication
view handoff between Storyboard and Bookmarks
```

The focused native smoke test completed with:

```text
PASS thumbnail smoke (0 failures)
```

The Flutter test suite completed with:

```text
128 tests passed
```

Interactive testing also confirmed that storyboard generation became materially faster when multiple exact frame requests reused one MLT generation session.

These application results support the extraction pattern described above, while the concurrency observation should still be treated as a topic for further upstream clarification rather than a framework wide guarantee.

---

## Suggested Upstream Follow Up

Two separate upstream contributions would keep the scope clear.

### Documentation or Example Pull Request

Suggested title:

```text
Add C example for efficient exact frame thumbnail extraction
```

Scope:

```text
source profile probing
producer reopen
multiple exact frame seeks
single producer reuse
clean lifecycle
```

### Discussion or Issue

Suggested title:

```text
Clarify concurrency guarantees for independent producer graphs
```

Scope:

```text
producer construction from worker threads
parallel seeking
parallel image evaluation
avformat backed producers
recommended locking boundaries
```

Keeping these separate allows the extraction example to remain useful even if the concurrency question requires additional investigation.
