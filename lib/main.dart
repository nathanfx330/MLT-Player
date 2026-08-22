// lib/main.dart

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:ui' show FontFeature;

import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// Native bindings
// ---------------------------------------------------------------------------

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

typedef _Int64Native = Int64 Function();
typedef _Int64Dart = int Function();

typedef _DoubleNative = Double Function();
typedef _DoubleDart = double Function();

typedef _StringNative = Pointer<Utf8> Function();
typedef _StringDart = Pointer<Utf8> Function();

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _OpenNative = Int32 Function(Pointer<Utf8>);
typedef _OpenDart = int Function(Pointer<Utf8>);

typedef _SeekNative = Int32 Function(Int64);
typedef _SeekDart = int Function(int);

typedef _SetVolumeNative = Void Function(Double);
typedef _SetVolumeDart = void Function(double);

/// Thin wrapper over libmlt_bridge.so.
///
/// The library is resolved out of the running process rather than opened
/// by path. The Linux runner already links it, so it is loaded before Dart
/// starts, and looking it up this way guarantees Dart and the runner share
/// one copy of the bridge's state. Opening it by path would work only as
/// long as the path resolved to the same file the runner linked, and the
/// failure mode when it does not is silent: two independent players, one
/// of which owns the texture and the other of which owns the media.
class MltBridge {
  MltBridge() : _library = DynamicLibrary.process() {
    _init = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_init');
    _shutdown =
        _library.lookupFunction<_VoidNative, _VoidDart>('mlt_bridge_shutdown');
    _version = _library
        .lookupFunction<_StringNative, _StringDart>('mlt_bridge_version');
    _lastError = _library
        .lookupFunction<_StringNative, _StringDart>('mlt_bridge_last_error');

    _textureId = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_texture_id');

    _open = _library.lookupFunction<_OpenNative, _OpenDart>('mlt_bridge_open');
    _closeMedia = _library
        .lookupFunction<_VoidNative, _VoidDart>('mlt_bridge_close_media');

    _play = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_play');
    _pause = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_pause');
    _seek = _library.lookupFunction<_SeekNative, _SeekDart>('mlt_bridge_seek_ms');

    _positionMs = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_position_ms');
    _isPlaying =
        _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_is_playing');
    _isEof = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_is_eof');

    _setVolume = _library.lookupFunction<_SetVolumeNative, _SetVolumeDart>(
        'mlt_bridge_set_volume');
    _volume = _library
        .lookupFunction<_DoubleNative, _DoubleDart>('mlt_bridge_volume');
    _hasAudio =
        _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_has_audio');

    _durationFrames = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_duration_frames');
    _durationMs = _library
        .lookupFunction<_Int64Native, _Int64Dart>('mlt_bridge_duration_ms');
    _fps = _library.lookupFunction<_DoubleNative, _DoubleDart>('mlt_bridge_fps');
    _width = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_width');
    _height = _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_height');
    _displayAspect = _library.lookupFunction<_DoubleNative, _DoubleDart>(
        'mlt_bridge_display_aspect');
    _isStill =
        _library.lookupFunction<_IntNative, _IntDart>('mlt_bridge_is_still');
  }

  final DynamicLibrary _library;

  late final _IntDart _init;
  late final _VoidDart _shutdown;
  late final _StringDart _version;
  late final _StringDart _lastError;
  late final _Int64Dart _textureId;
  late final _OpenDart _open;
  late final _VoidDart _closeMedia;
  late final _IntDart _play;
  late final _IntDart _pause;
  late final _SeekDart _seek;
  late final _Int64Dart _positionMs;
  late final _IntDart _isPlaying;
  late final _IntDart _isEof;
  late final _SetVolumeDart _setVolume;
  late final _DoubleDart _volume;
  late final _IntDart _hasAudio;
  late final _Int64Dart _durationFrames;
  late final _Int64Dart _durationMs;
  late final _DoubleDart _fps;
  late final _IntDart _width;
  late final _IntDart _height;
  late final _DoubleDart _displayAspect;
  late final _IntDart _isStill;

  bool initialize() => _init() != 0;
  void shutdown() => _shutdown();

  String get version => _version().toDartString();
  String get lastError => _lastError().toDartString();

  int get textureId => _textureId();

  bool open(String path) {
    final nativePath = path.toNativeUtf8(allocator: malloc);
    try {
      return _open(nativePath) != 0;
    } finally {
      malloc.free(nativePath);
    }
  }

  void closeMedia() => _closeMedia();

  bool play() => _play() != 0;
  bool pause() => _pause() != 0;
  bool seekMs(int milliseconds) => _seek(milliseconds) != 0;

  int get positionMs => _positionMs();
  bool get isPlaying => _isPlaying() != 0;
  bool get isEof => _isEof() != 0;

  set volume(double value) => _setVolume(value);
  double get volume => _volume();
  bool get hasAudio => _hasAudio() != 0;

  int get durationFrames => _durationFrames();
  int get durationMs => _durationMs();
  double get fps => _fps();
  int get width => _width();
  int get height => _height();
  double get displayAspect => _displayAspect();
  bool get isStill => _isStill() != 0;
}

/// Entry point for the helper isolate that performs the open.
///
/// Opening a file probes the container twice and starts the audio consumer,
/// which takes long enough to be visible as a stall. Running it here keeps
/// the frame pump alive so the progress indicator is honest.
///
/// The isolate looks the library up in the same process, so it operates on
/// exactly the same engine state as the main isolate. The native side
/// serialises the call.
bool _openOnHelperIsolate(String path) => MltBridge().open(path);

// ---------------------------------------------------------------------------
// Host channel
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class MediaInfo {
  const MediaInfo({
    required this.path,
    required this.width,
    required this.height,
    required this.displayAspect,
    required this.fps,
    required this.frames,
    required this.durationMs,
    required this.hasAudio,
    required this.isStill,
  });

  final String path;
  final int width;
  final int height;
  final double displayAspect;
  final double fps;
  final int frames;
  final int durationMs;
  final bool hasAudio;
  final bool isStill;

  String get name {
    final normalised = path.replaceAll('\\', '/');
    final slash = normalised.lastIndexOf('/');
    return slash == -1 ? normalised : normalised.substring(slash + 1);
  }

  bool get hasVideo => width > 0 && height > 0;

  /// Pixel dimensions divided by display aspect tells you whether the
  /// source is anamorphic, which the viewport has to correct for.
  bool get isAnamorphic {
    if (!hasVideo || displayAspect <= 0) {
      return false;
    }
    final pixelAspect = width / height;
    return (pixelAspect - displayAspect).abs() > 0.01;
  }

  double get viewportAspect {
    if (displayAspect > 0) {
      return displayAspect;
    }
    if (hasVideo) {
      return width / height;
    }
    return 16 / 9;
  }
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Owns the native player and the polling loop, and nothing about layout.
class PlayerEngine extends ChangeNotifier {
  PlayerEngine(this.bridge, {required this.initialized}) {
    _volume = initialized ? bridge.volume : 1.0;
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  final MltBridge bridge;
  final bool initialized;

  Timer? _poll;

  MediaInfo? _media;
  String? _error;

  bool _opening = false;
  bool _playing = false;
  bool _eof = false;

  int _positionMs = 0;
  int _textureId = -1;

  double _volume = 1.0;
  double _volumeBeforeMute = 1.0;
  bool _muted = false;

  MediaInfo? get media => _media;
  String? get error => _error;
  bool get opening => _opening;
  bool get playing => _playing;
  bool get eof => _eof;
  int get positionMs => _positionMs;
  int get textureId => _textureId;
  double get volume => _volume;
  bool get muted => _muted;
  bool get hasMedia => _media != null;

  int get durationMs => _media?.durationMs ?? 0;
  bool get hasTimeline => durationMs > 0;

  set textureId(int value) {
    if (value != _textureId) {
      _textureId = value;
      notifyListeners();
    }
  }

  void _tick() {
    // Every native getter takes the engine lock, which open() holds for
    // its whole duration. Polling through an open would serialise the
    // main isolate against it and undo the point of the helper isolate.
    if (_opening || _media == null) {
      return;
    }

    final position = bridge.positionMs;
    final playing = bridge.isPlaying;
    final eof = bridge.isEof;

    if (position != _positionMs || playing != _playing || eof != _eof) {
      _positionMs = position;
      _playing = playing;
      _eof = eof;
      notifyListeners();
    }
  }

  Future<bool> open(String path) async {
    if (!initialized || _opening) {
      return false;
    }

    _opening = true;
    _error = null;
    notifyListeners();

    bool opened;
    try {
      opened = await Isolate.run(() => _openOnHelperIsolate(path));
    } catch (error) {
      _opening = false;
      _error = error.toString();
      notifyListeners();
      return false;
    }

    _opening = false;

    if (!opened) {
      _media = null;
      _playing = false;
      _eof = false;
      _positionMs = 0;
      _error = bridge.lastError.isEmpty
          ? 'MLT could not open that file.'
          : bridge.lastError;
      notifyListeners();
      return false;
    }

    _media = MediaInfo(
      path: path,
      width: bridge.width,
      height: bridge.height,
      displayAspect: bridge.displayAspect,
      fps: bridge.fps,
      frames: bridge.durationFrames,
      durationMs: bridge.durationMs,
      hasAudio: bridge.hasAudio,
      isStill: bridge.isStill,
    );

    _playing = false;
    _eof = false;
    _positionMs = 0;
    _error = null;

    final id = bridge.textureId;
    if (id > 0) {
      _textureId = id;
    }

    // Volume survives the new consumer, but read it back rather than
    // assuming, so the slider always shows what the engine actually has.
    _volume = bridge.volume;
    _muted = _volume <= 0.0;

    notifyListeners();
    return true;
  }

  void togglePlayback() {
    final media = _media;
    if (media == null || media.isStill) {
      return;
    }

    final ok = _playing ? bridge.pause() : bridge.play();
    if (!ok) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _playing = !_playing;
    _positionMs = bridge.positionMs;
    _eof = bridge.isEof;
    _error = null;
    notifyListeners();
  }

  void seekTo(int targetMs) {
    final media = _media;
    if (media == null || media.durationMs <= 0) {
      return;
    }

    final clamped = targetMs.clamp(0, media.durationMs);
    if (!bridge.seekMs(clamped)) {
      _error = bridge.lastError;
      notifyListeners();
      return;
    }

    _positionMs = clamped;
    _eof = false;
    _error = null;
    notifyListeners();
  }

  void seekBy(int deltaMs) => seekTo(_positionMs + deltaMs);

  void setVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);
    _volume = clamped;
    _muted = clamped <= 0.0;
    if (!_muted) {
      _volumeBeforeMute = clamped;
    }
    bridge.volume = clamped;
    notifyListeners();
  }

  void adjustVolume(double delta) => setVolume(_volume + delta);

  void toggleMute() {
    if (_muted || _volume <= 0.0) {
      setVolume(_volumeBeforeMute <= 0.0 ? 1.0 : _volumeBeforeMute);
    } else {
      _volumeBeforeMute = _volume;
      setVolume(0.0);
    }
  }

  void clearError() {
    if (_error != null) {
      _error = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    bridge.shutdown();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final bridge = MltBridge();
  final initialized = bridge.initialize();

  runApp(
    MltPlayerApp(
      bridge: bridge,
      initialized: initialized,
      version: bridge.version,
      startupError: initialized ? null : bridge.lastError,
    ),
  );
}

class MltPlayerApp extends StatelessWidget {
  const MltPlayerApp({
    super.key,
    required this.bridge,
    required this.initialized,
    required this.version,
    this.startupError,
  });

  final MltBridge bridge;
  final bool initialized;
  final String version;
  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MLT Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFE8A33D),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: PlayerPage(
        bridge: bridge,
        initialized: initialized,
        version: version,
        startupError: startupError,
      ),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.bridge,
    required this.initialized,
    required this.version,
    this.startupError,
  });

  final MltBridge bridge;
  final bool initialized;
  final String version;
  final String? startupError;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with TickerProviderStateMixin {
  static const Duration _overlayLinger = Duration(milliseconds: 2600);
  static const int _shortStepMs = 5000;
  static const int _longStepMs = 10000;

  late final PlayerEngine _engine;
  late final HostChannel _host;

  late final AnimationController _overlayController;
  late final Animation<double> _overlayCurve;
  late final AnimationController _infoController;

  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'player');

  Timer? _overlayTimer;
  Timer? _textureRetry;

  bool _overlayVisible = true;
  bool _infoOpen = false;
  bool _pointerOverControls = false;
  bool _fullscreen = false;

  bool _scrubbing = false;
  double _scrubMs = 0;

  @override
  void initState() {
    super.initState();

    _engine = PlayerEngine(widget.bridge, initialized: widget.initialized)
      ..addListener(_onEngineChanged);

    _overlayController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 320),
      value: 1,
    );

    _overlayCurve = CurvedAnimation(
      parent: _overlayController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    // The info panel is closed on purpose and stays closed until it is
    // asked for. It is reference material, not part of the viewing
    // experience, and it never opens itself.
    _infoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 200),
      value: 0,
    );

    _infoController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        _restartOverlayTimer();
      }
    });

    _host = HostChannel(
      onTextureRegistered: (id) => _engine.textureId = id,
      onPathOpened: _openPath,
    );

    _resolveTextureId();
    _restartOverlayTimer();
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _textureRetry?.cancel();
    _overlayController.dispose();
    _infoController.dispose();
    _keyboardFocus.dispose();
    _engine
      ..removeListener(_onEngineChanged)
      ..dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  // -------------------------------------------------------------------------
  // Texture
  // -------------------------------------------------------------------------

  /// The runner registers the texture when Flutter renders its first frame,
  /// which may land either side of this widget's construction. The push
  /// from the host covers the late case, this covers the early one, and
  /// the retry covers a slow start without leaving a poll running forever.
  Future<void> _resolveTextureId() async {
    var attempts = 0;

    Future<void> attempt() async {
      final id = await _host.textureId();
      if (!mounted) {
        return;
      }
      if (id > 0) {
        _engine.textureId = id;
        return;
      }
      if (++attempts < 25) {
        _textureRetry = Timer(const Duration(milliseconds: 200), attempt);
      }
    }

    await attempt();
  }

  // -------------------------------------------------------------------------
  // Overlay visibility
  // -------------------------------------------------------------------------

  bool get _overlayPinned =>
      !_engine.hasMedia ||
      !_engine.playing ||
      _pointerOverControls ||
      _scrubbing ||
      _infoOpen ||
      _engine.error != null;

  void _showOverlay() {
    if (!_overlayVisible) {
      setState(() => _overlayVisible = true);
    }
    _overlayController.forward();
    _restartOverlayTimer();
  }

  void _restartOverlayTimer() {
    _overlayTimer?.cancel();
    if (_overlayPinned) {
      return;
    }
    _overlayTimer = Timer(_overlayLinger, _hideOverlay);
  }

  void _hideOverlay() {
    if (_overlayPinned) {
      return;
    }
    _overlayController.reverse();
    if (mounted) {
      setState(() => _overlayVisible = false);
    }
  }

  void _onPointerActivity() {
    _showOverlay();
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _pickMedia() async {
    _showOverlay();

    final typeGroup = XTypeGroup(
      label: 'Media',
      extensions: <String>[
        'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'mxf', 'mpg', 'mpeg',
        'wmv', 'ts', 'm2ts', 'dv', 'flv', 'ogv',
        'mp3', 'wav', 'flac', 'aac', 'ogg', 'opus', 'm4a',
        'png', 'jpg', 'jpeg', 'tif', 'tiff', 'exr', 'webp',
        'mlt', 'xml',
      ],
    );

    final file = await openFile(
      confirmButtonText: 'Open',
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );

    if (file == null) {
      return;
    }

    await _openPath(file.path);
  }

  Future<void> _openPath(String path) async {
    // A new file starts closed, whatever the previous one was doing.
    if (_infoOpen) {
      setState(() => _infoOpen = false);
      _infoController.reverse();
    }
    await _engine.open(path);
    if (mounted) {
      _showOverlay();
    }
  }

  void _toggleInfo() {
    setState(() => _infoOpen = !_infoOpen);
    if (_infoOpen) {
      _infoController.forward();
    } else {
      _infoController.reverse();
    }
    _showOverlay();
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    await _host.setFullscreen(_fullscreen);
    _showOverlay();
  }

  Future<void> _exitFullscreen() async {
    if (!_fullscreen) {
      return;
    }
    setState(() => _fullscreen = false);
    await _host.setFullscreen(false);
    _showOverlay();
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    _showOverlay();

    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _engine.togglePlayback();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _engine.seekBy(shift ? -_longStepMs : -_shortStepMs);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      _engine.seekBy(shift ? _longStepMs : _shortStepMs);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyJ) {
      _engine.seekBy(-_longStepMs);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyL) {
      _engine.seekBy(_longStepMs);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _engine.adjustVolume(0.05);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      _engine.adjustVolume(-0.05);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.home) {
      _engine.seekTo(0);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.end) {
      _engine.seekTo(_engine.durationMs);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyM) {
      _engine.toggleMute();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyI) {
      _toggleInfo();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyO) {
      _pickMedia();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      _exitFullscreen();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // -------------------------------------------------------------------------
  // Formatting
  // -------------------------------------------------------------------------

  static String _formatClock(int milliseconds, {bool forceHours = false}) {
    final value = milliseconds < 0 ? 0 : milliseconds;
    final duration = Duration(milliseconds: value);

    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');

    if (hours > 0 || forceHours) {
      return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
    }
    return '$mm:$ss';
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final media = _engine.media;

    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        body: MouseRegion(
          cursor: _overlayVisible
              ? SystemMouseCursors.basic
              : SystemMouseCursors.none,
          onHover: (_) => _onPointerActivity(),
          onEnter: (_) => _onPointerActivity(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _keyboardFocus.requestFocus();
              if (_overlayVisible) {
                _engine.togglePlayback();
              } else {
                _showOverlay();
              }
            },
            onDoubleTap: _toggleFullscreen,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                _buildViewport(media),
                _buildTopBar(media),
                _buildBottomOverlay(media),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildViewport(MediaInfo? media) {
    if (media == null) {
      return _EmptyState(
        initialized: widget.initialized,
        opening: _engine.opening,
        message: widget.startupError,
        onOpen: _pickMedia,
      );
    }

    if (!media.hasVideo) {
      return const Center(
        child: Icon(Icons.graphic_eq, size: 96, color: Colors.white24),
      );
    }

    if (_engine.textureId <= 0) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Center(
      child: AspectRatio(
        // The display aspect, not the pixel grid. Anamorphic sources
        // differ, and letterboxing to the wrong one is a silent error
        // nobody notices until the credits look narrow.
        aspectRatio: media.viewportAspect,
        child: Texture(
          textureId: _engine.textureId,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }

  Widget _buildTopBar(MediaInfo? media) {
    if (media == null) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _OverlayFade(
        animation: _overlayCurve,
        slideFrom: const Offset(0, -0.35),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 28),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  media.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'MLT ${widget.version}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomOverlay(MediaInfo? media) {
    if (media == null) {
      return const SizedBox.shrink();
    }

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: _OverlayFade(
        animation: _overlayCurve,
        slideFrom: const Offset(0, 0.35),
        child: MouseRegion(
          onEnter: (_) {
            _pointerOverControls = true;
            _showOverlay();
          },
          onExit: (_) {
            _pointerOverControls = false;
            _restartOverlayTimer();
          },
          // Absorbs taps so that clicking the scrim beside a button does
          // not fall through to the video and toggle playback.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            // The player owns the keyboard. Nothing in here may take
            // focus, or the slider would eat the arrow keys.
            child: ExcludeFocus(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Color(0xF2000000),
                      Color(0xB3000000),
                      Color(0x00000000),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 40, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildInfoRoll(media),
                    if (_engine.error != null) _buildErrorRow(),
                    if (!media.isStill) _buildScrubber(media),
                    _buildControlRow(media),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The rolling file information panel.
  ///
  /// Anchored to the bottom of its own clip rect, so growing the height
  /// factor rolls the panel up out of the control bar and shrinking it
  /// rolls it back down behind it.
  Widget _buildInfoRoll(MediaInfo media) {
    return AnimatedBuilder(
      animation: _infoController,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_infoController.value);
        if (t == 0) {
          return const SizedBox(width: double.infinity, height: 0);
        }
        return ClipRect(
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: t,
            child: Opacity(opacity: t, child: child),
          ),
        );
      },
      child: _InfoPanel(media: media),
    );
  }

  Widget _buildErrorRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFE57373)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _engine.error ?? '',
              style: const TextStyle(fontSize: 12, color: Color(0xFFE57373)),
            ),
          ),
          IconButton(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: _engine.clearError,
          ),
        ],
      ),
    );
  }

  Widget _buildScrubber(MediaInfo media) {
    final durationMs = media.durationMs;
    final maxValue = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final value = (_scrubbing ? _scrubMs : _positionForDisplay().toDouble())
        .clamp(0.0, maxValue);

    final showHours = durationMs >= 3600000;

    return Row(
      children: [
        SizedBox(
          width: showHours ? 66 : 48,
          child: Text(
            _formatClock(
              _scrubbing ? _scrubMs.round() : _positionForDisplay(),
              forceHours: showHours,
            ),
            style: const TextStyle(
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              min: 0,
              max: maxValue,
              value: value,
              onChangeStart: durationMs > 0
                  ? (v) => setState(() {
                        _scrubbing = true;
                        _scrubMs = v;
                      })
                  : null,
              onChanged:
                  durationMs > 0 ? (v) => setState(() => _scrubMs = v) : null,
              onChangeEnd: durationMs > 0
                  ? (v) {
                      setState(() => _scrubbing = false);
                      _engine.seekTo(v.round());
                      _restartOverlayTimer();
                    }
                  : null,
            ),
          ),
        ),
        SizedBox(
          width: showHours ? 66 : 48,
          child: Text(
            _formatClock(durationMs, forceHours: showHours),
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white70,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  int _positionForDisplay() => _engine.positionMs;

  Widget _buildControlRow(MediaInfo media) {
    return Row(
      children: [
        if (!media.isStill) ...[
          _OverlayButton(
            icon: _engine.eof
                ? Icons.replay
                : (_engine.playing ? Icons.pause : Icons.play_arrow),
            tooltip: _engine.eof
                ? 'Replay'
                : (_engine.playing ? 'Pause (space)' : 'Play (space)'),
            size: 30,
            onPressed: _engine.togglePlayback,
          ),
          _OverlayButton(
            icon: Icons.replay_10,
            tooltip: 'Back 10 seconds (J)',
            onPressed: () => _engine.seekBy(-_longStepMs),
          ),
          _OverlayButton(
            icon: Icons.forward_10,
            tooltip: 'Forward 10 seconds (L)',
            onPressed: () => _engine.seekBy(_longStepMs),
          ),
          if (media.hasAudio) _buildVolume(),
        ],
        const Spacer(),
        _OverlayButton(
          icon: Icons.folder_open,
          tooltip: 'Open media (O)',
          onPressed: widget.initialized && !_engine.opening ? _pickMedia : null,
        ),
        _OverlayButton(
          icon: _infoOpen ? Icons.expand_more : Icons.info_outline,
          tooltip:
              _infoOpen ? 'Hide file information (I)' : 'File information (I)',
          onPressed: _toggleInfo,
        ),
        _OverlayButton(
          icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: _fullscreen ? 'Leave fullscreen (F)' : 'Fullscreen (F)',
          onPressed: _toggleFullscreen,
        ),
      ],
    );
  }

  Widget _buildVolume() {
    final volume = _engine.volume;
    final muted = _engine.muted || volume <= 0;

    final IconData icon;
    if (muted) {
      icon = Icons.volume_off;
    } else if (volume < 0.34) {
      icon = Icons.volume_mute;
    } else if (volume < 0.67) {
      icon = Icons.volume_down;
    } else {
      icon = Icons.volume_up;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _OverlayButton(
          icon: icon,
          tooltip: muted ? 'Unmute (M)' : 'Mute (M)',
          onPressed: _engine.toggleMute,
        ),
        SizedBox(
          width: 92,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              min: 0,
              max: 1,
              value: muted ? 0 : volume.clamp(0.0, 1.0),
              onChanged: _engine.setVolume,
              onChangeEnd: (_) => _restartOverlayTimer(),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Overlay pieces
// ---------------------------------------------------------------------------

/// Fade plus a short slide, and no hit testing once it is gone, so an
/// invisible control bar cannot swallow a click meant for the video.
class _OverlayFade extends StatelessWidget {
  const _OverlayFade({
    required this.animation,
    required this.slideFrom,
    required this.child,
  });

  final Animation<double> animation;
  final Offset slideFrom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, inner) {
        final t = animation.value.clamp(0.0, 1.0);
        return IgnorePointer(
          ignoring: t < 0.05,
          child: Opacity(
            opacity: t,
            child: Transform.translate(
              offset: slideFrom * (1 - t) * 24,
              child: inner,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: size,
      color: Colors.white,
      disabledColor: Colors.white24,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.media});

  final MediaInfo media;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      _InfoItem(
        label: 'Resolution',
        value: media.hasVideo ? '${media.width} x ${media.height}' : 'None',
      ),
      _InfoItem(
        label: 'Display aspect',
        value: media.displayAspect > 0
            ? media.displayAspect.toStringAsFixed(4) +
                (media.isAnamorphic ? '  (anamorphic)' : '')
            : 'Unknown',
      ),
      _InfoItem(
        label: 'Frame rate',
        value: media.fps > 0 ? '${media.fps.toStringAsFixed(3)} fps' : 'None',
      ),
      _InfoItem(
        label: 'Frames',
        value: media.frames > 0 ? media.frames.toString() : 'None',
      ),
      _InfoItem(
        label: 'Audio',
        value: media.hasAudio ? 'Present' : 'None',
      ),
      _InfoItem(
        label: 'Kind',
        value: media.isStill ? 'Still image' : 'Timed media',
      ),
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xE01A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            media.name,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SelectableText(
            media.path,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 28, runSpacing: 14, children: items),
        ],
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 0.8,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.initialized,
    required this.opening,
    required this.onOpen,
    this.message,
  });

  final bool initialized;
  final bool opening;
  final VoidCallback onOpen;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.movie_outlined, size: 64, color: Colors.white24),
          const SizedBox(height: 18),
          Text(
            initialized ? 'No media loaded' : 'MLT is unavailable',
            style: const TextStyle(fontSize: 17, color: Colors.white70),
          ),
          if (message != null && message!.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 420,
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFE57373)),
              ),
            ),
          ],
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: initialized && !opening ? onOpen : null,
            icon: opening
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open),
            label: Text(opening ? 'Opening' : 'Open media'),
          ),
          const SizedBox(height: 14),
          const Text(
            'or drop a file onto the window',
            style: TextStyle(fontSize: 12, color: Colors.white30),
          ),
        ],
      ),
    );
  }
}
