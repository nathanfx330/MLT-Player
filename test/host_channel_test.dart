// test/host_channel_test.dart

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlt_player/services/host_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mlt_player/host');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('revealPath forwards the exact path to the Linux host', () async {
    MethodCall? captured;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return true;
    });

    final revealed = await HostChannel.revealPath('/tmp/example clip.mov');

    expect(revealed, isTrue);
    expect(captured?.method, 'revealPath');
    expect(captured?.arguments, '/tmp/example clip.mov');
  });

  test('revealPath reports host failure without throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'reveal-failed');
    });

    expect(
      await HostChannel.revealPath('/tmp/example.mov'),
      isFalse,
    );
  });

  test('revealPath ignores an empty path', () async {
    var called = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      called = true;
      return true;
    });

    expect(await HostChannel.revealPath('   '), isFalse);
    expect(called, isFalse);
  });
}
