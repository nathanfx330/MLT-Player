// lib/ui/explorer_page.dart

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/explorer_item.dart';
import '../services/explorer_service.dart';

class ExplorerPage extends StatefulWidget {
  const ExplorerPage({
    super.key,
    required this.initialized,
    required this.version,
    required this.onOpenMedia,
    this.startupError,
    this.active = true,
  });

  final bool initialized;
  final String version;
  final String? startupError;
  final ValueChanged<String> onOpenMedia;
  final bool active;

  @override
  State<ExplorerPage> createState() => _ExplorerPageState();
}

class _ExplorerPageState extends State<ExplorerPage> {
  final ExplorerService _service = ExplorerService();
  final FocusNode _focusNode = FocusNode(debugLabel: 'mlt-explorer');

  String? _directoryPath;
  List<ExplorerItem> _items = const <ExplorerItem>[];
  int? _selectedIndex;
  bool _loading = false;
  String? _error;
  int _scanSerial = 0;

  ExplorerItem? get _selectedItem {
    final index = _selectedIndex;
    if (index == null || index < 0 || index >= _items.length) {
      return null;
    }
    return _items[index];
  }

  @override
  void didUpdateWidget(covariant ExplorerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open Folder');
    if (path == null || path.isEmpty) {
      return;
    }
    await _loadDirectory(path);
  }

  Future<void> _pickMedia() async {
    final file = await openFile(
      confirmButtonText: 'Open',
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'Media',
          extensions: ExplorerService.supportedExtensions,
        ),
      ],
    );

    if (file != null) {
      widget.onOpenMedia(file.path);
    }
  }

  Future<void> _loadDirectory(String path) async {
    final serial = ++_scanSerial;
    setState(() {
      _loading = true;
      _error = null;
      _selectedIndex = null;
    });

    try {
      final items = await _service.scanDirectory(path);
      if (!mounted || serial != _scanSerial) {
        return;
      }

      setState(() {
        _directoryPath = path;
        _items = items;
        _loading = false;
      });
    } on FileSystemException catch (error) {
      if (!mounted || serial != _scanSerial) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.isEmpty
            ? 'Could not read that directory.'
            : error.message;
      });
    } catch (error) {
      if (!mounted || serial != _scanSerial) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _goUp() async {
    final path = _directoryPath;
    if (path == null) {
      return;
    }

    final current = Directory(path).absolute;
    final parent = current.parent;
    if (parent.path == current.path) {
      return;
    }
    await _loadDirectory(parent.path);
  }

  Future<void> _activate(ExplorerItem item) async {
    if (item.isDirectory) {
      await _loadDirectory(item.path);
      return;
    }
    widget.onOpenMedia(item.path);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final control = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (event is KeyDownEvent &&
        control &&
        shift &&
        key == LogicalKeyboardKey.keyO) {
      unawaited(_pickFolder());
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent &&
        control &&
        key == LogicalKeyboardKey.keyO) {
      unawaited(_pickMedia());
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter) {
      final item = _selectedItem;
      if (item != null) {
        unawaited(_activate(item));
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.backspace && _directoryPath != null) {
      unawaited(_goUp());
      return KeyEventResult.handled;
    }

    if (_items.isEmpty) {
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      final next = ((_selectedIndex ?? -1) + 1)
          .clamp(0, _items.length - 1)
          .toInt();
      setState(() => _selectedIndex = next);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      final next = ((_selectedIndex ?? 1) - 1)
          .clamp(0, _items.length - 1)
          .toInt();
      setState(() => _selectedIndex = next);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.active,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        body: SafeArea(
          child: Column(
            children: [
              _buildToolbar(),
              const Divider(height: 1, color: Colors.white12),
              Expanded(child: _buildBody()),
              _buildStatusBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final canGoUp = _directoryPath != null &&
        Directory(_directoryPath!).absolute.parent.path !=
            Directory(_directoryPath!).absolute.path;

    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.collections_outlined, size: 22),
            const SizedBox(width: 9),
            const Text(
              'MLT Explorer',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 16),
            IconButton(
              tooltip: 'Up one folder (Backspace)',
              onPressed: canGoUp && !_loading ? _goUp : null,
              icon: const Icon(Icons.arrow_upward),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 34,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                decoration: BoxDecoration(
                  color: const Color(0x0FFFFFFF),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                child: Text(
                  _directoryPath ?? 'No folder open',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: widget.initialized && !_loading ? _pickMedia : null,
              icon: const Icon(Icons.movie_outlined, size: 18),
              label: const Text('OPEN FILE'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: !_loading ? _pickFolder : null,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('OPEN FOLDER'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (!widget.initialized) {
      return _buildUnavailable();
    }

    if (_directoryPath == null) {
      return _buildWelcome();
    }

    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE57373)),
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined, size: 64, color: Colors.white24),
            SizedBox(height: 14),
            Text(
              'No supported media in this folder',
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final selected = _selectedItem;
        final showDetails = constraints.maxWidth >= 900;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(14),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 190,
                  mainAxisExtent: 150,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return _ExplorerCard(
                    item: item,
                    selected: _selectedIndex == index,
                    onTap: () {
                      _focusNode.requestFocus();
                      setState(() => _selectedIndex = index);
                    },
                    onDoubleTap: () => unawaited(_activate(item)),
                  );
                },
              ),
            ),
            if (showDetails) ...[
              const VerticalDivider(width: 1, color: Colors.white12),
              SizedBox(
                width: 280,
                child: _ExplorerSelectionPane(
                  item: selected,
                  onOpen: selected == null
                      ? null
                      : () => unawaited(_activate(selected)),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.collections_outlined, size: 76, color: Colors.white24),
          const SizedBox(height: 18),
          const Text(
            'MLT Explorer',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Open a folder to browse media.',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Folder'),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _pickMedia,
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Open one media file instead'),
          ),
        ],
      ),
    );
  }

  Widget _buildUnavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 58, color: Color(0xFFE57373)),
            const SizedBox(height: 16),
            const Text(
              'MLT is unavailable',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (widget.startupError != null && widget.startupError!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                widget.startupError!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFE57373)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    final selected = _selectedItem;

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF171717),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Text(
            _directoryPath == null
                ? 'Ready'
                : '${_items.length} ${_items.length == 1 ? 'item' : 'items'}',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
          if (selected != null) ...[
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                selected.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ] else
            const Spacer(),
          Text(
            'MLT ${widget.version}',
            style: const TextStyle(fontSize: 10, color: Colors.white30),
          ),
        ],
      ),
    );
  }
}

class _ExplorerCard extends StatelessWidget {
  const _ExplorerCard({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
  });

  final ExplorerItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      ExplorerItemKind.directory => Icons.folder,
      ExplorerItemKind.video => Icons.movie_outlined,
      ExplorerItemKind.audio => Icons.graphic_eq,
      ExplorerItemKind.image => Icons.image_outlined,
      ExplorerItemKind.project => Icons.account_tree_outlined,
    };

    return Material(
      color: selected
          ? const Color(0x33E8A33D)
          : const Color(0xFF1B1B1B),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? const Color(0xFFE8A33D) : Colors.white10,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(
                    child: Icon(icon, size: 52, color: Colors.white30),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 8, 9, 3),
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
                child: Text(
                  item.isDirectory
                      ? 'Folder'
                      : item.extension.toUpperCase(),
                  style: const TextStyle(fontSize: 9, color: Colors.white30),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExplorerSelectionPane extends StatelessWidget {
  const _ExplorerSelectionPane({
    required this.item,
    required this.onOpen,
  });

  final ExplorerItem? item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Select a file or folder',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ),
      );
    }

    final icon = switch (item.kind) {
      ExplorerItemKind.directory => Icons.folder,
      ExplorerItemKind.video => Icons.movie_outlined,
      ExplorerItemKind.audio => Icons.graphic_eq,
      ExplorerItemKind.image => Icons.image_outlined,
      ExplorerItemKind.project => Icons.account_tree_outlined,
    };

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'SELECTION',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 24),
          Icon(icon, size: 72, color: Colors.white24),
          const SizedBox(height: 20),
          Text(
            item.name,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            item.path,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: onOpen,
            icon: Icon(item.isDirectory ? Icons.folder_open : Icons.play_arrow),
            label: Text(item.isDirectory ? 'OPEN FOLDER' : 'OPEN IN PLAYER'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Double-click an item to open it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: Colors.white30),
          ),
        ],
      ),
    );
  }
}
