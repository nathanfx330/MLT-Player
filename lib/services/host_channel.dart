// lib/services/host_channel.dart

import 'package:flutter/services.dart';

/// Talks to the GTK runner for the things Dart cannot reach: the external
/// texture id, window state, and files dropped onto the window.
class HostChannel {
  HostChannel({
    required this.onTextureRegistered,
    required this.onPathOpened,
  }) {
    _channel.setMethodCallHandler(_handle);
  }

  static const MethodChannel _channel = MethodChannel('mlt_player/host');

  final void Function(int textureId) onTextureRegistered;
  final void Function(String path) onPathOpened;

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'textureRegistered':
        final id = call.arguments as int?;
        if (id != null) {
          onTextureRegistered(id);
        }
        return null;
      case 'openPath':
        final path = call.arguments as String?;
        if (path != null && path.isNotEmpty) {
          onPathOpened(path);
        }
        return null;
      default:
        throw MissingPluginException('Unknown method ${call.method}');
    }
  }

  Future<int> textureId() async {
    try {
      final id = await _channel.invokeMethod<int>('getTextureId');
      return id ?? -1;
    } on PlatformException {
      return -1;
    } on MissingPluginException {
      return -1;
    }
  }

  Future<void> setFullscreen(bool fullscreen) async {
    try {
      await _channel.invokeMethod<void>('setFullscreen', fullscreen);
    } on PlatformException {
      // The window simply stays as it is.
    } on MissingPluginException {
      // Ditto.
    }
  }
}
