// lib/ui/widgets/storyboard_view.dart

import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/media_info.dart';
import '../../services/storyboard_thumbnail_service.dart';

enum PlayerViewMode { video, storyboard }

class PlayerViewModeSwitch extends StatelessWidget {
  const PlayerViewModeSwitch({
    super.key,
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final PlayerViewMode mode;
  final bool enabled;
  final ValueChanged<PlayerViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget button(PlayerViewMode value, String label) {
      final active = mode == value;
      final available = value == PlayerViewMode.video || enabled;

      return InkWell(
        onTap: available ? () => onChanged(value) : null,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE8A33D) : Colors.white10,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.45,
              color: active
                  ? Colors.black
                  : (available ? Colors.white70 : Colors.white24),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(PlayerViewMode.video, 'VIDEO'),
          const SizedBox(width: 4),
          button(PlayerViewMode.storyboard, 'STORYBOARD'),
        ],
      ),
    );
  }
}

class StoryboardView extends StatefulWidget {
  const StoryboardView({
    super.key,
    required this.media,
    required this.durationMs,
    required this.positionMs,
    required this.thumbnailService,
    required this.sourceFrameForPositionMs,
    required this.onSeek,
    required this.onOpenVideo,
  });

  final MediaInfo media;
  final int durationMs;
  final int positionMs;
  final StoryboardThumbnailService thumbnailService;
  final int Function(int clipPositionMs) sourceFrameForPositionMs;
  final ValueChanged<int> onSeek;
  final ValueChanged<int> onOpenVideo;

  @override
  State<StoryboardView> createState() => _StoryboardViewState();
}

class _StoryboardViewState extends State<StoryboardView> {
  static const List<int> _intervalChoices = <int>[5, 10, 30, 60];

  int _intervalSeconds = 10;

  @override
  void initState() {
    super.initState();
    widget.thumbnailService.beginSource(widget.media.path);
  }

  @override
  void didUpdateWidget(covariant StoryboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.path != widget.media.path) {
      widget.thumbnailService.beginSource(widget.media.path);
    }
  }

  @override
  void dispose() {
    widget.thumbnailService.cancelPending();
    super.dispose();
  }

  void _setInterval(int? seconds) {
    if (seconds == null || seconds == _intervalSeconds) {
      return;
    }

    setState(() => _intervalSeconds = seconds);
    widget.thumbnailService.restartSource(widget.media.path);
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.durationMs < 0 ? 0 : widget.durationMs;
    final intervalMs = _intervalSeconds * 1000;
    final itemCount = durationMs <= 0
        ? 0
        : ((durationMs - 1) ~/ intervalMs) + 1;

    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 72, 20, 154),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StoryboardToolbar(
              intervalSeconds: _intervalSeconds,
              choices: _intervalChoices,
              itemCount: itemCount,
              onChanged: _setInterval,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: itemCount == 0
                  ? const Center(
                      child: Text(
                        'No timed video frames available.',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : GridView.builder(
                      // ignore: deprecated_member_use
                      cacheExtent: 500,
                      padding: const EdgeInsets.only(bottom: 20),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 286,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 16 / 10.5,
                          ),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        final clipMs = index * intervalMs;
                        final sourceFrame =
                            widget.sourceFrameForPositionMs(clipMs);
                        final selected = _isSelected(
                          clipMs,
                          intervalMs,
                          durationMs,
                        );

                        return _StoryboardTile(
                          key: ValueKey<String>(
                            '${widget.media.path}:$_intervalSeconds:$sourceFrame',
                          ),
                          sourcePath: widget.media.path,
                          sourceFrame: sourceFrame,
                          clipMs: clipMs,
                          selected: selected,
                          service: widget.thumbnailService,
                          onTap: () => widget.onSeek(clipMs),
                          onDoubleTap: () => widget.onOpenVideo(clipMs),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isSelected(int clipMs, int intervalMs, int durationMs) {
    final position = widget.positionMs < 0
        ? 0
        : (widget.positionMs > durationMs ? durationMs : widget.positionMs);
    final endCandidate = clipMs + intervalMs;
    final end = endCandidate > durationMs ? durationMs : endCandidate;

    if (end >= durationMs) {
      return position >= clipMs && position <= durationMs;
    }
    return position >= clipMs && position < end;
  }
}

class _StoryboardToolbar extends StatelessWidget {
  const _StoryboardToolbar({
    required this.intervalSeconds,
    required this.choices,
    required this.itemCount,
    required this.onChanged,
  });

  final int intervalSeconds;
  final List<int> choices;
  final int itemCount;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.grid_view_rounded, size: 18, color: Colors.white54),
        const SizedBox(width: 8),
        const Text(
          'EVERY',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
            color: Colors.white54,
          ),
        ),
        const SizedBox(width: 8),
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: intervalSeconds,
            dropdownColor: const Color(0xFF242424),
            focusColor: Colors.transparent,
            items: choices
                .map(
                  (seconds) => DropdownMenuItem<int>(
                    value: seconds,
                    child: Text(seconds == 60 ? '1 min' : '$seconds sec'),
                  ),
                )
                .toList(growable: false),
            onChanged: onChanged,
          ),
        ),
        const Spacer(),
        Text(
          '$itemCount ${itemCount == 1 ? 'moment' : 'moments'}',
          style: const TextStyle(fontSize: 11, color: Colors.white38),
        ),
      ],
    );
  }
}

class _StoryboardTile extends StatefulWidget {
  const _StoryboardTile({
    super.key,
    required this.sourcePath,
    required this.sourceFrame,
    required this.clipMs,
    required this.selected,
    required this.service,
    required this.onTap,
    required this.onDoubleTap,
  });

  final String sourcePath;
  final int sourceFrame;
  final int clipMs;
  final bool selected;
  final StoryboardThumbnailService service;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  State<_StoryboardTile> createState() => _StoryboardTileState();
}

class _StoryboardTileState extends State<_StoryboardTile> {
  late Future<String?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _load();
  }

  @override
  void didUpdateWidget(covariant _StoryboardTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourcePath != widget.sourcePath ||
        oldWidget.sourceFrame != widget.sourceFrame ||
        !identical(oldWidget.service, widget.service)) {
      _thumbnail = _load();
    }
  }

  Future<String?> _load() => widget.service.thumbnailAtFrame(
    sourcePath: widget.sourcePath,
    requestedFrame: widget.sourceFrame,
  );

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.selected
        ? const Color(0xFFE8A33D)
        : Colors.white12;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: borderColor,
              width: widget.selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FutureBuilder<String?>(
                  future: _thumbnail,
                  builder: (context, snapshot) {
                    final path = snapshot.data;
                    if (path != null && path.isNotEmpty) {
                      return Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stackTrace) =>
                            const _StoryboardPlaceholder(failed: true),
                      );
                    }

                    if (snapshot.connectionState == ConnectionState.done) {
                      return const _StoryboardPlaceholder(failed: true);
                    }

                    return const _StoryboardPlaceholder(failed: false);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                child: Text(
                  _formatClock(widget.clipMs),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                    color: widget.selected
                        ? const Color(0xFFE8A33D)
                        : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatClock(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds < 0 ? 0 : milliseconds);
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

class _StoryboardPlaceholder extends StatelessWidget {
  const _StoryboardPlaceholder({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF111111),
      child: Center(
        child: failed
            ? const Icon(
                Icons.image_not_supported_outlined,
                size: 26,
                color: Colors.white24,
              )
            : const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white30,
                ),
              ),
      ),
    );
  }
}
