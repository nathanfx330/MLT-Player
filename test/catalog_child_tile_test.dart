// test/catalog_child_tile_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/ui/widgets/catalog_child_tile.dart';

void main() {
  testWidgets('catalog child tile shows its name and opens on click', (
    tester,
  ) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 190,
            height: 150,
            child: CatalogChildTile(
              name: 'Interviews',
              onTap: () => taps += 1,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Interviews'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);

    await tester.tap(find.text('Interviews'));
    expect(taps, 1);
  });

  testWidgets('catalog child tile keeps long names inside the tile', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 130,
            child: CatalogChildTile(
              name: 'A Very Long Nested Catalog Name That Needs Truncation',
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(
      find.text('A Very Long Nested Catalog Name That Needs Truncation'),
    );
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });
}
