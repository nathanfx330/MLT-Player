// test/text_prompt_dialog_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/ui/widgets/text_prompt_dialog.dart';

void main() {
  testWidgets(
    'text prompt keeps its controller alive through route dismissal',
    (tester) async {
      String? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showTextPromptDialog(
                      context,
                      title: 'New Catalog',
                      hint: 'Catalog name',
                    );
                  },
                  child: const Text('OPEN'),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Rocky Catalog');
      await tester.tap(find.text('SAVE'));

      // The route is still dismissing here. The TextField must retain a valid
      // controller until Flutter actually removes the dialog from the tree.
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(result, 'Rocky Catalog');
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('text prompt preserves select-all initial value behavior', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TextPromptDialog(
            title: 'Rename Catalog',
            hint: 'Catalog name',
            initialValue: 'Existing Catalog',
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    final controller = field.controller!;

    expect(controller.text, 'Existing Catalog');
    expect(controller.selection.baseOffset, 0);
    expect(controller.selection.extentOffset, 'Existing Catalog'.length);
  });
}
