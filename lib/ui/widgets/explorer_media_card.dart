// lib/ui/widgets/explorer_media_card.dart

import 'package:flutter/material.dart';

import '../../models/explorer_item.dart';
import '../../services/thumbnail_service.dart';
import 'explorer_media_thumbnail.dart';

class ExplorerMediaCard extends StatelessWidget {
  const ExplorerMediaCard({
    super.key,
    required this.item,
    required this.thumbnailService,
    required this.active,
    required this.selected,
    required this.rating,
    required this.colorStripe,
    required this.favorite,
    required this.onTap,
    required this.onDoubleTap,
    this.title,
    this.subtitle,
  });

  final ExplorerItem item;
  final ThumbnailService thumbnailService;
  final bool active;
  final bool selected;
  final int rating;
  final Color? colorStripe;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final isRedleafLink =
        item.isDirectory && item.path.toLowerCase().endsWith('.rlink');

    final icon = isRedleafLink
        ? Icons.link
        : switch (item.kind) {
      ExplorerItemKind.directory => Icons.folder,
      ExplorerItemKind.video => Icons.movie_outlined,
      ExplorerItemKind.audio => Icons.graphic_eq,
      ExplorerItemKind.image => Icons.image_outlined,
      ExplorerItemKind.project => Icons.account_tree_outlined,
    };

    return Material(
      color: selected
          ? const Color(0x33E8A33D)
          : const Color(0xFF1B1B1B),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0xFFE8A33D)
                  : Colors.white10,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ExplorerMediaThumbnail(
                      item: item,
                      thumbnailService: thumbnailService,
                      fallbackIcon: icon,
                      active: active,
                    ),
                    if (favorite && !item.isDirectory)
                      const Positioned(
                        top: 7,
                        left: 7,
                        child: Icon(
                          Icons.star,
                          size: 16,
                          color: Color(0xFFE8A33D),
                          shadows: [
                            Shadow(
                              blurRadius: 4,
                              color: Colors.black87,
                            ),
                          ],
                        ),
                      ),
                    if (!item.isDirectory && rating > 0)
                      Positioned(
                        top: 7,
                        right: 7,
                        child: _ExplorerRatingBadge(rating: rating),
                      ),
                  ],
                ),
              ),
              if (colorStripe != null)
                Container(
                  height: 4,
                  color: colorStripe,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 8, 9, 3),
                child: Text(
                  title ?? item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
                child: Text(
                  subtitle ??
                      (isRedleafLink
                          ? 'R.LINK VIRTUAL FOLDER'
                          : item.isDirectory
                              ? 'Folder'
                              : item.extension.toUpperCase()),
                  style:
                      const TextStyle(fontSize: 9, color: Colors.white30),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExplorerRatingBadge extends StatelessWidget {
  const _ExplorerRatingBadge({required this.rating});

  final int rating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC111111),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.star,
            size: 11,
            color: Color(0xFFE8A33D),
          ),
          const SizedBox(width: 3),
          Text(
            '$rating',
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

