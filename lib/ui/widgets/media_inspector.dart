// lib/ui/widgets/media_inspector.dart

import 'package:flutter/material.dart';

import '../../models/media_info.dart';

class MediaInspector extends StatelessWidget {
  const MediaInspector({super.key, required this.media});

  final MediaInfo media;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      _InfoItem(
        label: 'Resolution',
        value: media.hasVideo ? '${media.width} x ${media.height}' : 'None',
      ),
      _InfoItem(
        label: 'Display aspect',
        value: media.displayAspect > 0
            ? media.displayAspect.toStringAsFixed(4) +
                (media.isAnamorphic ? '  (anamorphic)' : '')
            : 'Unknown',
      ),
      _InfoItem(
        label: 'Frame rate',
        value: media.fps > 0 ? '${media.fps.toStringAsFixed(3)} fps' : 'None',
      ),
      _InfoItem(
        label: 'Frames',
        value: media.frames > 0 ? media.frames.toString() : 'None',
      ),
      if (media.dataSizeLabel != null)
        _InfoItem(
          label: 'Data size',
          value: media.dataSizeLabel!,
        ),
      if (media.averageDataRateLabel != null)
        _InfoItem(
          label: 'Avg data rate',
          value: media.averageDataRateLabel!,
        ),
      if (media.streamCount > 0)
        _InfoItem(
          label: 'Streams',
          value: '${media.streamCount} total',
        ),
      if (media.videoStreamIndex >= 0)
        _InfoItem(
          label: 'Video stream',
          value: 'Index ${media.videoStreamIndex}',
        ),
      if (media.videoCodecLabel != null)
        _InfoItem(
          label: 'Video codec',
          value: media.videoCodecLabel!,
        ),
      if (media.videoPixelFormat.isNotEmpty)
        _InfoItem(
          label: 'Pixel format',
          value: media.videoPixelFormat,
        ),
      if (media.videoColorspaceLabel != null)
        _InfoItem(
          label: 'Color space',
          value: media.videoColorspaceLabel!,
        ),
      if (media.videoColorTrcLabel != null)
        _InfoItem(
          label: 'Transfer',
          value: media.videoColorTrcLabel!,
        ),
      if (media.videoColorRange.isNotEmpty)
        _InfoItem(
          label: 'Color range',
          value: media.videoColorRange,
        ),
      if (media.audioStreamIndex >= 0)
        _InfoItem(
          label: 'Audio stream',
          value: 'Index ${media.audioStreamIndex}',
        ),
      if (media.audioCodecLabel != null)
        _InfoItem(
          label: 'Audio codec',
          value: media.audioCodecLabel!,
        ),
      for (final stream in media.streams)
        _InfoItem(
          label: 'Stream ${stream.index} · ${stream.typeLabel}',
          value: stream.detailLabel,
        ),
      if (media.sourceTimecode != null)
        _InfoItem(
          label: 'Source timecode',
          value: media.sourceTimecode!.raw,
        ),
      _InfoItem(
        label: 'Audio',
        value: media.hasAudio ? 'Present' : 'None',
      ),
      _InfoItem(
        label: 'Kind',
        value: media.isStill ? 'Still image' : 'Timed media',
      ),
    ];

    final maxPanelHeight = MediaQuery.sizeOf(context).height * 0.58;

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxPanelHeight),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xE01A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              media.name,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SelectableText(
              media.path,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
            const SizedBox(height: 14),
            Wrap(spacing: 28, runSpacing: 14, children: items),
          ],
        ),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 0.8,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
