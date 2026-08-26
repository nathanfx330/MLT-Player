// lib/main.dart

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui show FontFeature, Size;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/media_info.dart';
import 'services/project_catalog_service.dart';
import 'services/project_media_metadata_service.dart';
import 'services/host_channel.dart';
import 'services/mlt_bridge.dart';
import 'services/mlt_export_frame_rate_bridge.dart';
import 'services/mlt_export_preset_bridge.dart';
import 'services/player_engine.dart';
import 'services/player_settings_service.dart';
import 'services/storyboard_thumbnail_service.dart';
import 'services/srt_subtitle_service.dart';
import 'ui/widgets/player_settings_button.dart';
import 'ui/widgets/bookmark_view.dart';
import 'ui/widgets/media_inspector.dart';
import 'ui/explorer_page.dart';
import 'ui/project_page.dart';
import 'ui/widgets/layers_inspector.dart';
import 'ui/widgets/storyboard_view.dart';
import 'ui/widgets/subtitle_overlay.dart';

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

class MltPlayerApp extends StatefulWidget {
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
  State<MltPlayerApp> createState() => _MltPlayerAppState();
}

class _MltPlayerAppState extends State<MltPlayerApp> {
  late final PlayerSettingsService _playerSettings;

  @override
  void initState() {
    super.initState();
    _playerSettings = PlayerSettingsService()
      ..addListener(_onPlayerSettingsChanged);
    unawaited(_playerSettings.load());
  }

  @override
  void dispose() {
    _playerSettings
      ..removeListener(_onPlayerSettingsChanged)
      ..dispose();
    super.dispose();
  }

  void _onPlayerSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MLT Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: _playerSettings.accentColor,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: _MltExplorerShell(
        bridge: widget.bridge,
        initialized: widget.initialized,
        version: widget.version,
        startupError: widget.startupError,
        playerSettings: _playerSettings,
      ),
    );
  }
}

class _MltExplorerShell extends StatefulWidget {
  const _MltExplorerShell({
    required this.bridge,
    required this.initialized,
    required this.version,
    required this.playerSettings,
    this.startupError,
  });

  final MltBridge bridge;
  final bool initialized;
  final String version;
  final PlayerSettingsService playerSettings;
  final String? startupError;

  @override
  State<_MltExplorerShell> createState() => _MltExplorerShellState();
}

enum _WorkspaceSection {
  explorer,
  project,
}

class _MltExplorerShellState extends State<_MltExplorerShell> {
  late final ProjectCatalogService _projectCatalogService;
  late final ProjectMediaMetadataService _projectMediaMetadataService;

  String? _playerPath;
  String? _activeProjectId;
  int _playerOpenRequest = 0;
  bool _showPlayer = false;
  _WorkspaceSection _workspaceSection = _WorkspaceSection.explorer;

  @override
  void initState() {
    super.initState();
    _projectCatalogService = ProjectCatalogService();
    _projectMediaMetadataService = ProjectMediaMetadataService();
  }

  void _setActiveProject(String projectId) {
    if (_activeProjectId == projectId) {
      return;
    }
    setState(() => _activeProjectId = projectId);
  }

  void _openInPlayer(String path) {
    setState(() {
      _playerPath = path;
      _playerOpenRequest += 1;
      _showPlayer = true;
    });
  }

  void _returnToExplorer() {
    setState(() {
      _showPlayer = false;
      _workspaceSection = _WorkspaceSection.explorer;
    });
  }

  void _setWorkspaceSection(_WorkspaceSection section) {
    if (_workspaceSection == section) {
      return;
    }
    setState(() => _workspaceSection = section);
  }

  @override
  Widget build(BuildContext context) {
    final workspaceIndex =
        _workspaceSection == _WorkspaceSection.explorer ? 0 : 1;

    return IndexedStack(
      index: _showPlayer ? 1 : 0,
      children: [
        Column(
          children: [
            _WorkspaceTabs(
              selected: _workspaceSection,
              onSelected: _setWorkspaceSection,
            ),
            Expanded(
              child: IndexedStack(
                index: workspaceIndex,
                children: [
                  ExplorerPage(
                    initialized: widget.initialized,
                    version: widget.version,
                    startupError: widget.startupError,
                    onOpenMedia: _openInPlayer,
                    projectCatalogService: _projectCatalogService,
                    projectMediaMetadataService:
                        _projectMediaMetadataService,
                    playerSettings: widget.playerSettings,
                    onActiveProjectChanged: _setActiveProject,
                    active: !_showPlayer &&
                        _workspaceSection == _WorkspaceSection.explorer,
                  ),
                  ProjectPage(
                    projectCatalogService: _projectCatalogService,
                    projectMediaMetadataService:
                        _projectMediaMetadataService,
                    activeProjectId: _activeProjectId,
                  ),
                ],
              ),
            ),
          ],
        ),
        PlayerPage(
          bridge: widget.bridge,
          initialized: widget.initialized,
          version: widget.version,
          startupError: widget.startupError,
          playerSettings: widget.playerSettings,
          projectMediaMetadataService: _projectMediaMetadataService,
          activeProjectId: _activeProjectId,
          initialPath: _playerPath,
          openRequestSerial: _playerOpenRequest,
          onBack: _returnToExplorer,
        ),
      ],
    );
  }
}

class _WorkspaceTabs extends StatelessWidget {
  const _WorkspaceTabs({
    required this.selected,
    required this.onSelected,
  });

  final _WorkspaceSection selected;
  final ValueChanged<_WorkspaceSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFF0D0D0D),
                border: Border(
                  bottom: BorderSide(color: Colors.white12),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  _WorkspaceTab(
                    label: 'EXPLORER',
                    icon: Icons.collections_outlined,
                    selected: selected == _WorkspaceSection.explorer,
                    onTap: () => onSelected(_WorkspaceSection.explorer),
                  ),
                  const SizedBox(width: 2),
                  _WorkspaceTab(
                    label: 'PROJECT',
                    icon: Icons.dashboard_outlined,
                    selected: selected == _WorkspaceSection.project,
                    onTap: () => onSelected(_WorkspaceSection.project),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
          const ColoredBox(
            color: Color(0xFF0D0D0D),
            child: SizedBox(
              width: 126,
              height: 42,
              child: Padding(
                padding: EdgeInsets.only(right: 14),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'MLT PLAYER',
                    style: TextStyle(
                      inherit: false,
                      decoration: TextDecoration.none,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: Colors.white38,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceTab extends StatelessWidget {
  const _WorkspaceTab({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? const Color(0xFFE8A33D)
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 15,
                color: selected
                    ? const Color(0xFFE8A33D)
                    : Colors.white38,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.9,
                  color: selected ? Colors.white70 : Colors.white38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ExportMode {
  video,
  imageSequence,
  audio,
}

enum _ExportMenuChoice {
  video,
  imageSequence,
  audio,
  h264Delivery,
  proRes422HqMaster,
  frameRateSource,
  frameRate23976,
  frameRate24,
  frameRate25,
  frameRate2997,
  frameRate30,
  frameRate50,
  frameRate5994,
  frameRate60,
  wholeMovie,
  inOut,
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.bridge,
    required this.initialized,
    required this.version,
    required this.playerSettings,
    required this.projectMediaMetadataService,
    required this.activeProjectId,
    this.startupError,
    this.initialPath,
    this.openRequestSerial = 0,
    this.onBack,
  });

  final MltBridge bridge;
  final bool initialized;
  final String version;
  final PlayerSettingsService playerSettings;
  final ProjectMediaMetadataService projectMediaMetadataService;
  final String? activeProjectId;
  final String? startupError;
  final String? initialPath;
  final int openRequestSerial;
  final VoidCallback? onBack;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with TickerProviderStateMixin {
  static const Duration _overlayLinger = Duration(milliseconds: 2600);
  static const Duration _textureReadyPollInterval =
      Duration(milliseconds: 50);
  static const Duration _textureReadyTimeout = Duration(seconds: 10);

  late final PlayerEngine _engine;
  late final HostChannel _host;
  late final MltExportPresetBridge _exportPresetBridge;
  late final MltExportFrameRateBridge _exportFrameRateBridge;
  late final StoryboardThumbnailService _storyboardThumbnailService;

  SubtitleTrack? _subtitleTrack;
  int _subtitleLoadSerial = 0;

  late final AnimationController _overlayController;
  late final Animation<double> _overlayCurve;
  late final AnimationController _infoController;

  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'player');

  Timer? _overlayTimer;
  Timer? _textureRetry;

  bool _overlayVisible = true;
  bool _infoOpen = false;
  bool _tracksOpen = false;
  bool _pointerOverControls = false;
  bool _fullscreen = false;

  bool _scrubbing = false;
  double _scrubMs = 0;

  bool _showTransportTimecode = false;
  PlayerViewMode _viewMode = PlayerViewMode.video;

  _ExportMode _exportMode = _ExportMode.video;
  VideoExportPreset _videoExportPreset = VideoExportPreset.h264Delivery;
  VideoExportFrameRate _videoExportFrameRate = VideoExportFrameRate.source;

  @override
  void initState() {
    super.initState();

    _engine = PlayerEngine(widget.bridge, initialized: widget.initialized)
      ..addListener(_onEngineChanged);

    _exportPresetBridge = MltExportPresetBridge();
    _exportPresetBridge.setVideoExportPreset(_videoExportPreset);
    _exportFrameRateBridge = MltExportFrameRateBridge();
    _exportFrameRateBridge.setVideoExportFrameRate(_videoExportFrameRate);
    _storyboardThumbnailService = StoryboardThumbnailService();

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

    final initialPath = widget.initialPath;
    if (initialPath != null && initialPath.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_openPath(initialPath));
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final path = widget.initialPath;
    if (path != null &&
        path.isNotEmpty &&
        (path != oldWidget.initialPath ||
            widget.openRequestSerial != oldWidget.openRequestSerial)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_openPath(path));
        }
      });
    }
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _textureRetry?.cancel();
    _overlayController.dispose();
    _infoController.dispose();
    _keyboardFocus.dispose();
    _storyboardThumbnailService.cancelPending();
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

  /// Media open is allowed to cross into MLT only after the Linux runner has
  /// actually registered the external Flutter texture. The old fixed delay
  /// reduced a cold-start race without proving readiness; this gate uses the
  /// runner's real texture id as the condition and keeps a timeout only as a
  /// fail-safe so a broken registration cannot hang the UI forever.
  Future<bool> _waitForTextureReady() async {
    if (_engine.textureId > 0) {
      return true;
    }

    final stopwatch = Stopwatch()..start();

    while (mounted && stopwatch.elapsed < _textureReadyTimeout) {
      final id = await _host.textureId();
      if (!mounted) {
        return false;
      }

      if (id > 0) {
        _textureRetry?.cancel();
        _textureRetry = null;
        _engine.textureId = id;
        debugPrint(
          'MLT Player: texture ready before media open '
          '(id=$id, waited=${stopwatch.elapsedMilliseconds}ms)',
        );
        return true;
      }

      await Future<void>.delayed(_textureReadyPollInterval);
    }

    debugPrint(
      'MLT Player: texture was not ready after '
      '${stopwatch.elapsedMilliseconds}ms; media open was blocked.',
    );
    return false;
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
      _tracksOpen ||
      _engine.exporting ||
      _engine.error != null ||
      _viewMode != PlayerViewMode.video;

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

    const typeGroup = XTypeGroup(
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

  Future<void> _pickNextTrack() async {
    final media = _engine.media;
    if (media == null ||
        media.isStill ||
        !media.hasVideo ||
        _engine.addingTrack ||
        _engine.exporting ||
        _engine.trackCount >= 3) {
      return;
    }

    // Additions use the exact parked playhead as their insertion frame.
    if (_engine.playing) {
      _engine.togglePlayback();
      if (_engine.playing) {
        return;
      }
    }

    _showOverlay();

    const typeGroup = XTypeGroup(
      label: 'Layer media',
      extensions: <String>[
        'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'mxf', 'mpg', 'mpeg',
        'wmv', 'ts', 'm2ts', 'dv', 'flv', 'ogv',
        'png', 'jpg', 'jpeg', 'webp', 'bmp', 'tif', 'tiff', 'exr',
      ],
    );

    final nextLayerNumber = _engine.trackCount + 1;
    final file = await openFile(
      confirmButtonText: 'Add Layer $nextLayerNumber',
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );

    if (file == null) {
      return;
    }

    final added = await _engine.addTrack(file.path);

    if (mounted) {
      if (added) {
        setState(() => _tracksOpen = true);
      }
      _showOverlay();
    }
  }

  Future<void> _removeTopLayer() async {
    if (!_engine.hasLayer(1) ||
        _engine.opening ||
        _engine.addingTrack ||
        _engine.exporting) {
      return;
    }

    final topLayerIndex = _engine.topOverlayLayerIndex;
    if (topLayerIndex == null) {
      return;
    }
    final removed = await _engine.removeLayer(topLayerIndex);

    if (mounted) {
      if (removed) {
        setState(() {
          _tracksOpen = _engine.hasLayer(1);
        });
      }
      _showOverlay();
    }
  }

  Future<void> _replaceLayerSource(int layerIndex) async {
    final media = _engine.media;
    final layer = _engine.layerState(layerIndex);
    final isBase = layerIndex == 0;

    if (media == null ||
        media.isStill ||
        !media.hasVideo ||
        !layer.present ||
        _engine.opening ||
        _engine.addingTrack ||
        _engine.exporting) {
      return;
    }

    _showOverlay();

    final typeGroup = XTypeGroup(
      label: isBase ? 'Base video' : 'Overlay layer media',
      extensions: isBase
          ? const <String>[
              'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'mxf', 'mpg',
              'mpeg', 'wmv', 'ts', 'm2ts', 'dv', 'flv', 'ogv',
            ]
          : const <String>[
              'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v', 'mxf', 'mpg',
              'mpeg', 'wmv', 'ts', 'm2ts', 'dv', 'flv', 'ogv',
              'png', 'jpg', 'jpeg', 'webp', 'bmp', 'tif', 'tiff', 'exr',
            ],
    );

    final file = await openFile(
      confirmButtonText: isBase ? 'Replace Base' : 'Replace Layer ${layerIndex + 1}',
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );

    if (file == null) {
      return;
    }

    await _engine.replaceLayerSource(layerIndex, file.path);

    if (mounted) {
      setState(() {
        _tracksOpen = _engine.hasLayer(1);
      });
      _showOverlay();
    }
  }

  Future<void> _moveLayerUp(int layerIndex) async {
    if (!_engine.canMoveLayerUp(layerIndex)) {
      return;
    }

    _showOverlay();
    await _engine.moveLayerUp(layerIndex);

    if (mounted) {
      setState(() {
        _tracksOpen = _engine.hasLayer(1);
      });
      _showOverlay();
    }
  }

  Future<void> _moveLayerDown(int layerIndex) async {
    if (!_engine.canMoveLayerDown(layerIndex)) {
      return;
    }

    _showOverlay();
    await _engine.moveLayerDown(layerIndex);

    if (mounted) {
      setState(() {
        _tracksOpen = _engine.hasLayer(1);
      });
      _showOverlay();
    }
  }

  void _setViewMode(PlayerViewMode mode) {
    final media = _engine.media;

    if (mode == _viewMode) {
      _showOverlay();
      return;
    }

    if (mode != PlayerViewMode.video) {
      if (media == null ||
          media.isStill ||
          !media.hasVideo ||
          _engine.durationMs <= 0) {
        return;
      }

      if (_engine.playing) {
        _engine.pausePlayback();
      }

      // Storyboard and Bookmarks share the exact-frame thumbnail lane.
      // Invalidate work owned by the view being left before the new view
      // starts issuing requests.
      _storyboardThumbnailService.cancelPending();
      setState(() => _viewMode = mode);
      _showOverlay();
      return;
    }

    _storyboardThumbnailService.cancelPending();
    setState(() => _viewMode = PlayerViewMode.video);
    _showOverlay();
  }

  void _seekStoryboardMoment(int clipPositionMs) {
    _engine.seekTo(clipPositionMs);
    _keyboardFocus.requestFocus();
    _showOverlay();
  }

  void _openStoryboardMoment(int clipPositionMs) {
    _engine.seekTo(clipPositionMs);
    _storyboardThumbnailService.cancelPending();
    setState(() => _viewMode = PlayerViewMode.video);
    if (!_engine.playing) {
      _engine.togglePlayback();
    }
    _keyboardFocus.requestFocus();
    _showOverlay();
  }

  void _playFromCurrentView() {
    if (_viewMode != PlayerViewMode.video) {
      _storyboardThumbnailService.cancelPending();
      setState(() => _viewMode = PlayerViewMode.video);
    }
    _engine.togglePlayback();
    _showOverlay();
  }

  Future<void> _saveProjectMetadata() async {
    try {
      await widget.projectMediaMetadataService.save();
    } on FileSystemException {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save Project bookmarks.')),
      );
    }
  }

  List<int> _bookmarkFramesFor(MediaInfo media) {
    final projectId = widget.activeProjectId;
    if (projectId == null ||
        !widget.projectMediaMetadataService.loaded) {
      return const <int>[];
    }

    return widget.projectMediaMetadataService.bookmarkFramesFor(
      projectId,
      media.path,
    );
  }

  void _toggleBookmarkFrame(int sourceFrame) {
    final media = _engine.media;
    final projectId = widget.activeProjectId;
    if (media == null ||
        projectId == null ||
        media.isStill ||
        !media.hasVideo ||
        sourceFrame < 0) {
      return;
    }

    widget.projectMediaMetadataService.toggleBookmark(
      projectId,
      media.path,
      sourceFrame,
    );
    setState(() {});
    unawaited(_saveProjectMetadata());
    _showOverlay();
  }

  void _removeBookmarkFrame(int sourceFrame) {
    final media = _engine.media;
    final projectId = widget.activeProjectId;
    if (media == null || projectId == null) {
      return;
    }

    if (widget.projectMediaMetadataService.removeBookmark(
      projectId,
      media.path,
      sourceFrame,
    )) {
      setState(() {});
      unawaited(_saveProjectMetadata());
    }
    _showOverlay();
  }

  void _addCurrentBookmark() {
    final media = _engine.media;
    final projectId = widget.activeProjectId;
    if (media == null ||
        projectId == null ||
        media.isStill ||
        !media.hasVideo ||
        _engine.opening ||
        _engine.exporting) {
      return;
    }

    // A soft screenshot should point at the exact visible source frame. The
    // existing capture helper parks transport on that frame without writing
    // an image file.
    final sourceFrame = _engine.captureCurrentSourceFrame();
    if (sourceFrame == null) {
      return;
    }

    if (widget.projectMediaMetadataService.addBookmark(
      projectId,
      media.path,
      sourceFrame,
    )) {
      setState(() {});
      unawaited(_saveProjectMetadata());
    }
    _showOverlay();
  }

  void _openBookmarkFrame(int sourceFrame) {
    final media = _engine.media;
    if (media == null || media.fps <= 0 || _engine.clipFrameCount <= 0) {
      return;
    }

    // PlayerEngine.seekTo converts the clip-time position back to an exact
    // frame-native seek. Rounding to the nearest millisecond stays safely
    // inside the target frame at ordinary video frame rates.
    final clipFrame = _engine.clipFrameForSourceFrame(sourceFrame);
    final clipPositionMs = ((clipFrame * 1000.0) / media.fps).round();
    _engine.seekTo(clipPositionMs);

    _storyboardThumbnailService.cancelPending();
    setState(() => _viewMode = PlayerViewMode.video);
    _keyboardFocus.requestFocus();
    _showOverlay();
  }

  String _formatBookmarkFrame(MediaInfo media, int sourceFrame) {
    final clipFrame = _engine.clipFrameForSourceFrame(sourceFrame);
    return _formatClipTimecode(media, clipFrame);
  }

  Future<void> _openPath(String path) async {
    // On Linux, file_selector can return while the native GTK chooser and its
    // thumbnail work are still unwinding. Starting MLT immediately from that
    // callback can overlap native teardown. Give the chooser one short settle
    // window before any player/native media work begins.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) {
      return;
    }

    // A cold Linux launch can reach media open before the runner has finished
    // registering Flutter's external texture. Do not let MLT construct/start
    // its preview consumer until the runner reports a real texture id.
    final textureReady = await _waitForTextureReady();
    if (!mounted) {
      return;
    }
    if (!textureReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Video output did not finish initializing. Media was not opened.',
          ),
        ),
      );
      return;
    }

    // Invalidate any sidecar read from the previous media immediately. Actual
    // SRT discovery still starts only after the native player open completes.
    final subtitleSerial = ++_subtitleLoadSerial;

    // A new file starts in normal video view, whatever the previous one was
    // doing. Any queued Storyboard/Bookmark thumbnail requests from that file
    // become obsolete.
    _storyboardThumbnailService.cancelPending();
    if (_viewMode != PlayerViewMode.video && mounted) {
      setState(() => _viewMode = PlayerViewMode.video);
    }

    // A new file starts closed, whatever the previous one was doing.
    if (_infoOpen || _tracksOpen) {
      setState(() {
        _infoOpen = false;
        _tracksOpen = false;
      });
      await _infoController.reverse();
    }

    // Keep sidecar discovery strictly after the native player has completed
    // its normal open path. SRT support is a Flutter overlay and must not
    // participate in native media probing or graph construction.
    final opened = await _engine.open(path);

    if (!mounted) {
      return;
    }

    if (_subtitleTrack != null) {
      setState(() => _subtitleTrack = null);
    }

    if (opened &&
        _engine.media != null &&
        _engine.media!.hasVideo &&
        !_engine.media!.isStill) {
      unawaited(_loadSidecarSubtitles(path, subtitleSerial));
    }

    _keyboardFocus.requestFocus();
    _showOverlay();
  }

  Future<void> _loadSidecarSubtitles(
    String mediaPath,
    int subtitleSerial,
  ) async {
    final track = await SrtSubtitleService.loadForMedia(mediaPath);

    if (!mounted || subtitleSerial != _subtitleLoadSerial) {
      return;
    }

    setState(() => _subtitleTrack = track);
  }

  void _returnToExplorer() {
    if (_engine.playing) {
      _engine.pausePlayback();
    }
    _storyboardThumbnailService.cancelPending();
    widget.onBack?.call();
  }

  static String _mediaStem(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static String _joinPath(String directory, String child) {
    final separator = Platform.pathSeparator;
    return directory.endsWith(separator)
        ? '$directory$child'
        : '$directory$separator$child';
  }

  Future<String> _createUniqueSequenceDirectory(
    String parentDirectory,
    String preferredName,
  ) async {
    for (var index = 0; index < 1000; index++) {
      final suffix = index == 0 ? '' : '_${index + 1}';
      final path = _joinPath(
        parentDirectory,
        '$preferredName$suffix',
      );
      final directory = Directory(path);

      if (await directory.exists()) {
        continue;
      }

      try {
        await directory.create();
        return path;
      } on FileSystemException {
        if (await directory.exists()) {
          continue;
        }
        rethrow;
      }
    }

    throw FileSystemException(
      'Could not create a unique image-sequence directory.',
      parentDirectory,
    );
  }

  Future<void> _exportActiveClip() async {
    final media = _engine.media;
    if (media == null ||
        media.isStill ||
        !_engine.exportsAvailable ||
        _engine.exporting) {
      return;
    }

    _showOverlay();

    final preset = _videoExportPreset;
    final frameRate = _videoExportFrameRate;
    final stem = _mediaStem(media.name);
    final suffix = _engine.exportRangeMode == ExportRangeMode.inOut
        ? 'selection'
        : (_engine.isTrimmed ? 'trimmed' : 'export');

    final location = await getSaveLocation(
      confirmButtonText: 'Export',
      suggestedName: '${stem}_$suffix.${preset.extension}',
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(
          label: preset.typeLabel,
          extensions: <String>[preset.extension],
        ),
      ],
    );

    if (location == null) {
      return;
    }

    var outputPath = location.path;
    final requiredExtension = '.${preset.extension.toLowerCase()}';
    if (!outputPath.toLowerCase().endsWith(requiredExtension)) {
      outputPath = '$outputPath$requiredExtension';
    }

    // Re-assert the selected purpose preset immediately before launch. Native
    // snapshots it into the immutable ExportJob before starting the worker.
    if (!_exportPresetBridge.setVideoExportPreset(preset)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not select the requested video export preset.'),
          ),
        );
      }
      return;
    }

    if (!_exportFrameRateBridge.setVideoExportFrameRate(frameRate)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not select the requested video frame rate.'),
          ),
        );
      }
      return;
    }

    _engine.startExport(outputPath);
  }

  Future<void> _exportCurrentFrame() async {
    final media = _engine.media;
    if (media == null ||
        media.isStill ||
        !media.hasVideo ||
        !_engine.exportsAvailable ||
        _engine.exporting) {
      return;
    }

    /*
     * Capture freezes transport on the exact visible source frame before the
     * save dialog opens. The PNG therefore matches the frame left on screen,
     * even when the command was invoked during playback or shuttle.
     */
    final sourceFrame = _engine.captureCurrentSourceFrame();
    if (sourceFrame == null) {
      return;
    }

    _showOverlay();

    final stem = _mediaStem(media.name);
    final clipFrameNumber =
        _engine.clipFrameForSourceFrame(sourceFrame) + 1;
    final frameLabel = clipFrameNumber.toString().padLeft(6, '0');

    final location = await getSaveLocation(
      confirmButtonText: 'Export Frame',
      suggestedName: '${stem}_frame_$frameLabel.png',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'PNG Image',
          extensions: <String>['png'],
        ),
      ],
    );

    if (location == null) {
      return;
    }

    var outputPath = location.path;
    if (!outputPath.toLowerCase().endsWith('.png')) {
      outputPath = '$outputPath.png';
    }

    _engine.startFrameExport(
      outputPath,
      sourceFrame: sourceFrame,
    );
  }

  Future<void> _exportBookmarkFrame(int sourceFrame) async {
    final media = _engine.media;
    if (media == null ||
        media.isStill ||
        !media.hasVideo ||
        !_engine.exportsAvailable ||
        _engine.exporting ||
        sourceFrame < 0 ||
        sourceFrame >= media.frames) {
      return;
    }

    _showOverlay();

    final stem = _mediaStem(media.name);
    final clipFrameNumber =
        _engine.clipFrameForSourceFrame(sourceFrame) + 1;
    final frameLabel = clipFrameNumber.toString().padLeft(6, '0');

    final location = await getSaveLocation(
      confirmButtonText: 'Export Bookmark',
      suggestedName: '${stem}_bookmark_$frameLabel.png',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'PNG Image',
          extensions: <String>['png'],
        ),
      ],
    );

    if (location == null) {
      return;
    }

    var outputPath = location.path;
    if (!outputPath.toLowerCase().endsWith('.png')) {
      outputPath = '$outputPath.png';
    }

    _engine.startFrameExport(
      outputPath,
      sourceFrame: sourceFrame,
    );
  }

  Future<void> _exportImageSequence() async {
    final media = _engine.media;
    if (media == null ||
        media.isStill ||
        !media.hasVideo ||
        !_engine.exportsAvailable ||
        _engine.exporting) {
      return;
    }

    _showOverlay();

    final parentDirectory = await getDirectoryPath(
      confirmButtonText: 'Export Frames',
    );

    if (parentDirectory == null) {
      return;
    }

    final stem = _mediaStem(media.name);
    final suffix = _engine.exportRangeMode == ExportRangeMode.inOut
        ? 'selection_frames'
        : (_engine.isTrimmed ? 'trimmed_frames' : 'frames');

    late final String outputDirectory;

    try {
      outputDirectory = await _createUniqueSequenceDirectory(
        parentDirectory,
        '${stem}_$suffix',
      );
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message.isEmpty
                ? 'Could not create the image-sequence directory.'
                : error.message,
          ),
        ),
      );
      return;
    }

    final started =
        _engine.startImageSequenceExport(outputDirectory);

    if (!started) {
      try {
        await Directory(outputDirectory).delete();
      } on FileSystemException {
        // Native startup failed before any sequence frame was written.
        // If the directory is no longer empty, leave it untouched.
      }
    }
  }

  Future<void> _exportAudio() async {
    final media = _engine.media;
    if (media == null ||
        media.isStill ||
        !_engine.exportHasAudio ||
        !_engine.exportsAvailable ||
        _engine.exporting) {
      return;
    }

    _showOverlay();

    final stem = _mediaStem(media.name);
    final suffix = _engine.exportRangeMode == ExportRangeMode.inOut
        ? 'selection'
        : (_engine.isTrimmed ? 'trimmed' : 'audio');

    final location = await getSaveLocation(
      confirmButtonText: 'Export Audio',
      suggestedName: '${stem}_$suffix.wav',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'WAV Audio',
          extensions: <String>['wav'],
        ),
      ],
    );

    if (location == null) {
      return;
    }

    var outputPath = location.path;
    if (!outputPath.toLowerCase().endsWith('.wav')) {
      outputPath = '$outputPath.wav';
    }

    _engine.startAudioExport(outputPath);
  }

  Future<void> _exportSelectedMode() async {
    switch (_exportMode) {
      case _ExportMode.video:
        await _exportActiveClip();
        return;
      case _ExportMode.imageSequence:
        await _exportImageSequence();
        return;
      case _ExportMode.audio:
        await _exportAudio();
        return;
    }
  }

  void _selectExportMode(_ExportMode mode) {
    if (_exportMode == mode) {
      _showOverlay();
      return;
    }

    setState(() => _exportMode = mode);
    _showOverlay();
  }

  void _selectExportRange(ExportRangeMode mode) {
    _engine.setExportRangeMode(mode);
    _showOverlay();
  }

  void _selectVideoExportPreset(VideoExportPreset preset) {
    if (_videoExportPreset == preset) {
      _showOverlay();
      return;
    }

    if (!_exportPresetBridge.setVideoExportPreset(preset)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video export preset cannot change during an export.'),
        ),
      );
      return;
    }

    setState(() => _videoExportPreset = preset);
    _showOverlay();
  }

  void _selectVideoExportFrameRate(VideoExportFrameRate frameRate) {
    if (_videoExportFrameRate == frameRate) {
      _showOverlay();
      return;
    }

    if (!_exportFrameRateBridge.setVideoExportFrameRate(frameRate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video frame rate cannot change during an export.'),
        ),
      );
      return;
    }

    setState(() => _videoExportFrameRate = frameRate);
    _showOverlay();
  }

  String _exportModeTooltip(MediaInfo media) {
    final rangeIssue = _engine.exportRangeIssue;
    if (rangeIssue != null) {
      return rangeIssue;
    }

    final rangeLabel = _engine.exportRangeMode == ExportRangeMode.inOut
        ? 'In / Out'
        : 'Whole Movie';

    switch (_exportMode) {
      case _ExportMode.video:
        return 'Export $rangeLabel with ${_videoExportPreset.label} • ${_videoExportFrameRate.label} (Ctrl+E)';
      case _ExportMode.imageSequence:
        if (!media.hasVideo) {
          return 'Image sequence unavailable for this media — hold or use ▾ to change export mode';
        }
        return 'Export $rangeLabel as composited PNG frames (Ctrl+E)';
      case _ExportMode.audio:
        if (!_engine.exportHasAudio) {
          return 'Audio export unavailable for this composition — hold or use ▾ to change export mode';
        }
        return 'Export $rangeLabel as mixed WAV audio (Ctrl+E)';
    }
  }

  void _toggleInfo() {
    setState(() => _infoOpen = !_infoOpen);
    if (_infoOpen) {
      _infoController.forward();
    } else {
      unawaited(_infoController.reverse());
    }
    _showOverlay();
  }

  void _toggleTracksInspector() {
    if (!_engine.hasLayer(1)) {
      return;
    }

    setState(() => _tracksOpen = !_tracksOpen);
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
    final controlPressed = HardwareKeyboard.instance.isControlPressed;
    final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    final altPressed = HardwareKeyboard.instance.isAltPressed;

    final primaryFocusContext = FocusManager.instance.primaryFocus?.context;
    final textInputFocused = primaryFocusContext != null &&
        (primaryFocusContext.widget is EditableText ||
            primaryFocusContext.findAncestorWidgetOfExactType<EditableText>() !=
                null);

    if (textInputFocused) {
      return KeyEventResult.ignored;
    }

    _showOverlay();

    if (event is KeyDownEvent &&
        controlPressed &&
        shiftPressed &&
        key == LogicalKeyboardKey.keyZ) {
      _engine.redo();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        key == LogicalKeyboardKey.keyZ) {
      _engine.undo();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        altPressed &&
        key == LogicalKeyboardKey.keyE) {
      if (!_engine.exporting) {
        _exportImageSequence();
      }
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        shiftPressed &&
        key == LogicalKeyboardKey.keyE) {
      if (!_engine.exporting) {
        _exportCurrentFrame();
      }
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        key == LogicalKeyboardKey.keyE) {
      if (_engine.exporting) {
        _engine.cancelExport();
      } else {
        _exportSelectedMode();
      }
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        key == LogicalKeyboardKey.keyT) {
      _engine.trimSelection();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        key == LogicalKeyboardKey.keyO) {
      _pickMedia();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        controlPressed &&
        key == LogicalKeyboardKey.keyI) {
      _toggleInfo();
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        shiftPressed &&
        key == LogicalKeyboardKey.space) {
      _engine.playSelection();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      _playFromCurrentView();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyK) {
      _engine.pausePlayback();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _engine.stepFrames(-1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      _engine.stepFrames(1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyJ) {
      _engine.shuttleReverse();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyL) {
      _engine.shuttleForward();
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

    if (!controlPressed &&
        !shiftPressed &&
        !altPressed &&
        key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyI) {
      _engine.setInPoint();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyO) {
      _engine.setOutPoint();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _exitFullscreen();
      } else if (widget.onBack != null) {
        _returnToExplorer();
      }
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

  static int _frameForClipPosition(
    MediaInfo media,
    int milliseconds,
    int frameCount,
  ) {
    if (frameCount <= 0 || media.fps <= 0) {
      return 0;
    }

    final frame = ((milliseconds / 1000.0) * media.fps).round();
    return frame.clamp(0, frameCount - 1);
  }

  double? _fractionForFrame(MediaInfo media, int? sourceFrame) {
    final frameCount = _engine.clipFrameCount;
    if (sourceFrame == null || frameCount <= 1) {
      return null;
    }

    final clipFrame = _engine.clipFrameForSourceFrame(sourceFrame);
    return clipFrame / (frameCount - 1);
  }

  static String _formatFrameDuration(MediaInfo media, int frames) {
    if (frames <= 0 || media.fps <= 0) {
      return '00:00:00:00';
    }

    // Duration is a frame count, while _formatClipTimecode() accepts a
    // zero-based frame number. Passing the count directly gives the desired
    // elapsed-frame display: 30 frames at nominal 30 fps = 00:00:01:00.
    return _formatClipTimecode(media, frames);
  }

  String _formatTransportReadout(MediaInfo media, int milliseconds) {
    final frameCount = _engine.clipFrameCount;
    final frame = _frameForClipPosition(media, milliseconds, frameCount);
    final speed = _engine.speed;

    final speedText = speed == 0.0
        ? 'Paused'
        : '${speed > 0 ? '+' : ''}${speed.toStringAsFixed(0)}×';

    if (_showTransportTimecode) {
      return 'TC ${_formatClipTimecode(media, frame)}  ·  $speedText';
    }

    return 'Frame ${frame + 1} / $frameCount  ·  $speedText';
  }

  static String _formatClipTimecode(MediaInfo media, int frame) {
    final nominalFps = media.fps.round();
    if (nominalFps <= 0) {
      return '00:00:00:00';
    }

    final framesPer24Hours = nominalFps * 60 * 60 * 24;
    var value = frame % framesPer24Hours;
    if (value < 0) {
      value += framesPer24Hours;
    }

    final hours = value ~/ (nominalFps * 3600);
    value %= nominalFps * 3600;
    final minutes = value ~/ (nominalFps * 60);
    value %= nominalFps * 60;
    final seconds = value ~/ nominalFps;
    final frames = value % nominalFps;

    final hh = hours.toString().padLeft(2, '0');
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    final ff = frames.toString().padLeft(2, '0');

    return '$hh:$mm:$ss:$ff';
  }

  static String? _formatSourceTimecode(
    MediaInfo media,
    int sourceFrame,
  ) {
    final source = media.sourceTimecode;
    if (source == null) {
      return null;
    }

    return source.atOffset(sourceFrame);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final media = _engine.media;

    return Focus(
      focusNode: _keyboardFocus,
      autofocus: widget.initialPath != null,
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
              if (_viewMode != PlayerViewMode.video) {
                _showOverlay();
              } else if (_overlayVisible) {
                _engine.togglePlayback();
              } else {
                _showOverlay();
              }
            },
            onDoubleTap: _viewMode == PlayerViewMode.video
                ? _toggleFullscreen
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                _buildViewport(media),
                _buildTopBar(media),
                if (media == null && widget.onBack != null)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: IconButton.filledTonal(
                      tooltip: 'Back to MLT Explorer',
                      onPressed: _returnToExplorer,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ),
                _buildBottomOverlay(media),
                _buildTracksInspector(media),
                SubtitleOverlay(
                  track: _subtitleTrack,
                  positionMs: _engine.positionMs,
                  enabled: media != null &&
                      media.hasVideo &&
                      !media.isStill &&
                      _viewMode == PlayerViewMode.video,
                  controlsVisible: _overlayVisible,
                  onSeek: _engine.seekTo,
                ),
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

    if (_viewMode == PlayerViewMode.storyboard && !media.isStill) {
      return StoryboardView(
        media: media,
        durationMs: _engine.durationMs,
        positionMs: _engine.positionMs,
        thumbnailService: _storyboardThumbnailService,
        sourceFrameForPositionMs: _engine.sourceFrameForClipPositionMs,
        onSeek: _seekStoryboardMoment,
        onOpenVideo: _openStoryboardMoment,
        bookmarkedFrames: _bookmarkFramesFor(media).toSet(),
        onToggleBookmark: _toggleBookmarkFrame,
      );
    }

    if (_viewMode == PlayerViewMode.bookmarks && !media.isStill) {
      return BookmarkView(
        sourcePath: media.path,
        sourceFrames: _bookmarkFramesFor(media),
        currentSourceFrame:
            _engine.sourceFrameForClipPositionMs(_engine.positionMs),
        thumbnailService: _storyboardThumbnailService,
        formatFrame: (sourceFrame) =>
            _formatBookmarkFrame(media, sourceFrame),
        onAddCurrent: _addCurrentBookmark,
        onOpenFrame: _openBookmarkFrame,
        onRemoveFrame: _removeBookmarkFrame,
        onExportFrame: (sourceFrame) =>
            unawaited(_exportBookmarkFrame(sourceFrame)),
        exportEnabled: !_engine.exporting && _engine.exportsAvailable,
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
          freeze: _engine.textureFrozen,
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
              if (widget.onBack != null) ...[
                IconButton(
                  tooltip: 'Back to MLT Explorer',
                  visualDensity: VisualDensity.compact,
                  onPressed: _returnToExplorer,
                  icon: const Icon(Icons.arrow_back, size: 20),
                ),
                const SizedBox(width: 4),
              ],
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
              ExcludeFocus(
                child: PlayerViewModeSwitch(
                  mode: _viewMode,
                  enabled: !media.isStill &&
                      media.hasVideo &&
                      _engine.durationMs > 0,
                  onChanged: _setViewMode,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'MLT ${widget.version}',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const SizedBox(width: 4),
              ExcludeFocus(
                child: MltPlayerSettingsButton(
                  settings: widget.playerSettings,
                  mltVersion: widget.version,
                  onClosed: _keyboardFocus.requestFocus,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTracksInspector(MediaInfo? media) {
    if (!_tracksOpen ||
        media == null ||
        !_engine.hasLayer(1)) {
      return const SizedBox.shrink();
    }

    final layers = _engine.layerStates;

    return Positioned(
      top: 58,
      right: 16,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        onDoubleTap: () {},
        onSecondaryTap: () {},
        child: ExcludeFocus(
          child: LayersInspector(
            layers: layers,
            formatFrame: (frame) => _formatClipTimecode(media, frame),
            baseWidth: media.width,
            baseHeight: media.height,
            canAddLayer: _engine.trackCount < layers.length,
            reorderEnabled: !_engine.opening &&
                !_engine.addingTrack &&
                !_engine.exporting,
            onAudioChanged: (layerIndex, value) =>
                _engine.setTrackAudioGain(layerIndex, value),
            onOpacityChanged: (layerIndex, value) =>
                _engine.setLayerOpacity(layerIndex, value),
            onAlphaModeChanged: (layerIndex, mode) =>
                _engine.setLayerAlphaMode(layerIndex, mode),
            onXChanged: (layerIndex, value) =>
                _engine.setLayerX(layerIndex, value),
            onYChanged: (layerIndex, value) =>
                _engine.setLayerY(layerIndex, value),
            onScaleChanged: (layerIndex, value) =>
                _engine.setLayerScale(layerIndex, value),
            onAnchorChanged: (layerIndex, anchor) =>
                _engine.setLayerAnchor(layerIndex, anchor),
            onStartNudge: (layerIndex, deltaFrames) => unawaited(
              _engine.nudgeLayerStart(layerIndex, deltaFrames),
            ),
            onEndNudge: (layerIndex, deltaFrames) => unawaited(
              _engine.nudgeLayerEnd(layerIndex, deltaFrames),
            ),
            onSourceInNudge: (layerIndex, deltaFrames) => unawaited(
              _engine.nudgeLayerSourceIn(layerIndex, deltaFrames),
            ),
            onSourceOutNudge: (layerIndex, deltaFrames) => unawaited(
              _engine.nudgeLayerSourceOut(layerIndex, deltaFrames),
            ),
            onReplaceSource: (layerIndex) => _replaceLayerSource(layerIndex),
            onToggleVisible: _engine.toggleLayerVisible,
            onAddLayer: _pickNextTrack,
            onRemoveTopLayer: _removeTopLayer,
            onMoveUp: (layerIndex) => unawaited(_moveLayerUp(layerIndex)),
            onMoveDown: (layerIndex) => unawaited(_moveLayerDown(layerIndex)),
            onClose: _toggleTracksInspector,
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
                    if (_engine.hasExportStatus) _buildExportRow(),
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
      child: MediaInspector(media: media),
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

  Widget _buildExportRow() {
    final path = _engine.exportPath;
    final name = path == null ? '' : _basename(path);

    if (_engine.exporting) {
      final percent = (_engine.exportProgress * 100).clamp(0.0, 100.0);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Icon(
              Icons.movie_creation_outlined,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Exporting ${percent.toStringAsFixed(0)}%'
                    '${name.isEmpty ? '' : '  ·  $name'}',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: _engine.exportProgress.clamp(0.0, 1.0),
                    minHeight: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _engine.cancelExport,
              child: const Text('CANCEL'),
            ),
          ],
        ),
      );
    }

    final succeeded = _engine.exportSucceeded;
    final error = _engine.exportError;
    final color = succeeded
        ? const Color(0xFF81C784)
        : const Color(0xFFE57373);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            succeeded ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              succeeded
                  ? 'Export complete${name.isEmpty ? '' : '  ·  $name'}'
                  : (error ?? 'Export failed.'),
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
          IconButton(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            tooltip: 'Dismiss export status',
            icon: const Icon(Icons.close),
            onPressed: _engine.clearExportStatus,
          ),
        ],
      ),
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash == -1 ? normalized : normalized.substring(slash + 1);
  }

  Widget _buildScrubber(MediaInfo media) {
    final durationMs = _engine.durationMs;
    final maxValue = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final value = (_scrubbing ? _scrubMs : _positionForDisplay().toDouble())
        .clamp(0.0, maxValue);

    final showHours = durationMs >= 3600000;

    final displayPositionMs =
        _scrubbing ? _scrubMs.round() : _positionForDisplay();

    final inFrame = _engine.inFrame;
    final outFrame = _engine.outFrame;
    final inFraction = _fractionForFrame(media, inFrame);
    final outFraction = _fractionForFrame(media, outFrame);
    final selectionFrames = _engine.selectionFrameCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SizedBox(
              width: showHours ? 190 : 172,
              child: Builder(
                builder: (context) {
                  final sourceFrame =
                      _engine.sourceFrameForClipPositionMs(displayPositionMs);
                  final sourceTimecode =
                      _formatSourceTimecode(media, sourceFrame);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatClock(
                          displayPositionMs,
                          forceHours: showHours,
                        ),
                        style: const TextStyle(
                          fontSize: 12,
                          fontFeatures: [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 1),
                      Tooltip(
                        message: _showTransportTimecode
                            ? 'Click to show frame number'
                            : 'Click to show clip timecode',
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              setState(() {
                                _showTransportTimecode =
                                    !_showTransportTimecode;
                              });
                              _showOverlay();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                _formatTransportReadout(
                                  media,
                                  displayPositionMs,
                                ),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white54,
                                  fontFeatures: [ui.FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (sourceTimecode != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          'SRC $sourceTimecode',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white70,
                            fontFeatures: [ui.FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
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
                      onChanged: durationMs > 0
                          ? (v) => setState(() => _scrubMs = v)
                          : null,
                      onChangeEnd: durationMs > 0
                          ? (v) {
                              setState(() => _scrubbing = false);
                              _engine.seekTo(v.round());
                              _restartOverlayTimer();
                            }
                          : null,
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _SelectionTrackPainter(
                          inFraction: inFraction,
                          outFraction: outFraction,
                          accentColor: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
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
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        if (inFrame != null || outFrame != null || _engine.isTrimmed)
          Padding(
            padding: EdgeInsets.only(
              top: 1,
              left: showHours ? 190 : 172,
              right: showHours ? 66 : 48,
            ),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              runSpacing: 2,
              children: [
                if (inFrame != null)
                  Text(
                    'IN ${_formatClipTimecode(
                      media,
                      _engine.clipFrameForSourceFrame(inFrame),
                    )}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white70,
                      fontFeatures: [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                if (outFrame != null)
                  Text(
                    'OUT ${_formatClipTimecode(
                      media,
                      _engine.clipFrameForSourceFrame(outFrame),
                    )}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white70,
                      fontFeatures: [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                if (selectionFrames > 0)
                  Text(
                    'SEL ${_formatFrameDuration(media, selectionFrames)}'
                    '  ·  $selectionFrames ${selectionFrames == 1 ? 'frame' : 'frames'}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.primary,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                if (_engine.isTrimmed)
                  Text(
                    'TRIMMED ${_formatFrameDuration(media, _engine.clipFrameCount)}'
                    '  ·  ${_engine.clipFrameCount} ${_engine.clipFrameCount == 1 ? 'frame' : 'frames'}',
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.primary,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
              ],
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
            onPressed: _playFromCurrentView,
          ),
          const SizedBox(width: 2),
          _ModeButton(
            label: 'PLAY SEL',
            tooltip: _engine.hasSelection
                ? 'Play In to Out (Shift+Space)'
                : 'Set In and Out points to play a selection',
            active: _engine.playingSelection,
            onPressed: _engine.hasSelection ? _engine.playSelection : null,
          ),
          const SizedBox(width: 2),
          _ModeButton(
            label: 'TRIM SEL',
            tooltip: _engine.canTrimSelection
                ? 'Trim movie to In/Out (Ctrl+T)'
                : 'Set a smaller In/Out selection to trim',
            active: false,
            onPressed:
                _engine.canTrimSelection ? _engine.trimSelection : null,
          ),
          const SizedBox(width: 2),
          _ModeButton(
            label: _engine.addingTrack
                ? 'ADDING…'
                : (_engine.hasLayer(1) ? 'LAYERS' : 'ADD LAYER'),
            tooltip: _engine.hasLayer(1)
                ? (_tracksOpen
                    ? 'Hide Layers Inspector'
                    : 'Open Layers Inspector')
                : 'Add video or an image layer at the current playhead',
            active: _tracksOpen,
            onPressed: _engine.hasLayer(1)
                ? _toggleTracksInspector
                : (!_engine.addingTrack && !_engine.exporting
                    ? _pickNextTrack
                    : null),
          ),
          if (_engine.hasLayer(1)) ...[
            const SizedBox(width: 2),
            _OverlayButton(
              icon: Icons.remove_circle_outline,
              tooltip: _engine.hasLayer(2)
                  ? 'Remove Layer 3 — Undo restores it'
                  : 'Remove Layer 2 — Undo restores it',
              onPressed: !_engine.opening &&
                      !_engine.addingTrack &&
                      !_engine.exporting
                  ? _removeTopLayer
                  : null,
            ),
          ],
          const SizedBox(width: 2),
          _ExportSplitButton(
            mode: _exportMode,
            videoPreset: _videoExportPreset,
            videoFrameRate: _videoExportFrameRate,
            rangeMode: _engine.exportRangeMode,
            hasInOutRange: _engine.hasSelection,
            exporting: _engine.exporting,
            tooltip: _engine.exporting
                ? 'Cancel export (Ctrl+E)'
                : _exportModeTooltip(media),
            imageSequenceEnabled: media.hasVideo,
            audioEnabled: _engine.exportHasAudio,
            onPressed: _engine.exporting
                ? _engine.cancelExport
                : (!_engine.exportsAvailable ||
                        _engine.exportRangeIssue != null ||
                        (_exportMode == _ExportMode.imageSequence && !media.hasVideo) ||
                        (_exportMode == _ExportMode.audio && !_engine.exportHasAudio)
                    ? null
                    : _exportSelectedMode),
            onModeSelected: _selectExportMode,
            onVideoPresetSelected: _selectVideoExportPreset,
            onVideoFrameRateSelected: _selectVideoExportFrameRate,
            onRangeSelected: _selectExportRange,
          ),
          if (!_engine.exporting && _engine.exportRangeIssue != null) ...[
            const SizedBox(width: 3),
            Tooltip(
              message: _engine.exportRangeIssue!,
              child: Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(width: 2),
          _OverlayButton(
            icon: Icons.bookmark_add_outlined,
            tooltip: 'Keep current frame as a soft bookmark',
            onPressed: !_engine.exporting && media.hasVideo
                ? _addCurrentBookmark
                : null,
          ),
          const SizedBox(width: 2),
          _OverlayButton(
            icon: Icons.photo_camera_outlined,
            tooltip: 'Export current frame as display-size PNG (Ctrl+Shift+E)',
            onPressed: !_engine.exporting &&
                    media.hasVideo &&
                    _engine.exportsAvailable
                ? _exportCurrentFrame
                : null,
          ),
          const SizedBox(width: 2),
          _OverlayButton(
            icon: Icons.fast_rewind,
            tooltip: 'Shuttle reverse (J)',
            onPressed: _engine.shuttleReverse,
          ),
          _OverlayButton(
            icon: Icons.fast_forward,
            tooltip: 'Shuttle forward (L)',
            onPressed: _engine.shuttleForward,
          ),
          const SizedBox(width: 4),
          _ModeButton(
            label: 'ALL FRAMES',
            tooltip: _engine.playAllFrames
                ? 'Play All Frames is on — click for real-time playback'
                : 'Play All Frames — never drop video frames',
            active: _engine.playAllFrames,
            onPressed: _engine.togglePlayAllFrames,
          ),
          const SizedBox(width: 4),
          _ModeButton(
            label: 'LOOP',
            tooltip: _engine.repeatMode == PlaybackRepeatMode.loop
                ? 'Loop playback is on'
                : 'Loop playback at the active clip boundaries',
            active: _engine.repeatMode == PlaybackRepeatMode.loop,
            onPressed: _engine.toggleLoop,
          ),
          const SizedBox(width: 4),
          if (media.hasAudio) _buildVolume(),
          const SizedBox(width: 6),
          _OverlayButton(
            icon: Icons.undo,
            tooltip: _engine.canUndo ? 'Undo (Ctrl+Z)' : 'Nothing to undo',
            onPressed: _engine.canUndo ? _engine.undo : null,
          ),
          _OverlayButton(
            icon: Icons.redo,
            tooltip: _engine.canRedo
                ? 'Redo (Ctrl+Shift+Z)'
                : 'Nothing to redo',
            onPressed: _engine.canRedo ? _engine.redo : null,
          ),
        ],
        const Spacer(),
        _OverlayButton(
          icon: Icons.folder_open,
          tooltip: 'Open media (Ctrl+O)',
          onPressed: widget.initialized && !_engine.opening ? _pickMedia : null,
        ),
        _OverlayButton(
          icon: _infoOpen ? Icons.expand_more : Icons.info_outline,
          tooltip:
              _infoOpen ? 'Hide file information (Ctrl+I)' : 'File information (Ctrl+I)',
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

class _SelectionTrackPainter extends CustomPainter {
  const _SelectionTrackPainter({
    required this.inFraction,
    required this.outFraction,
    required this.accentColor,
  });

  final double? inFraction;
  final double? outFraction;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 28 || (inFraction == null && outFraction == null)) {
      return;
    }

    // Flutter's slider track is inset by the 14 px overlay radius used by
    // this scrubber. Matching that inset keeps frame markers aligned with
    // the actual track endpoints rather than the widget's outer bounds.
    const inset = 14.0;
    final trackWidth = size.width - (inset * 2);
    if (trackWidth <= 0) {
      return;
    }

    final y = size.height / 2;

    double xFor(double fraction) =>
        inset + (fraction.clamp(0.0, 1.0) * trackWidth);

    if (inFraction != null && outFraction != null) {
      final start = xFor(inFraction!);
      final end = xFor(outFraction!);
      final selectionPaint = Paint()
        ..color = const Color(0xB3FFFFFF)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(start, y),
        Offset(end, y),
        selectionPaint,
      );
    }

    final markerPaint = Paint()
      ..color = accentColor
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    void drawMarker(double fraction) {
      final x = xFor(fraction);
      canvas.drawLine(
        Offset(x, y - 8),
        Offset(x, y + 8),
        markerPaint,
      );
      canvas.drawCircle(Offset(x, y - 9), 2.5, markerPaint);
    }

    if (inFraction != null) {
      drawMarker(inFraction!);
    }
    if (outFraction != null) {
      drawMarker(outFraction!);
    }
  }

  @override
  bool shouldRepaint(covariant _SelectionTrackPainter oldDelegate) {
    return oldDelegate.inFraction != inFraction ||
        oldDelegate.outFraction != outFraction ||
        oldDelegate.accentColor != accentColor;
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

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: active ? Colors.black : Colors.white70,
          backgroundColor:
              active ? Theme.of(context).colorScheme.primary : Colors.white10,
          minimumSize: const ui.Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.45,
          ),
        ),
      ),
    );
  }
}

class _ExportSplitButton extends StatefulWidget {
  const _ExportSplitButton({
    required this.mode,
    required this.videoPreset,
    required this.videoFrameRate,
    required this.rangeMode,
    required this.hasInOutRange,
    required this.exporting,
    required this.tooltip,
    required this.imageSequenceEnabled,
    required this.audioEnabled,
    required this.onPressed,
    required this.onModeSelected,
    required this.onVideoPresetSelected,
    required this.onVideoFrameRateSelected,
    required this.onRangeSelected,
  });

  final _ExportMode mode;
  final VideoExportPreset videoPreset;
  final VideoExportFrameRate videoFrameRate;
  final ExportRangeMode rangeMode;
  final bool hasInOutRange;
  final bool exporting;
  final String tooltip;
  final bool imageSequenceEnabled;
  final bool audioEnabled;
  final VoidCallback? onPressed;
  final ValueChanged<_ExportMode> onModeSelected;
  final ValueChanged<VideoExportPreset> onVideoPresetSelected;
  final ValueChanged<VideoExportFrameRate> onVideoFrameRateSelected;
  final ValueChanged<ExportRangeMode> onRangeSelected;

  @override
  State<_ExportSplitButton> createState() => _ExportSplitButtonState();
}

class _ExportSplitButtonState extends State<_ExportSplitButton> {
  Future<void> _showModeMenu() async {
    if (widget.exporting) {
      return;
    }

    final renderObject = context.findRenderObject();
    final overlayObject = Overlay.of(context).context.findRenderObject();

    if (renderObject is! RenderBox || overlayObject is! RenderBox) {
      return;
    }

    final topLeft = renderObject.localToGlobal(
      Offset.zero,
      ancestor: overlayObject,
    );
    final bottomRight = renderObject.localToGlobal(
      renderObject.size.bottomRight(Offset.zero),
      ancestor: overlayObject,
    );

    final selected = await showMenu<_ExportMenuChoice>(
      context: context,
      color: const Color(0xFF202020),
      elevation: 12,
      position: RelativeRect.fromRect(
        Rect.fromLTRB(
          topLeft.dx,
          bottomRight.dy,
          bottomRight.dx,
          bottomRight.dy,
        ),
        Offset.zero & overlayObject.size,
      ),
      items: <PopupMenuEntry<_ExportMenuChoice>>[
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.video,
          checked: widget.mode == _ExportMode.video,
          child: const Text('Export Video'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.imageSequence,
          checked: widget.mode == _ExportMode.imageSequence,
          enabled: widget.imageSequenceEnabled,
          child: const Text('Export Image Sequence'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.audio,
          checked: widget.mode == _ExportMode.audio,
          enabled: widget.audioEnabled,
          child: const Text('Export Audio (WAV)'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_ExportMenuChoice>(
          enabled: false,
          height: 28,
          child: Text(
            'VIDEO PRESET',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.h264Delivery,
          checked: widget.videoPreset == VideoExportPreset.h264Delivery,
          child: const Text('H.264 Delivery'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.proRes422HqMaster,
          checked: widget.videoPreset == VideoExportPreset.proRes422HqMaster,
          child: const Text('ProRes 422 HQ Master'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_ExportMenuChoice>(
          enabled: false,
          height: 28,
          child: Text(
            'VIDEO FRAME RATE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRateSource,
          checked: widget.videoFrameRate == VideoExportFrameRate.source,
          child: const Text('Source'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate23976,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps23976,
          child: const Text('23.976 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate24,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps24,
          child: const Text('24 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate25,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps25,
          child: const Text('25 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate2997,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps2997,
          child: const Text('29.97 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate30,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps30,
          child: const Text('30 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate50,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps50,
          child: const Text('50 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate5994,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps5994,
          child: const Text('59.94 fps'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.frameRate60,
          checked: widget.videoFrameRate == VideoExportFrameRate.fps60,
          child: const Text('60 fps'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_ExportMenuChoice>(
          enabled: false,
          height: 28,
          child: Text(
            'RANGE',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.wholeMovie,
          checked: widget.rangeMode == ExportRangeMode.wholeMovie,
          child: const Text('Whole Movie'),
        ),
        CheckedPopupMenuItem<_ExportMenuChoice>(
          value: _ExportMenuChoice.inOut,
          checked: widget.rangeMode == ExportRangeMode.inOut,
          enabled: widget.hasInOutRange,
          child: const Text('In / Out'),
        ),
      ],
    );

    if (!mounted || selected == null) {
      return;
    }

    switch (selected) {
      case _ExportMenuChoice.video:
        widget.onModeSelected(_ExportMode.video);
        return;
      case _ExportMenuChoice.imageSequence:
        widget.onModeSelected(_ExportMode.imageSequence);
        return;
      case _ExportMenuChoice.audio:
        widget.onModeSelected(_ExportMode.audio);
        return;
      case _ExportMenuChoice.h264Delivery:
        widget.onVideoPresetSelected(VideoExportPreset.h264Delivery);
        return;
      case _ExportMenuChoice.proRes422HqMaster:
        widget.onVideoPresetSelected(VideoExportPreset.proRes422HqMaster);
        return;
      case _ExportMenuChoice.frameRateSource:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.source);
        return;
      case _ExportMenuChoice.frameRate23976:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps23976);
        return;
      case _ExportMenuChoice.frameRate24:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps24);
        return;
      case _ExportMenuChoice.frameRate25:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps25);
        return;
      case _ExportMenuChoice.frameRate2997:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps2997);
        return;
      case _ExportMenuChoice.frameRate30:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps30);
        return;
      case _ExportMenuChoice.frameRate50:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps50);
        return;
      case _ExportMenuChoice.frameRate5994:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps5994);
        return;
      case _ExportMenuChoice.frameRate60:
        widget.onVideoFrameRateSelected(VideoExportFrameRate.fps60);
        return;
      case _ExportMenuChoice.wholeMovie:
        widget.onRangeSelected(ExportRangeMode.wholeMovie);
        return;
      case _ExportMenuChoice.inOut:
        widget.onRangeSelected(ExportRangeMode.inOut);
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.exporting;
    final mainEnabled = widget.onPressed != null;
    final menuEnabled = !widget.exporting;

    final label = widget.exporting
        ? 'CANCEL'
        : switch (widget.mode) {
            _ExportMode.video => 'EXPORT VIDEO',
            _ExportMode.imageSequence => 'EXPORT FRAMES',
            _ExportMode.audio => 'EXPORT AUDIO',
          };

    final foreground = active
        ? Colors.black
        : (mainEnabled ? Colors.white70 : Colors.white24);
    final background =
        active ? Theme.of(context).colorScheme.primary : Colors.white10;

    return Tooltip(
      message: widget.tooltip,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 30,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: widget.onPressed,
                onLongPress: menuEnabled ? _showModeMenu : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.45,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 18,
                color: active ? Colors.black26 : Colors.white12,
              ),
              InkWell(
                onTap: menuEnabled ? _showModeMenu : null,
                child: SizedBox(
                  width: 24,
                  height: 30,
                  child: Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: menuEnabled ? Colors.white54 : Colors.black38,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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
