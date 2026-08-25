// test/srt_subtitle_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/srt_subtitle_service.dart';

void main() {
  group('SrtSubtitleService', () {
    test('parses standard SRT cues and multiline text', () {
      const source = '''1
00:00:01,000 --> 00:00:03,500
First line
Second line

2
00:00:04,000 --> 00:00:05,250
Hello world
''';

      final track = SrtSubtitleService.parse(source, path: '/tmp/movie.srt');

      expect(track.path, '/tmp/movie.srt');
      expect(track.cues, hasLength(2));
      expect(track.cues.first.startMs, 1000);
      expect(track.cues.first.endMs, 3500);
      expect(track.cues.first.text, 'First line\nSecond line');
      expect(track.textAt(999), isNull);
      expect(track.textAt(1000), 'First line\nSecond line');
      expect(track.textAt(3499), 'First line\nSecond line');
      expect(track.textAt(3500), isNull);
      expect(track.textAt(4000), 'Hello world');
    });

    test('accepts dot milliseconds and strips common formatting tags', () {
      const source = '''1
00:00:00.500 --> 00:00:02.000
<i>Hello</i><br>world &amp; friends
''';

      final track = SrtSubtitleService.parse(source);

      expect(track.cues, hasLength(1));
      expect(track.cues.single.startMs, 500);
      expect(track.cues.single.text, 'Hello\nworld & friends');
    });

    test('returns overlapping active cues in source order', () {
      const source = '''1
00:00:01,000 --> 00:00:05,000
A

2
00:00:02,000 --> 00:00:03,000
B
''';

      final track = SrtSubtitleService.parse(source);

      expect(track.textAt(2500), 'A\nB');
      expect(track.textAt(3500), 'A');
    });

    test('finds same-stem SRT beside media including uppercase extension', () async {
      final root = await Directory.systemTemp.createTemp('mlt_srt_test_');

      try {
        final media = File('${root.path}${Platform.pathSeparator}Movie.mp4');
        final subtitle = File('${root.path}${Platform.pathSeparator}Movie.SRT');
        await media.writeAsBytes(<int>[1]);
        await subtitle.writeAsString(
          '1\n00:00:00,000 --> 00:00:01,000\nFound\n',
        );

        final found = await SrtSubtitleService.findSidecarForMedia(media.path);
        expect(found?.absolute.path, subtitle.absolute.path);

        final track = await SrtSubtitleService.loadForMedia(media.path);
        expect(track?.textAt(500), 'Found');
      } finally {
        await root.delete(recursive: true);
      }
    });

    test('does not match language-suffixed or differently named SRT files', () async {
      final root = await Directory.systemTemp.createTemp('mlt_srt_test_');

      try {
        final media = File('${root.path}${Platform.pathSeparator}Movie.mp4');
        await media.writeAsBytes(<int>[1]);
        await File('${root.path}${Platform.pathSeparator}Movie.en.srt')
            .writeAsString('not an exact sidecar');
        await File('${root.path}${Platform.pathSeparator}Other.srt')
            .writeAsString('not an exact sidecar');

        final found = await SrtSubtitleService.findSidecarForMedia(media.path);
        expect(found, isNull);
      } finally {
        await root.delete(recursive: true);
      }
    });
  });
}
