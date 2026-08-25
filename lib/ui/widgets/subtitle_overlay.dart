// lib/ui/widgets/subtitle_overlay.dart

import 'package:flutter/material.dart';

import '../../services/srt_subtitle_service.dart';

class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.track,
    required this.positionMs,
    required this.enabled,
    required this.controlsVisible,
  });

  final SubtitleTrack? track;
  final int positionMs;
  final bool enabled;
  final bool controlsVisible;

  @override
  Widget build(BuildContext context) {
    final currentTrack = track;
    if (!enabled || currentTrack == null) {
      return const SizedBox.shrink();
    }

    final text = currentTrack.textAt(positionMs);
    if (text == null || text.isEmpty) {
      return const SizedBox.shrink();
    }

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      left: 24,
      right: 24,
      bottom: controlsVisible ? 132 : 42,
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
    );
  }
}
