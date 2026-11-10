// test/player_handoff_wait_indicator_test.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_handoff_wait_controller.dart';
import 'package:mlt_player/ui/widgets/player_handoff_wait_indicator.dart';

Widget _harness({
  required PlayerHandoffWaitController controller,
  required VoidCallback onOpen,
  VoidCallback? onNavigate,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton(
                onPressed: onOpen,
                child: const Text('OPEN PLAYER'),
              ),
              if (onNavigate != null)
                TextButton(
                  onPressed: onNavigate,
                  child: const Text('NAVIGATE'),
                ),
            ],
          ),
          Positioned(
            right: 18,
            bottom: 18,
            child: PlayerHandoffWaitIndicator(controller: controller),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('slow thumbnail drain shows feedback without opening Player',
      (tester) async {
    final releaseDrain = Completer<void>();
    final controller = PlayerHandoffWaitController(
      waitForDrains: () => releaseDrain.future,
    );
    addTearDown(controller.dispose);

    var playerOpens = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      onOpen: () => unawaited(controller.run(() => playerOpens++)),
    ));

    await tester.tap(find.text('OPEN PLAYER'));
    await tester.pump();
    expect(find.text('Finishing thumbnail…'), findsNothing);
    expect(playerOpens, 0);

    await tester.pump(const Duration(milliseconds: 199));
    expect(find.text('Finishing thumbnail…'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('Finishing thumbnail…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(playerOpens, 0);

    // A deliberately long decode is never bypassed by the indicator.
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('Finishing thumbnail…'), findsOneWidget);
    expect(playerOpens, 0);

    releaseDrain.complete();
    await tester.pump();
    expect(playerOpens, 1);
    expect(find.text('Finishing thumbnail…'), findsNothing);
  });

  testWidgets('instant drain opens Player without flashing an indicator',
      (tester) async {
    final controller = PlayerHandoffWaitController(
      waitForDrains: () async {},
    );
    addTearDown(controller.dispose);

    var playerOpens = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      onOpen: () => unawaited(controller.run(() => playerOpens++)),
    ));

    await tester.tap(find.text('OPEN PLAYER'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(playerOpens, 1);
    expect(find.text('Finishing thumbnail…'), findsNothing);
  });

  test('new Player click supersedes a stale pending handoff', () async {
    final firstDrain = Completer<void>();
    final secondDrain = Completer<void>();
    var waitCalls = 0;
    final controller = PlayerHandoffWaitController(
      waitForDrains: () {
        waitCalls++;
        return waitCalls == 1 ? firstDrain.future : secondDrain.future;
      },
    );

    final openedPaths = <String>[];
    final first = controller.run(() => openedPaths.add('first.mp4'));
    final second = controller.run(() => openedPaths.add('second.mp4'));

    firstDrain.complete();
    await first;
    expect(openedPaths, isEmpty);

    secondDrain.complete();
    await second;
    expect(openedPaths, <String>['second.mp4']);
    controller.dispose();
  });

  testWidgets('switching tabs cancels the wait and removes its indicator',
      (tester) async {
    final releaseDrain = Completer<void>();
    final controller = PlayerHandoffWaitController(
      waitForDrains: () => releaseDrain.future,
    );
    addTearDown(controller.dispose);

    var playerOpens = 0;
    await tester.pumpWidget(_harness(
      controller: controller,
      onOpen: () => unawaited(controller.run(() => playerOpens++)),
      onNavigate: controller.cancel,
    ));

    await tester.tap(find.text('OPEN PLAYER'));
    await tester.pump(const Duration(milliseconds: 210));
    expect(find.text('Finishing thumbnail…'), findsOneWidget);

    await tester.tap(find.text('NAVIGATE'));
    await tester.pump();
    expect(find.text('Finishing thumbnail…'), findsNothing);

    // Navigation does not cancel the MLT decode, only the Player request.
    releaseDrain.complete();
    await tester.pump();
    expect(playerOpens, 0);
  });

  testWidgets('switching projects and returning never revives the old open',
      (tester) async {
    final releaseDrain = Completer<void>();
    final controller = PlayerHandoffWaitController(
      waitForDrains: () => releaseDrain.future,
    );
    addTearDown(controller.dispose);

    var activeProject = 'redleaf:A';
    final openedProjects = <String>[];
    await tester.pumpWidget(_harness(
      controller: controller,
      onOpen: () {
        final requestedProject = activeProject;
        unawaited(controller.run(
          () => openedProjects.add(requestedProject),
          isStillCurrent: () => activeProject == requestedProject,
        ));
      },
      onNavigate: () {
        activeProject = 'redleaf:B';
        controller.cancel();
      },
    ));

    await tester.tap(find.text('OPEN PLAYER'));
    await tester.pump(const Duration(milliseconds: 210));
    expect(find.text('Finishing thumbnail…'), findsOneWidget);

    await tester.tap(find.text('NAVIGATE'));
    await tester.pump();
    expect(find.text('Finishing thumbnail…'), findsNothing);

    activeProject = 'redleaf:A';
    releaseDrain.complete();
    await tester.pump();
    expect(openedProjects, isEmpty);
  });

  test('original project identity is rechecked after the thumbnail drain',
      () async {
    final releaseDrain = Completer<void>();
    var activeProject = 'redleaf:A';
    final controller = PlayerHandoffWaitController(
      waitForDrains: () => releaseDrain.future,
    );
    var playerOpens = 0;

    // Even if a navigation call site forgets to cancel, never open A's
    // media using B's current metadata project.
    final requestedProject = activeProject;
    final pending = controller.run(
      () => playerOpens++,
      isStillCurrent: () => activeProject == requestedProject,
    );
    activeProject = 'redleaf:B';
    releaseDrain.complete();
    await pending;
    expect(playerOpens, 0);
    controller.dispose();
  });

  test('cancelled request does not block a subsequent valid request', () async {
    final firstDrain = Completer<void>();
    final secondDrain = Completer<void>();
    var calls = 0;
    final controller = PlayerHandoffWaitController(
      waitForDrains: () => ++calls == 1 ? firstDrain.future : secondDrain.future,
    );
    final opened = <String>[];

    final oldRequest = controller.run(() => opened.add('old.mp4'));
    controller.cancel();
    final newRequest = controller.run(() => opened.add('new.mp4'));

    firstDrain.complete();
    await oldRequest;
    expect(opened, isEmpty);

    secondDrain.complete();
    await newRequest;
    expect(opened, <String>['new.mp4']);
    controller.dispose();
  });

  test('disposed shell never opens Player when a drain completes', () async {
    final releaseDrain = Completer<void>();
    final controller = PlayerHandoffWaitController(
      waitForDrains: () => releaseDrain.future,
    );
    var playerOpens = 0;
    final pending = controller.run(() => playerOpens++);

    controller.dispose();
    releaseDrain.complete();
    await pending;
    expect(playerOpens, 0);
  });
}
