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
  static const double _listVerticalPadding = 6;
  static const double _rowTextWidth = 344;
  static const double _rowVerticalPadding = 18;

  late final TextEditingController _searchController;
  late final FocusNode _searchFocus;
  late final ScrollController _scrollController;

  late List<String> _normalizedCueText;
  final Map<SubtitleCue, double> _cueExtentCache =
      Map<SubtitleCue, double>.identity();

  String _query = '';
  List<SubtitleCue>? _searchResults;
  double? _extentCacheTextScale;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocus = FocusNode(debugLabel: 'subtitle-search');
    _scrollController = ScrollController();
    _rebuildSearchIndex();
  }

  @override
  void didUpdateWidget(covariant SubtitleSearchSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.track.path != widget.track.path ||
        !identical(oldWidget.track.cues, widget.track.cues)) {
      _searchController.clear();
      _query = '';
      _searchResults = null;
      _cueExtentCache.clear();
      _extentCacheTextScale = null;
      _rebuildSearchIndex();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) {
          return;
        }
        _scrollController.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _rebuildSearchIndex() {
    _normalizedCueText = widget.track.cues
        .map((cue) => cue.text.toLowerCase())
        .toList(growable: false);
  }

  List<SubtitleCue> get _visibleCues =>
      _searchResults ?? widget.track.cues;

  void _updateQuery(String value) {
    final normalized = value.trim().toLowerCase();

    if (normalized.isEmpty) {
      setState(() {
        _query = value;
        _searchResults = null;
      });
      return;
    }

    final terms = normalized
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList(growable: false);

    final matches = <SubtitleCue>[];
    for (var index = 0; index < widget.track.cues.length; index++) {
      final text = _normalizedCueText[index];
      if (terms.every(text.contains)) {
        matches.add(widget.track.cues[index]);
      }
    }

    setState(() {
      _query = value;
      _searchResults = List<SubtitleCue>.unmodifiable(matches);
    });
  }

  void _submitSearch(String _) {
    final cues = _visibleCues;
    if (cues.isNotEmpty) {
      _selectCue(cues.first);
    }
  }

  void _selectCue(SubtitleCue cue) {
    final fullIndex = widget.track.cues.indexOf(cue);
    final wasSearching = _query.trim().isNotEmpty;

    if (wasSearching) {
      _searchController.clear();
      _searchFocus.unfocus();
      setState(() {
        _query = '';
        _searchResults = null;
      });
    }

    widget.onSeek(cue.startMs);

    if (wasSearching && fullIndex >= 0) {
      _scheduleRevealIndex(fullIndex);
    }
  }

  void _scheduleRevealIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      final position = _scrollController.position;
      final cueTop = _fullTranscriptOffsetForIndex(index);
      final desiredOffset = (cueTop - position.viewportDimension * 0.30)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();

      // Jump after the unfiltered list has laid out. Because this list uses
      // the same per-cue extents as the offset calculation, the requested cue
      // is mounted at a deterministic position without materializing the
      // entire transcript.
      _scrollController.jumpTo(desiredOffset);
    });
  }

  double _fullTranscriptOffsetForIndex(int index) {
    var offset = _listVerticalPadding;
    for (var cueIndex = 0; cueIndex < index; cueIndex++) {
      offset += _cueExtent(
        widget.track.cues[cueIndex],
        includeDivider: cueIndex > 0,
      );
    }
    return offset;
  }

  double _cueExtent(
    SubtitleCue cue, {
    required bool includeDivider,
  }) {
    final contentExtent = _cueContentExtent(cue);
    return contentExtent + (includeDivider ? 1 : 0);
  }

  double _cueContentExtent(SubtitleCue cue) {
    final textScaler = MediaQuery.textScalerOf(context);
    final textScale = textScaler.scale(1.0);

    if (_extentCacheTextScale != textScale) {
      _extentCacheTextScale = textScale;
      _cueExtentCache.clear();
    }

    final cached = _cueExtentCache[cue];
    if (cached != null) {
      return cached;
    }

    final textPainter = TextPainter(
      text: const TextSpan(
        style: TextStyle(
          fontSize: 12,
          height: 1.35,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
    );

    textPainter.text = TextSpan(
      text: cue.text,
      style: const TextStyle(
        fontSize: 12,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
    );
    textPainter.layout(maxWidth: _rowTextWidth);

    final timePainter = TextPainter(
      text: TextSpan(
        text: _formatTime(cue.startMs),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
    )..layout(maxWidth: 42);

    final contentHeight =
        textPainter.height > timePainter.height
            ? textPainter.height
            : timePainter.height;

    // Ceil so the fixed extent never clips a glyph because of fractional
    // font metrics.
    final extent = contentHeight.ceilToDouble() + _rowVerticalPadding;
    _cueExtentCache[cue] = extent;
    return extent;
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
    final accentColor = Theme.of(context).colorScheme.primary;
    final searching = _query.trim().isNotEmpty;

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
                onChanged: _updateQuery,
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
                            setState(() {
                              _query = '';
                              _searchResults = null;
                            });
                            _searchFocus.requestFocus();
                          },
                          icon: const Icon(Icons.close),
                        ),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0x12FFFFFF),
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
                          searching
                              ? 'No transcript matches.'
                              : 'No subtitle cues.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey<String>('subtitle-transcript-list'),
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        vertical: _listVerticalPadding,
                      ),
                      itemCount: cues.length,
                      itemExtentBuilder: (index, _) => _cueExtent(
                        cues[index],
                        includeDivider: index > 0,
                      ),
                      itemBuilder: (context, index) {
                        final cue = cues[index];
                        final active = cue.isActiveAt(widget.positionMs);

                        return Column(
                          children: [
                            if (index > 0)
                              const Divider(
                                height: 1,
                                indent: 62,
                                color: Colors.white10,
                              ),
                            Expanded(
                              child: _TranscriptCueRow(
                                key: ObjectKey(cue),
                                cue: cue,
                                active: active,
                                accentColor: accentColor,
                                onTap: () => _selectCue(cue),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            if (searching)
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

class _TranscriptCueRow extends StatelessWidget {
  const _TranscriptCueRow({
    super.key,
    required this.cue,
    required this.active,
    required this.accentColor,
    required this.onTap,
  });

  final SubtitleCue cue;
  final bool active;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? accentColor.withAlpha(0x26) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  _SubtitleSearchSidebarState._formatTime(cue.startMs),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
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
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? Colors.white : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
