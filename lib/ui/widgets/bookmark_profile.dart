// lib/ui/widgets/bookmark_profile.dart

import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/srt_subtitle_service.dart';
import '../../services/storyboard_thumbnail_service.dart';

class BookmarkProfile extends StatefulWidget {
  const BookmarkProfile({
    super.key,
    required this.sourcePath,
    required this.sourceFrame,
    required this.frameLabel,
    required this.thumbnailService,
    required this.subtitleTrack,
    required this.bookmarkPositionMs,
    required this.exportEnabled,
    required this.onBack,
    required this.onOpenFrame,
    required this.onOpenTranscriptPosition,
    required this.onRemove,
    required this.onExport,
  });

  final String sourcePath;
  final int sourceFrame;
  final String frameLabel;
  final StoryboardThumbnailService thumbnailService;
  final SubtitleTrack? subtitleTrack;
  final int bookmarkPositionMs;
  final bool exportEnabled;
  final VoidCallback onBack;
  final VoidCallback onOpenFrame;
  final ValueChanged<int> onOpenTranscriptPosition;
  final VoidCallback onRemove;
  final VoidCallback onExport;

  @override
  State<BookmarkProfile> createState() => _BookmarkProfileState();
}

class _BookmarkProfileState extends State<BookmarkProfile> {
  late Future<String?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant BookmarkProfile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourcePath != widget.sourcePath ||
        oldWidget.sourceFrame != widget.sourceFrame ||
        !identical(oldWidget.thumbnailService, widget.thumbnailService)) {
      _thumbnail = _loadThumbnail();
    }
  }

  Future<String?> _loadThumbnail() {
    return widget.thumbnailService.thumbnailAtFrame(
      sourcePath: widget.sourcePath,
      requestedFrame: widget.sourceFrame,
    );
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 72, 20, 154),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              TextButton.icon(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 17),
                label: const Text('BOOKMARKS'),
              ),
              const SizedBox(width: 12),
              const Text(
                'BOOKMARK PROFILE',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: Colors.white54,
                ),
              ),
              const Spacer(),
              Text(
                widget.frameLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: accentColor,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '#${widget.sourceFrame + 1}',
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.white38,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: _BookmarkImageCard(
                    thumbnail: _thumbnail,
                    onOpenFrame: widget.onOpenFrame,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 2,
                  child: _BookmarkTranscriptPanel(
                    track: widget.subtitleTrack,
                    bookmarkPositionMs: widget.bookmarkPositionMs,
                    onOpenPosition: widget.onOpenTranscriptPosition,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: widget.onOpenFrame,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('OPEN IN PLAYER'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: widget.exportEnabled ? widget.onExport : null,
                icon: const Icon(Icons.file_download_outlined, size: 17),
                label: const Text('EXPORT PNG'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: widget.onRemove,
                icon: const Icon(Icons.delete_outline, size: 17),
                label: const Text('REMOVE BOOKMARK'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white54,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BookmarkImageCard extends StatelessWidget {
  const _BookmarkImageCard({
    required this.thumbnail,
    required this.onOpenFrame,
  });

  final Future<String?> thumbnail;
  final VoidCallback onOpenFrame;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF151515),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpenFrame,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12),
          ),
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: FutureBuilder<String?>(
                future: thumbnail,
                builder: (context, snapshot) {
                  final path = snapshot.data;
                  if (path != null && path.isNotEmpty) {
                    return Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          const _BookmarkProfilePlaceholder(failed: true),
                    );
                  }

                  if (snapshot.connectionState == ConnectionState.done) {
                    return const _BookmarkProfilePlaceholder(failed: true);
                  }

                  return const _BookmarkProfilePlaceholder(failed: false);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BookmarkTranscriptPanel extends StatelessWidget {
  const _BookmarkTranscriptPanel({
    required this.track,
    required this.bookmarkPositionMs,
    required this.onOpenPosition,
  });

  static const int _contextRadius = 5;

  final SubtitleTrack? track;
  final int bookmarkPositionMs;
  final ValueChanged<int> onOpenPosition;

  @override
  Widget build(BuildContext context) {
    final currentTrack = track;

    return Material(
      color: const Color(0xFF171717),
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 13, 14, 11),
              child: Row(
                children: [
                  Icon(
                    Icons.subtitles_outlined,
                    size: 18,
                    color: Colors.white70,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'TRANSCRIPT AROUND BOOKMARK',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: currentTrack == null || currentTrack.isEmpty
                  ? const _NoBookmarkTranscript()
                  : _buildTranscript(context, currentTrack),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscript(BuildContext context, SubtitleTrack track) {
    final anchor = _anchorIndex(track.cues, bookmarkPositionMs);
    final first =
        (anchor - _contextRadius).clamp(0, track.cues.length - 1).toInt();
    final last =
        (anchor + _contextRadius).clamp(0, track.cues.length - 1).toInt();
    final cues = track.cues.sublist(first, last + 1);
    final accentColor = Theme.of(context).colorScheme.primary;

    return ListView.separated(
      key: const ValueKey<String>('bookmark-profile-transcript'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: cues.length,
      separatorBuilder: (context, index) => const Divider(
        height: 1,
        indent: 62,
        color: Colors.white10,
      ),
      itemBuilder: (context, index) {
        final cue = cues[index];
        final fullIndex = first + index;
        final active = fullIndex == anchor;

        return Material(
          color: active ? accentColor.withAlpha(0x24) : Colors.transparent,
          child: InkWell(
            onTap: () => onOpenPosition(cue.startMs),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 42,
                    child: Text(
                      _formatTime(cue.startMs),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w500,
                        color: active ? accentColor : Colors.white38,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cue.text,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400,
                        color: active ? Colors.white : Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static int _anchorIndex(List<SubtitleCue> cues, int positionMs) {
    for (var index = 0; index < cues.length; index++) {
      if (cues[index].isActiveAt(positionMs)) {
        return index;
      }
      if (cues[index].startMs > positionMs) {
        return index == 0 ? 0 : index - 1;
      }
    }
    return cues.length - 1;
  }

  static String _formatTime(int milliseconds) {
    final value = milliseconds < 0 ? 0 : milliseconds;
    final duration = Duration(milliseconds: value);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
    }
    return '$mm:$ss';
  }
}

class _NoBookmarkTranscript extends StatelessWidget {
  const _NoBookmarkTranscript();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.subtitles_off_outlined,
              size: 32,
              color: Colors.white24,
            ),
            SizedBox(height: 10),
            Text(
              'No SRT transcript is available for this media.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookmarkProfilePlaceholder extends StatelessWidget {
  const _BookmarkProfilePlaceholder({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF101010),
      child: Center(
        child: failed
            ? const Icon(
                Icons.image_not_supported_outlined,
                size: 34,
                color: Colors.white24,
              )
            : const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white30,
                ),
              ),
      ),
    );
  }
}
