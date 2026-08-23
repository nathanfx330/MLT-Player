// lib/ui/widgets/tracks_inspector.dart

import 'dart:ui' as ui show FontFeature;

import 'package:flutter/material.dart';

class TracksInspector extends StatelessWidget {
  const TracksInspector({
    super.key,
    required this.primaryName,
    required this.secondaryName,
    required this.secondaryStart,
    required this.primaryHasAudio,
    required this.secondaryHasAudio,
    required this.primaryAudioGain,
    required this.secondaryAudioGain,
    required this.secondaryOpacity,
    required this.onPrimaryAudioChanged,
    required this.onSecondaryAudioChanged,
    required this.onSecondaryOpacityChanged,
    required this.onClose,
  });

  final String primaryName;
  final String secondaryName;
  final String secondaryStart;

  final bool primaryHasAudio;
  final bool secondaryHasAudio;

  final double primaryAudioGain;
  final double secondaryAudioGain;
  final double secondaryOpacity;

  final ValueChanged<double> onPrimaryAudioChanged;
  final ValueChanged<double> onSecondaryAudioChanged;
  final ValueChanged<double> onSecondaryOpacityChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2191919),
      elevation: 18,
      shadowColor: Colors.black87,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: 390,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            const Divider(height: 1, color: Colors.white24),
            _TrackSection(
              number: 1,
              name: primaryName,
              start: '00:00:00:00',
              videoLabel: 'BASE LAYER',
              audioEnabled: primaryHasAudio,
              audioGain: primaryAudioGain,
              onAudioChanged: onPrimaryAudioChanged,
            ),
            const Divider(height: 1, color: Colors.white30),
            _TrackSection(
              number: 2,
              name: secondaryName,
              start: secondaryStart,
              videoOpacity: secondaryOpacity,
              audioEnabled: secondaryHasAudio,
              audioGain: secondaryAudioGain,
              onVideoOpacityChanged: onSecondaryOpacityChanged,
              onAudioChanged: onSecondaryAudioChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            const Icon(
              Icons.layers_outlined,
              size: 16,
              color: Color(0xFFE8A33D),
            ),
            const SizedBox(width: 8),
            const Text(
              'TRACKS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            const Text(
              '2 TRACKS',
              style: TextStyle(
                fontSize: 10,
                color: Colors.white54,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Close Tracks Inspector',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: onClose,
              icon: const Icon(Icons.close, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackSection extends StatelessWidget {
  const _TrackSection({
    required this.number,
    required this.name,
    required this.start,
    this.videoLabel,
    required this.audioEnabled,
    required this.audioGain,
    required this.onAudioChanged,
    this.videoOpacity,
    this.onVideoOpacityChanged,
  });

  final int number;
  final String name;
  final String start;
  final String? videoLabel;
  final double? videoOpacity;
  final bool audioEnabled;
  final double audioGain;
  final ValueChanged<double> onAudioChanged;
  final ValueChanged<double>? onVideoOpacityChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 42,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 62,
                  child: Text(
                    'TRACK $number',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Color(0xFFE8A33D),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12, color: Colors.white12),
        _InspectorLine(
          label: 'START',
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              start,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white70,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12, color: Colors.white12),
        _InspectorLine(
          label: 'VIDEO',
          child: videoOpacity == null
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    videoLabel ?? '100%',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white54,
                      letterSpacing: 0.4,
                    ),
                  ),
                )
              : _LevelControl(
                  value: videoOpacity!,
                  icon: Icons.opacity,
                  enabled: true,
                  onChanged: onVideoOpacityChanged!,
                ),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12, color: Colors.white12),
        _InspectorLine(
          label: 'AUDIO',
          child: _LevelControl(
            value: audioGain,
            icon: audioEnabled ? Icons.volume_up : Icons.volume_off,
            enabled: audioEnabled,
            onChanged: onAudioChanged,
          ),
        ),
      ],
    );
  }
}

class _InspectorLine extends StatelessWidget {
  const _InspectorLine({
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.9,
                  color: Colors.white38,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _LevelControl extends StatelessWidget {
  const _LevelControl({
    required this.value,
    required this.icon,
    required this.enabled,
    required this.onChanged,
  });

  final double value;
  final IconData icon;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final applied = value.clamp(0.0, 1.0).toDouble();
    final percent = (applied * 100).round();

    if (!enabled) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'NO AUDIO',
          style: TextStyle(
            fontSize: 10,
            color: Colors.white30,
            letterSpacing: 0.4,
          ),
        ),
      );
    }

    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white54),
        const SizedBox(width: 4),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              min: 0,
              max: 1,
              value: applied,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '$percent%',
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.white70,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
