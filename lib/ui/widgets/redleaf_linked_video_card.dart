// lib/ui/widgets/redleaf_linked_video_card.dart

import 'package:flutter/material.dart';

import '../../models/explorer_item.dart';
import '../../services/redleaf_media_resource_service.dart';
import '../../services/redleaf_srt_service.dart';
import '../../services/thumbnail_service.dart';
import 'explorer_media_card.dart';

/// A Redleaf-linked video in the very same card and thumbnail renderer used
/// by local Explorer. Only verified local files reach the MLT thumbnail
/// decoder; unverified URLs and offline links show the normal video fallback.
class RedleafLinkedVideoCard extends StatefulWidget {
  const RedleafLinkedVideoCard({
    super.key,
    required this.document,
    required this.mediaResources,
    required this.thumbnailService,
    required this.active,
    required this.connectedToProject,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    this.colorStripe,
  });

  final RedleafSrtDocument document;
  final RedleafMediaResourceService mediaResources;
  final ThumbnailService thumbnailService;
  final bool active;
  final bool connectedToProject;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final Color? colorStripe;

  @override
  State<RedleafLinkedVideoCard> createState() => _RedleafLinkedVideoCardState();
}

class _RedleafLinkedVideoCardState extends State<RedleafLinkedVideoCard> {
  Future<RedleafMediaResourceResolution>? _resolution;

  @override
  void initState() {
    super.initState();
    _requestResolution();
  }

  @override
  void didUpdateWidget(covariant RedleafLinkedVideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.document.media;
    final current = widget.document.media;
    if (oldWidget.document.docId != widget.document.docId ||
        before.state != current.state ||
        before.path != current.path ||
        before.type != current.type ||
        before.source != current.source ||
        oldWidget.connectedToProject != widget.connectedToProject ||
        oldWidget.active != widget.active ||
        !identical(oldWidget.mediaResources, widget.mediaResources)) {
      _requestResolution();
    }
  }

  void _requestResolution() {
    _resolution = widget.active &&
            widget.connectedToProject &&
            widget.document.media.isVideo
        ? widget.mediaResources.resolve(widget.document)
        : null;
  }

  static String _mediaName(RedleafSrtDocument document) {
    final reference = document.media.path?.trim() ?? '';
    if (reference.isEmpty) return document.fileName;
    final uri = Uri.tryParse(reference);
    final path = uri?.path ?? reference;
    final name = ExplorerItem.basename(path);
    if (name.isEmpty) return document.fileName;
    try {
      return Uri.decodeComponent(name);
    } on FormatException {
      return name;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RedleafMediaResourceResolution>(
      future: _resolution,
      builder: (context, snapshot) {
        final resolved = snapshot.data;
        final localPath = resolved?.isLocalFileReady == true
            ? resolved!.resolvedResource?.trim()
            : null;
        final ready = localPath != null && localPath.isNotEmpty;

        final item = ExplorerItem(
          path: ready ? localPath! : (widget.document.media.path ?? ''),
          name: ready
              ? ExplorerItem.basename(localPath!)
              : _mediaName(widget.document),
          kind: ExplorerItemKind.video,
        );

        return Tooltip(
          message: widget.document.relativePath,
          child: ExplorerMediaCard(
            item: item,
            thumbnailService: widget.thumbnailService,
            active: widget.active && ready,
            selected: widget.selected,
            rating: 0,
            favorite: false,
            colorStripe: widget.colorStripe,
            subtitle: ready
                ? 'VIDEO · SRT #${widget.document.docId}'
                : widget.connectedToProject
                    ? 'VIDEO UNAVAILABLE · SRT #${widget.document.docId}'
                    : 'VIDEO OFFLINE · SRT #${widget.document.docId}',
            onTap: widget.onTap,
            onDoubleTap: widget.onDoubleTap,
          ),
        );
      },
    );
  }
}
