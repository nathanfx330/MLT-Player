// lib/ui/widgets/bookmark_view.dart

import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/storyboard_thumbnail_service.dart';

class BookmarkView extends StatefulWidget {
  const BookmarkView({
    super.key,
    required this.sourcePath,
    required this.sourceFrames,
    required this.currentSourceFrame,
    required this.thumbnailService,
    required this.formatFrame,
    required this.onAddCurrent,
    required this.onOpenFrame,
    required this.onRemoveFrame,
    required this.onExportFrame,
    required this.exportEnabled,
  });

  final String sourcePath;
  final List<int> sourceFrames;
  final int currentSourceFrame;
  final StoryboardThumbnailService thumbnailService;
  final String Function(int sourceFrame) formatFrame;
  final VoidCallback onAddCurrent;
  final ValueChanged<int> onOpenFrame;
  final ValueChanged<int> onRemoveFrame;
  final ValueChanged<int> onExportFrame;
  final bool exportEnabled;

  @override
  State<BookmarkView> createState() => _BookmarkViewState();
}

class _BookmarkViewState extends State<BookmarkView> {
  @override
  void initState() {
    super.initState();
    widget.thumbnailService.beginSource(widget.sourcePath);
  }

  @override
  void didUpdateWidget(covariant BookmarkView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourcePath != widget.sourcePath) {
      widget.thumbnailService.beginSource(widget.sourcePath);
    }
  }

  @override
  void dispose() {
    widget.thumbnailService.cancelPending();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frames = List<int>.from(widget.sourceFrames)..sort();

    return ColoredBox(
      color: const Color(0xFF0D0D0D),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 72, 20, 154),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BookmarkToolbar(
              itemCount: frames.length,
              onAddCurrent: widget.onAddCurrent,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: frames.isEmpty
                  ? _EmptyBookmarks(onAddCurrent: widget.onAddCurrent)
                  : GridView.builder(
                      // Keep the same cache policy as Storyboard. This remains
                      // compatible with the project's older local Flutter SDK.
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
                      itemCount: frames.length,
                      itemBuilder: (context, index) {
                        final sourceFrame = frames[index];
                        return _BookmarkTile(
                          key: ValueKey<String>(
                            '${widget.sourcePath}:bookmark:$sourceFrame',
                          ),
                          sourcePath: widget.sourcePath,
                          sourceFrame: sourceFrame,
                          selected: sourceFrame == widget.currentSourceFrame,
                          service: widget.thumbnailService,
                          frameLabel: widget.formatFrame(sourceFrame),
                          exportEnabled: widget.exportEnabled,
                          onOpen: () => widget.onOpenFrame(sourceFrame),
                          onRemove: () => widget.onRemoveFrame(sourceFrame),
                          onExport: () => widget.onExportFrame(sourceFrame),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookmarkToolbar extends StatelessWidget {
  const _BookmarkToolbar({
    required this.itemCount,
    required this.onAddCurrent,
  });

  final int itemCount;
  final VoidCallback onAddCurrent;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.bookmarks_outlined, size: 18, color: Colors.white54),
        const SizedBox(width: 8),
        const Text(
          'BOOKMARKS',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
            color: Colors.white54,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$itemCount ${itemCount == 1 ? 'keeper' : 'keepers'}',
          style: const TextStyle(fontSize: 11, color: Colors.white38),
        ),
        const Spacer(),
        ExcludeFocus(
          child: TextButton.icon(
            onPressed: onAddCurrent,
          icon: const Icon(Icons.bookmark_add_outlined, size: 17),
          label: const Text('ADD CURRENT'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.primary,
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyBookmarks extends StatelessWidget {
  const _EmptyBookmarks({required this.onAddCurrent});

  final VoidCallback onAddCurrent;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.bookmarks_outlined,
            size: 42,
            color: Colors.white24,
          ),
          const SizedBox(height: 12),
          const Text(
            'No bookmarks kept for this movie.',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 4),
          const Text(
            'Bookmarks are soft screenshots: exact frames, not image files.',
            style: TextStyle(fontSize: 11, color: Colors.white30),
          ),
          const SizedBox(height: 14),
          ExcludeFocus(
            child: OutlinedButton.icon(
              onPressed: onAddCurrent,
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('Add current frame'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookmarkTile extends StatefulWidget {
  const _BookmarkTile({
    super.key,
    required this.sourcePath,
    required this.sourceFrame,
    required this.selected,
    required this.service,
    required this.frameLabel,
    required this.exportEnabled,
    required this.onOpen,
    required this.onRemove,
    required this.onExport,
  });

  final String sourcePath;
  final int sourceFrame;
  final bool selected;
  final StoryboardThumbnailService service;
  final String frameLabel;
  final bool exportEnabled;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  final VoidCallback onExport;

  @override
  State<_BookmarkTile> createState() => _BookmarkTileState();
}

class _BookmarkTileState extends State<_BookmarkTile> {
  late Future<String?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _load();
  }

  @override
  void didUpdateWidget(covariant _BookmarkTile oldWidget) {
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
    final accentColor = Theme.of(context).colorScheme.primary;
    final borderColor = widget.selected ? accentColor : Colors.white12;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FutureBuilder<String?>(
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
                                const _BookmarkPlaceholder(failed: true),
                          );
                        }

                        if (snapshot.connectionState == ConnectionState.done) {
                          return const _BookmarkPlaceholder(failed: true);
                        }

                        return const _BookmarkPlaceholder(failed: false);
                      },
                    ),
                    Positioned(
                      top: 5,
                      right: 5,
                      child: _TileAction(
                        tooltip: 'Remove bookmark',
                        icon: Icons.close,
                        onPressed: widget.onRemove,
                      ),
                    ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: _TileAction(
                        tooltip: 'Export this frame as PNG',
                        icon: Icons.file_download_outlined,
                        onPressed: widget.exportEnabled ? widget.onExport : null,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      Icons.bookmark,
                      size: 14,
                      color: accentColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.frameLabel,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: widget.selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: widget.selected
                              ? accentColor
                              : Colors.white70,
                        ),
                      ),
                    ),
                    Text(
                      '#${widget.sourceFrame + 1}',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xB3000000),
      borderRadius: BorderRadius.circular(5),
      child: ExcludeFocus(
        child: IconButton(
          tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(5),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        iconSize: 16,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

class _BookmarkPlaceholder extends StatelessWidget {
  const _BookmarkPlaceholder({required this.failed});

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
