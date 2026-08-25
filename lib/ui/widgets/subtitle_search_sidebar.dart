// lib/ui/widgets/subtitle_search_sidebar.dart

import 'package:flutter/material.dart';

import '../../services/srt_subtitle_service.dart';

class SubtitleSearchSidebar extends StatefulWidget {
  const SubtitleSearchSidebar({
    super.key,
    required this.track,
    required this.positionMs,
    required this.onSeek,
    required this.onClose,
    this.autofocusSearch = false,
  });

  final SubtitleTrack track;
  final int positionMs;
  final ValueChanged<int> onSeek;
  final VoidCallback onClose;
  final bool autofocusSearch;

  @override
  State<SubtitleSearchSidebar> createState() => _SubtitleSearchSidebarState();
}

class _SubtitleSearchSidebarState extends State<SubtitleSearchSidebar> {
  late final TextEditingController _searchController;
  late final FocusNode _searchFocus;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocus = FocusNode(debugLabel: 'subtitle-search');
  }

  @override
  void didUpdateWidget(covariant SubtitleSearchSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.track.path != widget.track.path) {
      _searchController.clear();
      _query = '';
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<SubtitleCue> get _visibleCues {
    final normalized = _query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return widget.track.cues;
    }

    final terms = normalized
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList(growable: false);

    return widget.track.cues.where((cue) {
      final text = cue.text.toLowerCase();
      return terms.every(text.contains);
    }).toList(growable: false);
  }

  void _submitSearch(String _) {
    final cues = _visibleCues;
    if (cues.isNotEmpty) {
      widget.onSeek(cues.first.startMs);
    }
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

  @override
  Widget build(BuildContext context) {
    final cues = _visibleCues;

    return Material(
      color: const Color(0xF21A1A1A),
      elevation: 18,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.subtitles_outlined,
                    size: 18,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Transcript',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.track.cues.length} cues',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Close transcript',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                autofocus: widget.autofocusSearch,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                onSubmitted: _submitSearch,
                decoration: InputDecoration(
                  hintText: 'Search transcript',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          iconSize: 17,
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                            _searchFocus.requestFocus();
                          },
                          icon: const Icon(Icons.close),
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.07),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 11,
                  ),
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: cues.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _query.trim().isEmpty
                              ? 'No subtitle cues.'
                              : 'No transcript matches.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: cues.length,
                      separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        indent: 62,
                        color: Colors.white10,
                      ),
                      itemBuilder: (context, index) {
                        final cue = cues[index];
                        final active = cue.isActiveAt(widget.positionMs);

                        return Material(
                          color: active
                              ? const Color(0x26E8A33D)
                              : Colors.transparent,
                          child: InkWell(
                            onTap: () => widget.onSeek(cue.startMs),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 42,
                                    child: Text(
                                      _formatTime(cue.startMs),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: active
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: active
                                            ? const Color(0xFFE8A33D)
                                            : Colors.white38,
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
                                        fontWeight: active
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: active
                                            ? Colors.white
                                            : Colors.white70,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_query.trim().isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Colors.white10),
                  ),
                ),
                child: Text(
                  '${cues.length} ${cues.length == 1 ? 'match' : 'matches'}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
