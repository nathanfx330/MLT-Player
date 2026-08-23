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
    required this.secondaryIsStill,
    required this.secondaryHasAlpha,
    required this.secondaryAlphaMode,
    required this.primaryAudioGain,
    required this.secondaryAudioGain,
    required this.secondaryOpacity,
    required this.secondaryVisible,
    required this.secondaryX,
    required this.secondaryY,
    required this.secondaryScale,
    required this.baseWidth,
    required this.baseHeight,
    required this.canSwapLayers,
    required this.onPrimaryAudioChanged,
    required this.onSecondaryAudioChanged,
    required this.onSecondaryOpacityChanged,
    required this.onSecondaryAlphaModeChanged,
    required this.onSecondaryXChanged,
    required this.onSecondaryYChanged,
    required this.onSecondaryScaleChanged,
    required this.onSecondaryAnchorChanged,
    required this.onReplacePrimarySource,
    required this.onReplaceSecondarySource,
    required this.onToggleSecondaryVisible,
    required this.onSwapLayers,
    required this.onClose,
  });

  final String primaryName;
  final String secondaryName;
  final String secondaryStart;

  final bool primaryHasAudio;
  final bool secondaryHasAudio;
  final bool secondaryIsStill;
  final bool secondaryHasAlpha;
  final int secondaryAlphaMode;

  final double primaryAudioGain;
  final double secondaryAudioGain;
  final double secondaryOpacity;
  final bool secondaryVisible;
  final double secondaryX;
  final double secondaryY;
  final double secondaryScale;
  final int baseWidth;
  final int baseHeight;
  final bool canSwapLayers;

  final ValueChanged<double> onPrimaryAudioChanged;
  final ValueChanged<double> onSecondaryAudioChanged;
  final ValueChanged<double> onSecondaryOpacityChanged;
  final ValueChanged<int> onSecondaryAlphaModeChanged;
  final ValueChanged<double> onSecondaryXChanged;
  final ValueChanged<double> onSecondaryYChanged;
  final ValueChanged<double> onSecondaryScaleChanged;
  final ValueChanged<int> onSecondaryAnchorChanged;
  final VoidCallback onReplacePrimarySource;
  final VoidCallback onReplaceSecondarySource;
  final VoidCallback onToggleSecondaryVisible;
  final VoidCallback onSwapLayers;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final availableBodyHeight =
        (MediaQuery.sizeOf(context).height - 120)
            .clamp(280.0, 620.0)
            .toDouble();

    return Material(
      color: const Color(0xF2191919),
      elevation: 18,
      shadowColor: Colors.black87,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            const Divider(height: 1, color: Colors.white24),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: availableBodyHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LayerSection(
                      number: 1,
                      name: primaryName,
                      badge: 'BASE VIDEO',
                      start: '00:00:00:00',
                      videoLabel: 'BASE LAYER',
                      audioEnabled: primaryHasAudio,
                      audioGain: primaryAudioGain,
                      onAudioChanged: onPrimaryAudioChanged,
                      onReplaceSource: onReplacePrimarySource,
                    ),
                    const Divider(height: 1, color: Colors.white30),
                    _LayerSection(
                      number: 2,
                      name: secondaryName,
                      badge: secondaryIsStill ? 'STILL' : 'VIDEO',
                      start: secondaryStart,
                      videoOpacity: secondaryOpacity,
                      videoVisible: secondaryVisible,
                      sizeLabel: secondaryIsStill
                          ? '100% = NATIVE • FIT IF LARGER'
                          : '100% = FIT TO BASE FRAME',
                      positionX: secondaryX,
                      positionY: secondaryY,
                      scale: secondaryScale,
                      baseWidth: baseWidth,
                      baseHeight: baseHeight,
                      audioEnabled: secondaryHasAudio,
                      audioGain: secondaryAudioGain,
                      alphaMode: secondaryAlphaMode,
                      hasAlpha: secondaryHasAlpha,
                      onVideoOpacityChanged: onSecondaryOpacityChanged,
                      onPositionXChanged: onSecondaryXChanged,
                      onPositionYChanged: onSecondaryYChanged,
                      onScaleChanged: onSecondaryScaleChanged,
                      onAnchorChanged: onSecondaryAnchorChanged,
                      onAudioChanged: onSecondaryAudioChanged,
                      onAlphaModeChanged: onSecondaryAlphaModeChanged,
                      onReplaceSource: onReplaceSecondarySource,
                      onToggleVideoVisible: onToggleSecondaryVisible,
                    ),
                  ],
                ),
              ),
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
              'LAYERS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            const Text(
              '2 LAYERS',
              style: TextStyle(
                fontSize: 10,
                color: Colors.white54,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: canSwapLayers
                  ? 'Swap Layer 1 and Layer 2'
                  : 'A still image cannot become the base layer',
              child: IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 17,
                onPressed: canSwapLayers ? onSwapLayers : null,
                icon: Icon(
                  Icons.swap_vert,
                  color: canSwapLayers
                      ? const Color(0xFFE8A33D)
                      : Colors.white24,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close Layers Inspector',
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

class _LayerSection extends StatelessWidget {
  const _LayerSection({
    required this.number,
    required this.name,
    required this.badge,
    required this.start,
    this.videoLabel,
    required this.audioEnabled,
    required this.audioGain,
    required this.onAudioChanged,
    this.videoOpacity,
    this.videoVisible = true,
    this.sizeLabel,
    this.positionX,
    this.positionY,
    this.scale,
    this.baseWidth,
    this.baseHeight,
    this.alphaMode,
    this.hasAlpha,
    this.onVideoOpacityChanged,
    this.onPositionXChanged,
    this.onPositionYChanged,
    this.onScaleChanged,
    this.onAnchorChanged,
    this.onAlphaModeChanged,
    this.onToggleVideoVisible,
    required this.onReplaceSource,
  });

  final int number;
  final String name;
  final String badge;
  final String start;
  final String? videoLabel;
  final double? videoOpacity;
  final bool videoVisible;
  final String? sizeLabel;
  final double? positionX;
  final double? positionY;
  final double? scale;
  final int? baseWidth;
  final int? baseHeight;
  final bool audioEnabled;
  final double audioGain;
  final int? alphaMode;
  final bool? hasAlpha;
  final ValueChanged<double> onAudioChanged;
  final ValueChanged<double>? onVideoOpacityChanged;
  final ValueChanged<double>? onPositionXChanged;
  final ValueChanged<double>? onPositionYChanged;
  final ValueChanged<double>? onScaleChanged;
  final ValueChanged<int>? onAnchorChanged;
  final ValueChanged<int>? onAlphaModeChanged;
  final VoidCallback? onToggleVideoVisible;
  final VoidCallback onReplaceSource;

  bool get hasGeometry =>
      positionX != null &&
      positionY != null &&
      scale != null &&
      baseWidth != null &&
      baseHeight != null &&
      onPositionXChanged != null &&
      onPositionYChanged != null &&
      onScaleChanged != null &&
      onAnchorChanged != null;

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
                    'LAYER $number',
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
                const SizedBox(width: 4),
                if (onToggleVideoVisible != null)
                  IconButton(
                    tooltip: videoVisible
                        ? 'Hide Layer $number'
                        : 'Show Layer $number',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    onPressed: onToggleVideoVisible,
                    icon: Icon(
                      videoVisible
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: videoVisible
                          ? const Color(0xFFE8A33D)
                          : Colors.white30,
                    ),
                  ),
                IconButton(
                  tooltip: 'Replace Layer $number source',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: onReplaceSource,
                  icon: const Icon(
                    Icons.swap_horiz,
                    color: Colors.white60,
                  ),
                ),
                const SizedBox(width: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white12),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.7,
                      color: Colors.white38,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const _Rule(),
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
        const _Rule(),
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
                  icon: videoVisible
                      ? Icons.opacity
                      : Icons.visibility_off_outlined,
                  enabled: true,
                  subdued: !videoVisible,
                  onChanged: onVideoOpacityChanged!,
                ),
        ),
        if (sizeLabel != null) ...[
          const _Rule(),
          _InspectorLine(
            label: 'SIZE',
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                sizeLabel!,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.45,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
        ],
        if (hasGeometry) ...[
          const _Rule(),
          _InspectorBlock(
            label: 'ANCHOR',
            child: _AnchorControl(onChanged: onAnchorChanged!),
          ),
          const _Rule(),
          _InspectorLine(
            label: 'X',
            child: _PixelControl(
              value: positionX!,
              extent: baseWidth!,
              onChanged: onPositionXChanged!,
            ),
          ),
          const _Rule(),
          _InspectorLine(
            label: 'Y',
            child: _PixelControl(
              value: positionY!,
              extent: baseHeight!,
              onChanged: onPositionYChanged!,
            ),
          ),
          const _Rule(),
          _InspectorLine(
            label: 'SCALE',
            child: _ScaleControl(
              value: scale!,
              onChanged: onScaleChanged!,
            ),
          ),
        ],
        if (alphaMode != null) ...[
          const _Rule(),
          _InspectorLine(
            label: 'ALPHA',
            child: _AlphaControl(
              hasAlpha: hasAlpha ?? false,
              mode: alphaMode!,
              onChanged: onAlphaModeChanged!,
            ),
          ),
        ],
        const _Rule(),
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

class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 1,
      indent: 12,
      endIndent: 12,
      color: Colors.white12,
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

class _InspectorBlock extends StatelessWidget {
  const _InspectorBlock({
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 86,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 62,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
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
            ),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _AnchorControl extends StatelessWidget {
  const _AnchorControl({required this.onChanged});

  final ValueChanged<int> onChanged;

  static const List<IconData> _icons = <IconData>[
    Icons.north_west,
    Icons.north,
    Icons.north_east,
    Icons.west,
    Icons.center_focus_weak,
    Icons.east,
    Icons.south_west,
    Icons.south,
    Icons.south_east,
  ];

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 96,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (row) {
            return SizedBox(
              height: 24,
              child: Row(
                children: List<Widget>.generate(3, (column) {
                  final index = row * 3 + column;
                  return SizedBox(
                    width: 30,
                    height: 24,
                    child: IconButton(
                      tooltip: _anchorTooltip(index),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 22,
                      ),
                      visualDensity: VisualDensity.compact,
                      iconSize: 13,
                      onPressed: () => onChanged(index),
                      icon: Icon(
                        _icons[index],
                        color: const Color(0xFFE8A33D),
                      ),
                    ),
                  );
                }),
              ),
            );
          }),
        ),
      ),
    );
  }

  static String _anchorTooltip(int index) {
    return switch (index) {
      0 => 'Top left',
      1 => 'Top center',
      2 => 'Top right',
      3 => 'Center left',
      4 => 'Center',
      5 => 'Center right',
      6 => 'Bottom left',
      7 => 'Bottom center',
      8 => 'Bottom right',
      _ => 'Anchor',
    };
  }
}

class _PixelControl extends StatelessWidget {
  const _PixelControl({
    required this.value,
    required this.extent,
    required this.onChanged,
  });

  final double value;
  final int extent;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final canvasExtent = extent > 0 ? extent.toDouble() : 1.0;
    var minimum = -2.0 * canvasExtent;
    var maximum = canvasExtent;

    if (value < minimum) {
      minimum = value;
    }
    if (value > maximum) {
      maximum = value;
    }
    if (maximum <= minimum) {
      maximum = minimum + 1.0;
    }

    final applied = value.clamp(minimum, maximum).toDouble();

    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              min: minimum,
              max: maximum,
              value: applied,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 62,
          child: Text(
            '${value.round()} px',
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

class _ScaleControl extends StatelessWidget {
  const _ScaleControl({
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final applied = value.clamp(0.10, 3.0).toDouble();
    final percent = (applied * 100).round();

    return Row(
      children: [
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              min: 0.10,
              max: 3.0,
              value: applied,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 44,
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

class _AlphaControl extends StatelessWidget {
  const _AlphaControl({
    required this.hasAlpha,
    required this.mode,
    required this.onChanged,
  });

  final bool hasAlpha;
  final int mode;
  final ValueChanged<int> onChanged;

  static const Map<int, String> _labels = <int, String>{
    0: 'AUTO',
    1: 'STRAIGHT',
    2: 'PREMULTIPLIED',
  };

  @override
  Widget build(BuildContext context) {
    final appliedMode = mode.clamp(0, 2).toInt();

    return Row(
      children: [
        Icon(
          hasAlpha ? Icons.check_circle_outline : Icons.remove_circle_outline,
          size: 13,
          color: hasAlpha ? const Color(0xFFE8A33D) : Colors.white30,
        ),
        const SizedBox(width: 5),
        Text(
          hasAlpha ? 'DETECTED' : 'NOT DETECTED',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: hasAlpha ? Colors.white60 : Colors.white30,
          ),
        ),
        const Spacer(),
        Tooltip(
          message: 'How Layer 2 RGB should be interpreted relative to alpha',
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: appliedMode,
              isDense: true,
              dropdownColor: const Color(0xFF252525),
              iconEnabledColor: Colors.white54,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.45,
                color: Colors.white70,
              ),
              items: _labels.entries
                  .map(
                    (entry) => DropdownMenuItem<int>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  onChanged(value);
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _LevelControl extends StatelessWidget {
  const _LevelControl({
    required this.value,
    required this.icon,
    required this.enabled,
    this.subdued = false,
    required this.onChanged,
  });

  final double value;
  final IconData icon;
  final bool enabled;
  final bool subdued;
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
        Icon(
          icon,
          size: 14,
          color: subdued ? Colors.white30 : Colors.white54,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
              inactiveTrackColor:
                  subdued ? Colors.white12 : Colors.white24,
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
            style: TextStyle(
              fontSize: 10,
              color: subdued ? Colors.white38 : Colors.white70,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
