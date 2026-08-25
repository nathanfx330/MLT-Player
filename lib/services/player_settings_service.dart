// lib/services/player_settings_service.dart

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';

class PlayerSettingsService extends ChangeNotifier {
  PlayerSettingsService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  static const int defaultAccentArgb = 0xFFE8A33D;

  final Directory _configDirectory;
  Future<void> _writeTail = Future<void>.value();

  int _accentArgb = defaultAccentArgb;

  int get accentArgb => _accentArgb;
  Color get accentColor => Color(_accentArgb);

  Future<void> load() async {
    final file = _stateFile;
    if (!await file.exists()) {
      return;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final rawAccent = decoded['accentArgb'];
      if (rawAccent is! int || !_isUsableArgb(rawAccent)) {
        return;
      }

      if (_accentArgb != rawAccent) {
        _accentArgb = rawAccent;
        notifyListeners();
      }
    } catch (_) {
      // Player appearance is convenience state. A damaged settings file must
      // never prevent MLT Player from starting with its default accent.
    }
  }

  Future<void> setAccentArgb(int value) {
    if (!_isUsableArgb(value) || value == _accentArgb) {
      return Future<void>.value();
    }

    _accentArgb = value;
    notifyListeners();
    return save();
  }

  Future<void> resetAccent() => setAccentArgb(defaultAccentArgb);

  Future<void> save() {
    final contents = jsonEncode(<String, Object>{
      'version': 1,
      'accentArgb': _accentArgb,
    });

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later settings write should still run after an earlier I/O error.
      }

      await _configDirectory.create(recursive: true);
      await _stateFile.writeAsString(contents, flush: true);
    }();

    return _writeTail;
  }

  File get _stateFile =>
      File('${_configDirectory.path}/player_settings.json');

  static bool _isUsableArgb(int value) =>
      value >= 0 &&
      value <= 0xFFFFFFFF &&
      (value & 0xFF000000) != 0;

  static Directory _defaultConfigDirectory() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.trim().isNotEmpty) {
      return Directory('${xdg.trim()}/mlt_player');
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.trim().isNotEmpty) {
      return Directory('${home.trim()}/.config/mlt_player');
    }

    return Directory('${Directory.systemTemp.path}/mlt_player');
  }
}
