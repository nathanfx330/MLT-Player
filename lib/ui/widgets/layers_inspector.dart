// lib/ui/widgets/layers_inspector.dart

import 'dart:ui' as ui show FontFeature;

import 'package:flutter/material.dart';

import '../../services/player_engine.dart';

typedef LayerDoubleChanged = void Function(int layerIndex, double value);
typedef LayerIntChanged = void Function(int layerIndex, int value);
typedef LayerFrameNudge = void Function(int layerIndex, int deltaFrames);
typedef LayerAction = void Function(int layerIndex);

class LayersInspector extends StatelessWidget {
  const LayersInspector({
    super.key,
    required this.layers,
    required this.formatFrame,
    required this.baseWidth,
    required this.baseHeight,
    required this.canAddLayer,
    required this.reorderEnabled,
    required this.onAudioChanged,
    required this.onOpacityChanged,
    required this.onAlphaModeChanged,
    required this.onXChanged,
    required this.onYChanged,
    required this.onScaleChanged,
    required this.onAnchorChanged,
    required this.onStartNudge,
    required this.onEndNudge,
    required this.onSourceInNudge,
    required this.onSourceOutNudge,
    required this.onReplaceSource,
    required this.onToggleVisible,
    required this.onAddLayer,
    required this.onRemoveTopLayer,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onClose,
  });

  final List<CompositionLayerState> layers;
  final String Function(int frame) formatFrame;
  final int baseWidth;
  final int baseHeight;

  final bool canAddLayer;
  final bool reorderEnabled;

  final LayerDoubleChanged onAudioChanged;
  final LayerDoubleChanged onOpacityChanged;
  final LayerIntChanged onAlphaModeChanged;
  final LayerDoubleChanged onXChanged;
  final LayerDoubleChanged onYChanged;
  final LayerDoubleChanged onScaleChanged;
  final LayerIntChanged onAnchorChanged;
  final LayerFrameNudge onStartNudge;
  final LayerFrameNudge onEndNudge;
  final LayerFrameNudge onSourceInNudge;
  final LayerFrameNudge onSourceOutNudge;
  final LayerAction onReplaceSource;
  final LayerAction onToggleVisible;
  final VoidCallback onAddLayer;
  final VoidCallback onRemoveTopLayer;
  final LayerAction onMoveUp;
  final LayerAction onMoveDown;
  final VoidCallback onClose;

  String _displayName(CompositionLayerState layer) {
    final path = layer.path;
    if (path == null || path.isEmpty) {
      return 'Layer ${layer.index + 1}';
    }

    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty || parts.last.isEmpty ? path : parts.last;
  }

  @override
  Widget build(BuildContext context) {
    final visibleLayers = layers
        .where((CompositionLayerState layer) => layer.present)
        .toList(growable: false)
      ..sort(
        (CompositionLayerState a, CompositionLayerState b) =>
            b.visualPosition.compareTo(a.visualPosition),
      );
    final layerCount = visibleLayers.length;

    bool canMoveUp(CompositionLayerState layer) => reorderEnabled &&
        visibleLayers.any(
          (CompositionLayerState other) =>
              other.visualPosition > layer.visualPosition,
        );
    bool canMoveDown(CompositionLayerState layer) => reorderEnabled &&
        visibleLayers.any(
          (CompositionLayerState other) =>
              other.visualPosition < layer.visualPosition,
        );

    final availableBodyHeight =
        (MediaQuery.sizeOf(context).height - 120)
            .clamp(280.0, 720.0)
            .toDouble();

    final sections = <Widget>[];
    for (final layer in visibleLayers) {
      if (sections.isNotEmpty) {
        sections.add(const Divider(height: 1, color: Colors.white30));
      }

      if (layer.index == 0) {
        sections.add(
          _LayerSection(
            number: 1,
            name: _displayName(layer),
            badge: 'BASE VIDEO',
            start: '00:00:00:00',
            videoLabel: 'BASE LAYER',
            audioEnabled: layer.hasAudio,
            audioGain: layer.audioGain,
            onAudioChanged: (value) => onAudioChanged(layer.index, value),
            showOrderControls: true,
            canMoveUp: canMoveUp(layer),
            canMoveDown: canMoveDown(layer),
            onMoveUp: () => onMoveUp(layer.index),
            onMoveDown: () => onMoveDown(layer.index),
            onReplaceSource: () => onReplaceSource(layer.index),
          ),
        );
        continue;
      }

      sections.add(
        _LayerSection(
          number: layer.index + 1,
          name: _displayName(layer),
          badge: layer.isStill ? 'STILL' : 'VIDEO',
          start: formatFrame(layer.startFrame ?? 0),
          end: formatFrame(layer.endFrame ?? layer.startFrame ?? 0),
          onStartNudge: (delta) => onStartNudge(layer.index, delta),
          onEndNudge: (delta) => onEndNudge(layer.index, delta),
          sourceIn: !layer.isStill && layer.sourceInFrame != null
              ? formatFrame(layer.sourceInFrame!)
              : null,
          sourceOut: !layer.isStill && layer.sourceOutFrame != null
              ? formatFrame(layer.sourceOutFrame!)
              : null,
          onSourceInNudge: !layer.isStill
              ? (delta) => onSourceInNudge(layer.index, delta)
              : null,
          onSourceOutNudge: !layer.isStill
              ? (delta) => onSourceOutNudge(layer.index, delta)
              : null,
          videoOpacity: layer.opacity,
          videoVisible: layer.visible,
          sizeLabel: layer.isStill
              ? '100% = NATIVE • FIT IF LARGER'
              : '100% = FIT TO BASE FRAME',
          positionX: layer.x,
          positionY: layer.y,
          scale: layer.scale,
          baseWidth: baseWidth,
          baseHeight: baseHeight,
          audioEnabled: layer.hasAudio,
          audioGain: layer.audioGain,
          alphaMode: layer.alphaMode,
          hasAlpha: layer.hasAlpha,
          onVideoOpacityChanged: (value) => onOpacityChanged(layer.index, value),
          onPositionXChanged: (value) => onXChanged(layer.index, value),
          onPositionYChanged: (value) => onYChanged(layer.index, value),
          onScaleChanged: (value) => onScaleChanged(layer.index, value),
          onAnchorChanged: (anchor) => onAnchorChanged(layer.index, anchor),
          onAudioChanged: (value) => onAudioChanged(layer.index, value),
          onAlphaModeChanged: (mode) => onAlphaModeChanged(layer.index, mode),
          onReplaceSource: () => onReplaceSource(layer.index),
          onToggleVideoVisible: () => onToggleVisible(layer.index),
          showOrderControls: true,
          canMoveUp: canMoveUp(layer),
          canMoveDown: canMoveDown(layer),
          onMoveUp: () => onMoveUp(layer.index),
          onMoveDown: () => onMoveDown(layer.index),
        ),
      );
    }

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
            _buildHeader(layerCount),
            const Divider(height: 1, color: Colors.white24),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: availableBodyHeight),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: sections,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(int layerCount) {
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
            Text(
              '$layerCount LAYERS',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white54,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 3),
            IconButton(
              tooltip: canAddLayer
                  ? 'Add Layer ${layerCount + 1}'
                  : 'Maximum of ${layers.length} layers',
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              onPressed: canAddLayer ? onAddLayer : null,
              icon: Icon(
                Icons.add_circle_outline,
                color: canAddLayer
                    ? const Color(0xFFE8A33D)
                    : Colors.white24,
              ),
            ),
            IconButton(
              tooltip: layerCount >= 3
                  ? 'Remove Layer 3 — Undo restores it'
                  : 'Remove Layer 2 — Undo restores it',
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              onPressed: layerCount > 1 ? onRemoveTopLayer : null,
              icon: const Icon(
                Icons.remove_circle_outline,
                color: Colors.white60,
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
    this.end,
    this.onStartNudge,
    this.onEndNudge,
    this.sourceIn,
    this.sourceOut,
    this.onSourceInNudge,
    this.onSourceOutNudge,
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
    this.showOrderControls = false,
    this.canMoveUp = false,
    this.canMoveDown = false,
    this.onMoveUp,
    this.onMoveDown,
    required this.onReplaceSource,
  });

  final int number;
  final String name;
  final String badge;
  final String start;
  final String? end;
  final ValueChanged<int>? onStartNudge;
  final ValueChanged<int>? onEndNudge;
  final String? sourceIn;
  final String? sourceOut;
  final ValueChanged<int>? onSourceInNudge;
  final ValueChanged<int>? onSourceOutNudge;
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
  final bool showOrderControls;
  final bool canMoveUp;
  final bool canMoveDown;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
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
                if (showOrderControls) ...[
                  Tooltip(
                    message: canMoveUp
                        ? 'Move Layer $number up'
                        : 'Layer $number is already at the top',
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: canMoveUp ? onMoveUp : null,
                      icon: Icon(
                        Icons.keyboard_arrow_up,
                        color: canMoveUp
                            ? const Color(0xFFE8A33D)
                            : Colors.white24,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: canMoveDown
                        ? 'Move Layer $number down'
                        : 'Layer $number is already at the bottom',
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: canMoveDown ? onMoveDown : null,
                      icon: Icon(
                        Icons.keyboard_arrow_down,
                        color: canMoveDown
                            ? const Color(0xFFE8A33D)
                            : Colors.white24,
                      ),
                    ),
                  ),
                ],
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
                  icon: const Icon(Icons.swap_horiz, color: Colors.white60),
                ),
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
          child: onStartNudge == null
              ? Text(
                  start,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                )
              : _FrameNudgeControl(
                  value: start,
                  semanticLabel: 'layer start',
                  onNudge: onStartNudge!,
                ),
        ),
        if (end != null) ...[
          const _Rule(),
          _InspectorLine(
            label: 'END',
            child: _FrameNudgeControl(
              value: end!,
              semanticLabel: 'layer end',
              onNudge: onEndNudge!,
            ),
          ),
        ],
        if (sourceIn != null && onSourceInNudge != null) ...[
          const _Rule(),
          _InspectorLine(
            label: 'SRC IN',
            child: _FrameNudgeControl(
              value: sourceIn!,
              semanticLabel: 'source in',
              onNudge: onSourceInNudge!,
            ),
          ),
        ],
        if (sourceOut != null && onSourceOutNudge != null) ...[
          const _Rule(),
          _InspectorLine(
            label: 'SRC OUT',
            child: _FrameNudgeControl(
              value: sourceOut!,
              semanticLabel: 'source out',
              onNudge: onSourceOutNudge!,
            ),
          ),
        ],
        const _Rule(),
        _InspectorLine(
          label: 'VIDEO',
          child: videoOpacity == null
              ? Text(
                  videoLabel ?? '100%',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white54,
                    letterSpacing: 0.4,
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
  const _InspectorLine({required this.label, required this.child});

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

class _FrameNudgeControl extends StatelessWidget {
  const _FrameNudgeControl({
    required this.value,
    required this.semanticLabel,
    required this.onNudge,
  });

  final String value;
  final String semanticLabel;
  final ValueChanged<int> onNudge;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white70,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
        ),
        _NudgeButton(
          tooltip: 'Move $semanticLabel back 10 frames',
          icon: Icons.keyboard_double_arrow_left,
          onPressed: () => onNudge(-10),
        ),
        const SizedBox(width: 2),
        _NudgeButton(
          tooltip: 'Move $semanticLabel back 1 frame',
          icon: Icons.chevron_left,
          onPressed: () => onNudge(-1),
        ),
        const SizedBox(width: 2),
        _NudgeButton(
          tooltip: 'Move $semanticLabel forward 1 frame',
          icon: Icons.chevron_right,
          onPressed: () => onNudge(1),
        ),
        const SizedBox(width: 2),
        _NudgeButton(
          tooltip: 'Move $semanticLabel forward 10 frames',
          icon: Icons.keyboard_double_arrow_right,
          onPressed: () => onNudge(10),
        ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 15,
        onTap: onPressed,
        child: Container(
          width: 26,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white12),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Icon(icon, size: 16, color: Colors.white60),
        ),
      ),
    );
  }
}

class _InspectorBlock extends StatelessWidget {
  const _InspectorBlock({required this.label, required this.child});

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
          child: Slider(
            min: minimum,
            max: maximum,
            value: applied,
            onChanged: onChanged,
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
  const _ScaleControl({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final applied = value.clamp(0.10, 3.0).toDouble();
    return Row(
      children: [
        Expanded(
          child: Slider(
            min: 0.10,
            max: 3.0,
            value: applied,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(applied * 100).round()}%',
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
        DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: appliedMode,
            isDense: true,
            dropdownColor: const Color(0xFF252525),
            iconEnabledColor: Colors.white54,
            items: _labels.entries
                .map(
                  (entry) => DropdownMenuItem<int>(
                    value: entry.key,
                    child: Text(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.white70,
                      ),
                    ),
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
    if (!enabled) {
      return const Text(
        'NO AUDIO',
        style: TextStyle(
          fontSize: 10,
          color: Colors.white30,
          letterSpacing: 0.4,
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
          child: Slider(
            min: 0,
            max: 1,
            value: applied,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '${(applied * 100).round()}%',
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
