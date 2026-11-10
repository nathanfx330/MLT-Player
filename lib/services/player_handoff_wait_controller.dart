// lib/services/player_handoff_wait_controller.dart

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Keeps the existing thumbnail drain barrier intact while giving a delayed
/// visual signal when Player entry must wait for a slow native decode.
///
/// A newer request supersedes an older request, including one still awaiting
/// the barrier. There is deliberately no timeout: Player must not open while
/// any paused browser's MLT thumbnail work is still in flight.
class PlayerHandoffWaitController extends ChangeNotifier {
  PlayerHandoffWaitController({
    required Future<void> Function() waitForDrains,
    this.indicatorDelay = const Duration(milliseconds: 200),
  }) : _waitForDrains = waitForDrains;

  final Future<void> Function() _waitForDrains;
  final Duration indicatorDelay;
  Timer? _indicatorTimer;
  int _requestSerial = 0;
  bool _disposed = false;
  bool _showIndicator = false;

  bool get showIndicator => _showIndicator;

  Future<void> run(VoidCallback onReady) async {
    final serial = ++_requestSerial;

    _indicatorTimer?.cancel();
    // If a second click arrives during a visible wait, keep the indicator
    // visible rather than briefly hiding and reshowing it.
    if (!_showIndicator) {
      _indicatorTimer = Timer(indicatorDelay, () {
        if (!_disposed && serial == _requestSerial) {
          _setIndicatorVisible(true);
        }
      });
    }

    try {
      await _waitForDrains();
      if (!_disposed && serial == _requestSerial) {
        onReady();
      }
    } finally {
      if (!_disposed && serial == _requestSerial) {
        _indicatorTimer?.cancel();
        _indicatorTimer = null;
        _setIndicatorVisible(false);
      }
    }
  }

  void _setIndicatorVisible(bool visible) {
    if (_showIndicator == visible) return;
    _showIndicator = visible;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _requestSerial++;
    _indicatorTimer?.cancel();
    _indicatorTimer = null;
    super.dispose();
  }
}
