// lib/ui/project_page.dart

import 'package:flutter/material.dart';

import '../models/project_catalog.dart';
import '../services/project_catalog_service.dart';
import '../services/project_media_metadata_service.dart';

const Color _projectAccent = Color(0xFFE8A33D);

const Map<String, String> _projectColorNames = <String, String>{
  '#E57373': 'Red',
  '#FFB74D': 'Orange',
  '#FFF176': 'Yellow',
  '#81C784': 'Green',
  '#64B5F6': 'Blue',
  '#BA68C8': 'Purple',
};

const List<String> _projectColorOrder = <String>[
  '#E57373',
  '#FFB74D',
  '#FFF176',
  '#81C784',
  '#64B5F6',
  '#BA68C8',
];

class ProjectPage extends StatelessWidget {
  const ProjectPage({
    super.key,
    required this.projectCatalogService,
    required this.projectMediaMetadataService,
    required this.activeProjectId,
    required this.onOpenCatalog,
    required this.onOpenRating,
    required this.onOpenTag,
    required this.onOpenColor,
    required this.onOpenBookmarks,
  });

  final ProjectCatalogService projectCatalogService;
  final ProjectMediaMetadataService projectMediaMetadataService;
  final String? activeProjectId;
  final ValueChanged<String> onOpenCatalog;
  final ValueChanged<int> onOpenRating;
  final ValueChanged<String> onOpenTag;
  final ValueChanged<String> onOpenColor;
  final VoidCallback onOpenBookmarks;

  @override
  Widget build(BuildContext context) {
    final projectId = activeProjectId;
    final project = projectId == null
        ? null
        : projectCatalogService.projectById(projectId);

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: project == null
            ? const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : _ProjectOverview(
                project: project,
                projectCatalogService: projectCatalogService,
                projectMediaMetadataService: projectMediaMetadataService,
                onOpenCatalog: onOpenCatalog,
                onOpenRating: onOpenRating,
                onOpenTag: onOpenTag,
                onOpenColor: onOpenColor,
                onOpenBookmarks: onOpenBookmarks,
              ),
      ),
    );
  }
}

class _ProjectOverview extends StatelessWidget {
  const _ProjectOverview({
    required this.project,
    required this.projectCatalogService,
    required this.projectMediaMetadataService,
    required this.onOpenCatalog,
    required this.onOpenRating,
    required this.onOpenTag,
    required this.onOpenColor,
    required this.onOpenBookmarks,
  });

  final MediaProject project;
  final ProjectCatalogService projectCatalogService;
  final ProjectMediaMetadataService projectMediaMetadataService;
  final ValueChanged<String> onOpenCatalog;
  final ValueChanged<int> onOpenRating;
  final ValueChanged<String> onOpenTag;
  final ValueChanged<String> onOpenColor;
  final VoidCallback onOpenBookmarks;

  @override
  Widget build(BuildContext context) {
    final projectId = project.id;
    final catalogs = projectCatalogService.catalogsForProject(projectId);
    final ratingCounts =
        projectMediaMetadataService.ratingCountsForProject(projectId);
    final tagCounts =
        projectMediaMetadataService.tagCountsForProject(projectId);
    final colorCounts =
        projectMediaMetadataService.colorCountsForProject(projectId);
    final ratedMedia =
        projectMediaMetadataService.ratedMediaCount(projectId);
    final colorLabeledMedia =
        projectMediaMetadataService.colorLabeledMediaCount(projectId);
    final bookmarkCount =
        projectMediaMetadataService.bookmarkCount(projectId);
    final bookmarkedMedia =
        projectMediaMetadataService.bookmarkedMediaCount(projectId);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1100;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PROJECT OVERVIEW',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.8,
                      color: _projectAccent,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    project.name,
                    key: const ValueKey<String>('project-overview-name'),
                    style: const TextStyle(
                      fontSize: 30,
                      height: 1.05,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Project-wide organization at a glance. Click a Catalog, '
                    'rating, color, or tag to open it in Explorer.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _ProjectMetricCard(
                        label: 'CATALOGS',
                        value: catalogs.length,
                        icon: Icons.folder_copy_outlined,
                      ),
                      _ProjectMetricCard(
                        label: 'RATED MEDIA',
                        value: ratedMedia,
                        icon: Icons.star_outline,
                      ),
                      _ProjectMetricCard(
                        label: 'TAGS',
                        value: tagCounts.length,
                        icon: Icons.sell_outlined,
                      ),
                      _ProjectMetricCard(
                        label: 'COLOR LABELED',
                        value: colorLabeledMedia,
                        icon: Icons.palette_outlined,
                      ),
                      _ProjectMetricCard(
                        label: 'BOOKMARKS',
                        value: bookmarkCount,
                        icon: Icons.bookmark_border,
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: _CatalogPanel(
                            projectId: projectId,
                            projectCatalogService: projectCatalogService,
                            onOpenCatalog: onOpenCatalog,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 3,
                          child: _RatingPanel(
                            ratingCounts: ratingCounts,
                            onOpenRating: onOpenRating,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 3,
                          child: _ColorPanel(
                            colorCounts: colorCounts,
                            onOpenColor: onOpenColor,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        _CatalogPanel(
                          projectId: projectId,
                          projectCatalogService: projectCatalogService,
                          onOpenCatalog: onOpenCatalog,
                        ),
                        const SizedBox(height: 14),
                        _RatingPanel(
                          ratingCounts: ratingCounts,
                          onOpenRating: onOpenRating,
                        ),
                        const SizedBox(height: 14),
                        _ColorPanel(
                          colorCounts: colorCounts,
                          onOpenColor: onOpenColor,
                        ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 7,
                          child: _TagPanel(
                            tagCounts: tagCounts,
                            onOpenTag: onOpenTag,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 4,
                          child: _BookmarkPanel(
                            bookmarkCount: bookmarkCount,
                            bookmarkedMediaCount: bookmarkedMedia,
                            onOpen: onOpenBookmarks,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        _TagPanel(
                          tagCounts: tagCounts,
                          onOpenTag: onOpenTag,
                        ),
                        const SizedBox(height: 14),
                        _BookmarkPanel(
                          bookmarkCount: bookmarkCount,
                          bookmarkedMediaCount: bookmarkedMedia,
                          onOpen: onOpenBookmarks,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProjectMetricCard extends StatelessWidget {
  const _ProjectMetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      height: 92,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF181818),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0x18E8A33D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: _projectAccent),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$value',
                  style: const TextStyle(
                    fontSize: 23,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Colors.white38,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectPanel extends StatelessWidget {
  const _ProjectPanel({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
            child: Row(
              children: [
                Icon(icon, size: 17, color: Colors.white54),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                    color: Colors.white70,
                  ),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          child,
        ],
      ),
    );
  }
}

class _CatalogPanel extends StatelessWidget {
  const _CatalogPanel({
    required this.projectId,
    required this.projectCatalogService,
    required this.onOpenCatalog,
  });

  final String projectId;
  final ProjectCatalogService projectCatalogService;
  final ValueChanged<String> onOpenCatalog;

  @override
  Widget build(BuildContext context) {
    final entries = <_CatalogEntry>[];

    void addCatalog(MediaCatalog catalog, int depth) {
      entries.add(_CatalogEntry(catalog, depth));
      for (final child in projectCatalogService.childrenOf(catalog.id)) {
        addCatalog(child, depth + 1);
      }
    }

    for (final root in projectCatalogService.rootCatalogsForProject(projectId)) {
      addCatalog(root, 0);
    }

    return _ProjectPanel(
      title: 'CATALOGS',
      icon: Icons.folder_copy_outlined,
      child: entries.isEmpty
          ? const _ProjectEmptyState('No Catalogs yet.')
          : Column(
              children: [
                for (var index = 0; index < entries.length; index++) ...[
                  _CatalogOverviewRow(
                    key: ValueKey<String>(
                      'project-catalog-${entries[index].catalog.id}',
                    ),
                    entry: entries[index],
                    count: projectCatalogService.mediaCountForCatalog(
                      entries[index].catalog.id,
                    ),
                    onTap: () => onOpenCatalog(entries[index].catalog.id),
                  ),
                  if (index != entries.length - 1)
                    const Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: Colors.white10,
                    ),
                ],
              ],
            ),
    );
  }
}

class _CatalogEntry {
  const _CatalogEntry(this.catalog, this.depth);

  final MediaCatalog catalog;
  final int depth;
}

class _CatalogOverviewRow extends StatelessWidget {
  const _CatalogOverviewRow({
    super.key,
    required this.entry,
    required this.count,
    required this.onTap,
  });

  final _CatalogEntry entry;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final catalog = entry.catalog;

    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      hoverColor: const Color(0x09FFFFFF),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16 + entry.depth * 18.0,
          10,
          16,
          10,
        ),
        child: Row(
          children: [
            Icon(
              catalog.isFavorites ? Icons.star : Icons.folder_outlined,
              size: 16,
              color: catalog.isFavorites ? _projectAccent : Colors.white38,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                catalog.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white70,
                ),
              ),
            ),
            Text(
              '$count',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingPanel extends StatelessWidget {
  const _RatingPanel({
    required this.ratingCounts,
    required this.onOpenRating,
  });

  final Map<int, int> ratingCounts;
  final ValueChanged<int> onOpenRating;

  @override
  Widget build(BuildContext context) {
    return _ProjectPanel(
      title: 'RATINGS',
      icon: Icons.star_outline,
      child: Column(
        children: [
          for (var rating = 5; rating >= 1; rating--)
            _OverviewCountRow(
              key: ValueKey<String>('project-rating-$rating'),
              label: _ratingLabel(rating),
              count: ratingCounts[rating] ?? 0,
              accent: _projectAccent,
              onTap: (ratingCounts[rating] ?? 0) > 0
                  ? () => onOpenRating(rating)
                  : null,
            ),
        ],
      ),
    );
  }
}

class _ColorPanel extends StatelessWidget {
  const _ColorPanel({
    required this.colorCounts,
    required this.onOpenColor,
  });

  final Map<String, int> colorCounts;
  final ValueChanged<String> onOpenColor;

  @override
  Widget build(BuildContext context) {
    final orderedColors = <String>[
      ..._projectColorOrder.where(colorCounts.containsKey),
      ...colorCounts.keys.where(
        (color) => !_projectColorOrder.contains(color),
      ),
    ];

    return _ProjectPanel(
      title: 'COLORS',
      icon: Icons.palette_outlined,
      child: orderedColors.isEmpty
          ? const _ProjectEmptyState('No color labels yet.')
          : Column(
              children: [
                for (final colorHex in orderedColors)
                  _OverviewCountRow(
                    key: ValueKey<String>('project-color-$colorHex'),
                    label: _projectColorNames[colorHex] ?? colorHex,
                    count: colorCounts[colorHex] ?? 0,
                    onTap: (colorCounts[colorHex] ?? 0) > 0
                        ? () => onOpenColor(colorHex)
                        : null,
                    leading: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: _colorFromHex(colorHex),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white24),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _TagPanel extends StatelessWidget {
  const _TagPanel({
    required this.tagCounts,
    required this.onOpenTag,
  });

  final Map<String, int> tagCounts;
  final ValueChanged<String> onOpenTag;

  @override
  Widget build(BuildContext context) {
    final entries = tagCounts.entries.take(16).toList(growable: false);

    return _ProjectPanel(
      title: 'TAGS',
      icon: Icons.sell_outlined,
      trailing: tagCounts.length > entries.length
          ? Text(
              '${tagCounts.length - entries.length} more',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white30,
              ),
            )
          : null,
      child: entries.isEmpty
          ? const _ProjectEmptyState('No tags yet.')
          : Padding(
              padding: const EdgeInsets.all(14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in entries)
                    InkWell(
                      key: ValueKey<String>('project-tag-${entry.key}'),
                      onTap: () => onOpenTag(entry.key),
                      mouseCursor: SystemMouseCursors.click,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x0FFFFFFF),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: entry.key,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white70,
                                ),
                              ),
                              TextSpan(
                                text: '  ${entry.value}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: _projectAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _BookmarkPanel extends StatelessWidget {
  const _BookmarkPanel({
    required this.bookmarkCount,
    required this.bookmarkedMediaCount,
    required this.onOpen,
  });

  final int bookmarkCount;
  final int bookmarkedMediaCount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return _ProjectPanel(
      title: 'BOOKMARKS',
      icon: Icons.bookmark_border,
      child: Tooltip(
        message: 'Open bookmarked media in Explorer',
        child: InkWell(
          key: const ValueKey<String>('project-bookmarks-open'),
          onTap: bookmarkedMediaCount > 0 ? onOpen : null,
          mouseCursor: bookmarkedMediaCount > 0
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
            child: Row(
              children: [
                Expanded(
                  child: _BookmarkMeasure(
                    value: bookmarkCount,
                    label: 'MOMENTS',
                  ),
                ),
                Container(
                  width: 1,
                  height: 48,
                  color: Colors.white10,
                ),
                Expanded(
                  child: _BookmarkMeasure(
                    value: bookmarkedMediaCount,
                    label: 'MEDIA FILES',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BookmarkMeasure extends StatelessWidget {
  const _BookmarkMeasure({
    required this.value,
    required this.label,
  });

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: Colors.white38,
          ),
        ),
      ],
    );
  }
}

class _OverviewCountRow extends StatelessWidget {
  const _OverviewCountRow({
    super.key,
    required this.label,
    required this.count,
    this.leading,
    this.accent,
    this.onTap,
  });

  final String label;
  final int count;
  final Widget? leading;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: accent ?? Colors.white60,
                letterSpacing: label.contains('★') ? 0.7 : 0,
              ),
            ),
          ),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white38,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return content;
    }

    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      hoverColor: const Color(0x09FFFFFF),
      child: content,
    );
  }
}

class _ProjectEmptyState extends StatelessWidget {
  const _ProjectEmptyState(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Text(
        message,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white30,
        ),
      ),
    );
  }
}

String _ratingLabel(int rating) {
  final filled = List<String>.filled(rating, '★').join();
  final empty = List<String>.filled(5 - rating, '☆').join();
  return '$filled$empty';
}

Color _colorFromHex(String value) {
  final hex = value.replaceFirst('#', '');
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null || hex.length != 6) {
    return Colors.transparent;
  }
  return Color(0xFF000000 | parsed);
}
