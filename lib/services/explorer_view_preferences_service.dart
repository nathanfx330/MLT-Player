// lib/services/explorer_view_preferences_service.dart

import 'dart:convert';
import 'dart:io';

import 'explorer_sort_filter_service.dart';

class ExplorerViewPreferencesService {
  ExplorerViewPreferencesService({Directory? configDirectory})
      : _configDirectory = configDirectory ?? _defaultConfigDirectory();

  static const int minDensityIndex = 0;
  static const int maxDensityIndex = 4;
  static const int defaultDensityIndex = 2;

  static const List<String> densityLabels = <String>[
    'Compact',
    'Small',
    'Standard',
    'Large',
    'Extra Large',
  ];

  static const List<double> _thumbnailExtents = <double>[
    130,
    160,
    190,
    230,
    280,
  ];

  static const List<double> _cardHeights = <double>[
    112,
    130,
    150,
    178,
    214,
  ];

  static const List<double> _gridSpacings = <double>[
    7,
    8,
    10,
    11,
    12,
  ];

  final Directory _configDirectory;
  int _densityIndex = defaultDensityIndex;
  ExplorerSortMode _sortMode = ExplorerSortMode.name;
  bool _sortDescending = false;
  Future<void> _writeTail = Future<void>.value();

  int get densityIndex => _densityIndex;
  String get densityLabel => densityLabels[_densityIndex];
  double get thumbnailExtent => _thumbnailExtents[_densityIndex];
  double get cardHeight => _cardHeights[_densityIndex];
  double get gridSpacing => _gridSpacings[_densityIndex];
  ExplorerSortMode get sortMode => _sortMode;
  bool get sortDescending => _sortDescending;

  void setDensityIndex(int value) {
    _densityIndex = value.clamp(minDensityIndex, maxDensityIndex).toInt();
  }

  void setSortMode(ExplorerSortMode value) {
    _sortMode = value;
  }

  void setSortDescending(bool value) {
    _sortDescending = value;
  }

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

      final density = decoded['thumbnailDensity'];
      if (density is int) {
        setDensityIndex(density);
      }

      final sortMode = decoded['sortMode'];
      if (sortMode is String) {
        final restoredMode = ExplorerSortMode.values.where(
          (mode) => mode.name == sortMode,
        );
        if (restoredMode.isNotEmpty) {
          _sortMode = restoredMode.first;
        }
      }

      final sortDescending = decoded['sortDescending'];
      if (sortDescending is bool) {
        _sortDescending = sortDescending;
      }
    } catch (_) {
      _resetDefaults();
    }
  }

  Future<void> save() {
    final contents = jsonEncode(<String, Object>{
      'version': 2,
      'thumbnailDensity': _densityIndex,
      'sortMode': _sortMode.name,
      'sortDescending': _sortDescending,
    });

    final previousWrite = _writeTail;
    _writeTail = () async {
      try {
        await previousWrite;
      } catch (_) {
        // A later save should still be attempted after an earlier I/O failure.
      }

      await _configDirectory.create(recursive: true);
      await _stateFile.writeAsString(contents, flush: true);
    }();

    return _writeTail;
  }

  void _resetDefaults() {
    _densityIndex = defaultDensityIndex;
    _sortMode = ExplorerSortMode.name;
    _sortDescending = false;
  }

  File get _stateFile => File('${_configDirectory.path}/explorer_view.json');

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
