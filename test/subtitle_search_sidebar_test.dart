// test/subtitle_search_sidebar_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/srt_subtitle_service.dart';
import 'package:mlt_player/ui/widgets/subtitle_search_sidebar.dart';

SubtitleTrack _trackWithDistantSearchResult() {
  return SubtitleTrack(
    path: '/tmp/search-reveal.srt',
    cues: List<SubtitleCue>.generate(300, (index) {
      final startMs = index * 1000;
      return SubtitleCue(
        startMs: startMs,
        endMs: startMs + 900,
        text: index == 264
            ? 'needle target cue'
            : 'ordinary cue $index with some transcript words',
      );
    }),
  );
}

Widget _harness({
  required SubtitleTrack track,
  required ValueChanged<int> onSeek,
}) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          height: 480,
          child: SubtitleSearchSidebar(
            track: track,
            positionMs: 0,
            onSeek: onSeek,
            onClose: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'search remains lazy and selected result is revealed in full transcript',
    (tester) async {
      int? soughtPosition;

      final track = _trackWithDistantSearchResult();

      await tester.pumpWidget(
        _harness(
          track: track,
          onSeek: (positionMs) => soughtPosition = positionMs,
        ),
      );

      final transcriptList = find.byKey(
        const ValueKey<String>('subtitle-transcript-list'),
      );
      expect(transcriptList, findsOneWidget);

      final searchField = find.byType(TextField);

      // A broad query matches nearly every cue. The ListView must still keep
      // only a small viewport worth of rows mounted.
      await tester.enterText(searchField, 'cue');
      await tester.pump();

      expect(
        find.textContaining('ordinary cue').evaluate().length,
        lessThan(300),
      );

      await tester.enterText(searchField, 'needle');
      await tester.pump();

      expect(find.text('needle target cue'), findsOneWidget);
      expect(find.text('1 match'), findsOneWidget);

      await tester.tap(find.text('needle target cue'));

      // Rebuild the unfiltered list, then run the post-frame deterministic
      // jump, then let the newly visible lazy children mount.
      await tester.pump();
      await tester.pump();

      expect(soughtPosition, 264000);

      final field = tester.widget<TextField>(searchField);
      expect(field.controller?.text, isEmpty);
      expect(find.text('1 match'), findsNothing);

      final target = find.byKey(
        ObjectKey(track.cues[264]),
      );
      expect(target, findsOneWidget);

      final listRect = tester.getRect(transcriptList);
      final targetRect = tester.getRect(target);

      expect(
        targetRect.bottom > listRect.top && targetRect.top < listRect.bottom,
        isTrue,
        reason: 'The selected cue should be visible in the full transcript.',
      );
    },
  );
}
