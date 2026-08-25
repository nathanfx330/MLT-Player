// test/player_settings_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/player_settings_service.dart';

void main() {
  test('player accent persists and restores', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mlt-player-settings-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final writer = PlayerSettingsService(configDirectory: directory);
    expect(
      writer.accentArgb,
      PlayerSettingsService.defaultAccentArgb,
    );

    await writer.setAccentArgb(0xFF5AA9E6);

    final reader = PlayerSettingsService(configDirectory: directory);
    await reader.load();

    expect(reader.accentArgb, 0xFF5AA9E6);
  });

  test('invalid settings leave the default accent intact', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mlt-player-settings-invalid-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await File('${directory.path}/player_settings.json').writeAsString(
      '{"version":1,"accentArgb":0}',
    );

    final settings = PlayerSettingsService(configDirectory: directory);
    await settings.load();

    expect(
      settings.accentArgb,
      PlayerSettingsService.defaultAccentArgb,
    );
  });
}
