// lib/ui/widgets/subtitle_overlay.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/srt_subtitle_service.dart';
import 'subtitle_search_sidebar.dart';

class SubtitleOverlay extends StatefulWidget {
  const SubtitleOverlay({
    super.key,
    required this.track,
    required this.positionMs,
    required this.enabled,
    required this.controlsVisible,
    required this.onSeek,
  });

  final SubtitleTrack? track;
  final int positionMs;
  final bool enabled;
  final bool controlsVisible;
  final ValueChanged<int> onSeek;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  bool _subtitlesVisible = true;
  bool _panelOpen = false;
  int _panelSession = 0;
  bool _keyboardHandlerRegistered = false;

  bool get _hasTrack => widget.track?.isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    _syncKeyboardHandler();
  }

  @override
  void didUpdateWidget(covariant SubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldPath = oldWidget.track?.path;
    final newPath = widget.track?.path;

    if (oldPath != newPath) {
      _subtitlesVisible = true;
      _panelOpen = false;
      _panelSession = 0;
    }

    _syncKeyboardHandler();
  }

  @override
  void dispose() {
    if (_keyboardHandlerRegistered) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    }
    super.dispose();
  }

  void _syncKeyboardHandler() {
    final shouldRegister = widget.enabled && _hasTrack;

    if (shouldRegister && !_keyboardHandlerRegistered) {
      HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
      _keyboardHandlerRegistered = true;
    } else if (!shouldRegister && _keyboardHandlerRegistered) {
      HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
      _keyboardHandlerRegistered = false;
    }
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || !widget.enabled || !_hasTrack) {
      return false;
    }

    final key = event.logicalKey;
    final controlPressed = HardwareKeyboard.instance.isControlPressed;
    final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    final altPressed = HardwareKeyboard.instance.isAltPressed;
    final primaryFocusContext = FocusManager.instance.primaryFocus?.context;
    final textInputFocused = primaryFocusContext != null &&
        (primaryFocusContext.widget is EditableText ||
            primaryFocusContext.findAncestorWidgetOfExactType<EditableText>() !=
                null);

    if (key == LogicalKeyboardKey.escape && _panelOpen) {
      _closePanel();
      return true;
    }

    if (controlPressed && key == LogicalKeyboardKey.keyF) {
      _openPanel();
      return true;
    }

    if (!textInputFocused &&
        !controlPressed &&
        !shiftPressed &&
        !altPressed &&
        key == LogicalKeyboardKey.keyC) {
      _toggleSubtitles();
      return true;
    }

    return false;
  }

  void _toggleSubtitles() {
    if (!_hasTrack) {
      return;
    }

    setState(() => _subtitlesVisible = !_subtitlesVisible);
  }

  void _togglePanel() {
    if (!_hasTrack) {
      return;
    }

    if (_panelOpen) {
      _closePanel();
    } else {
      _openPanel();
    }
  }

  void _openPanel() {
    if (!_hasTrack) {
      return;
    }

    setState(() {
      _panelOpen = true;
      _panelSession += 1;
    });
  }

  void _closePanel() {
    if (!_panelOpen) {
      return;
    }

    setState(() => _panelOpen = false);
  }

  void _seekToCue(int positionMs) {
    widget.onSeek(positionMs);
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = widget.track;
    if (!widget.enabled || currentTrack == null || currentTrack.isEmpty) {
      return const SizedBox.shrink();
    }

    final text = _subtitlesVisible
        ? currentTrack.textAt(widget.positionMs)
        : null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (text != null && text.isNotEmpty)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            left: 24,
            right: _panelOpen ? 456 : 24,
            bottom: widget.controlsVisible ? 132 : 42,
            child: IgnorePointer(
              child: Semantics(
                label: 'Subtitles',
                value: text,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xB8000000),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            height: 1.22,
                            fontWeight: FontWeight.w600,
                            shadows: <Shadow>[
                              Shadow(
                                blurRadius: 3,
                                offset: Offset(0, 1),
                                color: Colors.black,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (widget.controlsVisible && !_panelOpen)
          Positioned(
            right: 18,
            bottom: 94,
            child: _SubtitleQuickControls(
              subtitlesVisible: _subtitlesVisible,
              onToggleSubtitles: _toggleSubtitles,
              onTogglePanel: _togglePanel,
            ),
          ),
        if (_panelOpen)
          Positioned(
            top: 64,
            right: 16,
            bottom: 96,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              onDoubleTap: () {},
              onSecondaryTap: () {},
              child: SubtitleSearchSidebar(
                key: ValueKey<int>(_panelSession),
                track: currentTrack,
                positionMs: widget.positionMs,
                onSeek: _seekToCue,
                onClose: _closePanel,
                autofocusSearch: true,
              ),
            ),
          ),
      ],
    );
  }
}

class _SubtitleQuickControls extends StatelessWidget {
  const _SubtitleQuickControls({
    required this.subtitlesVisible,
    required this.onToggleSubtitles,
    required this.onTogglePanel,
  });

  final bool subtitlesVisible;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onTogglePanel;

  @override
  Widget build(BuildContext context) {
    final accentColor = Theme.of(context).colorScheme.primary;

    return Material(
      color: const Color(0xD91A1A1A),
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: subtitlesVisible
                ? 'Hide subtitles (C)'
                : 'Show subtitles (C)',
            child: InkWell(
              onTap: onToggleSubtitles,
              child: Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                color: subtitlesVisible
                    ? accentColor
                    : Colors.transparent,
                child: Text(
                  'CC',
                  style: TextStyle(
                    color: subtitlesVisible ? Colors.black : Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: 1,
            height: 22,
            color: Colors.white12,
          ),
          Tooltip(
            message: 'Search transcript (Ctrl+F)',
            child: InkWell(
              onTap: onTogglePanel,
              child: SizedBox(
                width: 38,
                height: 34,
                child: Icon(
                  Icons.manage_search,
                  size: 20,
                  color: accentColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
