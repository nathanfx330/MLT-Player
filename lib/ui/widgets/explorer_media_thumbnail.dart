// lib/ui/widgets/explorer_media_thumbnail.dart

import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/explorer_item.dart';
import '../../services/thumbnail_service.dart';

class ExplorerMediaThumbnail extends StatefulWidget {
  const ExplorerMediaThumbnail({
    super.key,
    required this.item,
    required this.thumbnailService,
    required this.fallbackIcon,
    required this.active,
  });

  final ExplorerItem item;
  final ThumbnailService thumbnailService;
  final IconData fallbackIcon;
  final bool active;

  @override
  State<ExplorerMediaThumbnail> createState() =>
      ExplorerMediaThumbnailState();
}

class ExplorerMediaThumbnailState
    extends State<ExplorerMediaThumbnail> {
  Future<String?>? _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _requestThumbnail();
  }

  @override
  void didUpdateWidget(
    covariant ExplorerMediaThumbnail oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.path != widget.item.path ||
        oldWidget.item.kind != widget.item.kind ||
        !identical(
          oldWidget.thumbnailService,
          widget.thumbnailService,
        ) ||
        oldWidget.active != widget.active) {
      _requestThumbnail();
    }
  }

  void _requestThumbnail() {
    if (!widget.active) {
      _thumbnailFuture = null;
      return;
    }

    _thumbnailFuture =
        widget.thumbnailService.supports(widget.item)
            ? widget.thumbnailService.thumbnailFor(widget.item)
            : null;
  }

  @override
  Widget build(BuildContext context) {
    final future = _thumbnailFuture;
    if (future == null) {
      return _buildFallback(loading: false);
    }

    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path != null && path.isNotEmpty) {
          return Image.file(
            File(path),
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              return _buildFallback(loading: false);
            },
          );
        }

        return _buildFallback(
          loading:
              snapshot.connectionState ==
                  ConnectionState.waiting,
        );
      },
    );
  }

  Widget _buildFallback({required bool loading}) {
    return ColoredBox(
      color: Colors.black26,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Icon(
              widget.fallbackIcon,
              size: 52,
              color: Colors.white30,
            ),
          ),
          if (loading)
            const Positioned(
              right: 8,
              bottom: 8,
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white38,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
