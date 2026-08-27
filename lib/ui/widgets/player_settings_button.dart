// lib/ui/widgets/player_settings_button.dart

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/player_settings_service.dart';
import '../../services/redleaf_connection_service.dart';

class MltPlayerSettingsButton extends StatelessWidget {
  const MltPlayerSettingsButton({
    super.key,
    required this.settings,
    required this.mltVersion,
    this.redleaf,
    this.onClosed,
  });

  final PlayerSettingsService settings;
  final String mltVersion;
  final RedleafConnectionService? redleaf;
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Settings',
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: () async {
        final redleafService = redleaf ?? RedleafConnectionService.instance;
        await redleafService.load();
        if (!context.mounted) {
          return;
        }

        await showDialog<void>(
          context: context,
          builder: (context) => _MltPlayerSettingsDialog(
            settings: settings,
            mltVersion: mltVersion,
            redleaf: redleafService,
          ),
        );
        onClosed?.call();
      },
      icon: const Icon(Icons.settings_outlined),
    );
  }
}

class _MltPlayerSettingsDialog extends StatefulWidget {
  const _MltPlayerSettingsDialog({
    required this.settings,
    required this.mltVersion,
    required this.redleaf,
  });

  final PlayerSettingsService settings;
  final String mltVersion;
  final RedleafConnectionService redleaf;

  @override
  State<_MltPlayerSettingsDialog> createState() =>
      _MltPlayerSettingsDialogState();
}

class _MltPlayerSettingsDialogState extends State<_MltPlayerSettingsDialog> {
  static const List<_AccentChoice> _choices = <_AccentChoice>[
    _AccentChoice('Amber', 0xFFE8A33D),
    _AccentChoice('Orange', 0xFFFF8A50),
    _AccentChoice('Red', 0xFFE57373),
    _AccentChoice('Pink', 0xFFEC6FA8),
    _AccentChoice('Purple', 0xFFAB7AE6),
    _AccentChoice('Blue', 0xFF5AA9E6),
    _AccentChoice('Cyan', 0xFF4DD0E1),
    _AccentChoice('Green', 0xFF66BB6A),
  ];

  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: widget.redleaf.serverUrl);
    _usernameController = TextEditingController(text: widget.redleaf.username);
    _passwordController = TextEditingController();
    widget.redleaf.addListener(_onRedleafChanged);
  }

  @override
  void dispose() {
    widget.redleaf.removeListener(_onRedleafChanged);
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onRedleafChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _signIn() async {
    final success = await widget.redleaf.signIn(
      serverUrl: _serverController.text,
      username: _usernameController.text,
      password: _passwordController.text,
    );

    if (success && mounted) {
      _passwordController.clear();
    }
  }

  void _disconnect() {
    widget.redleaf.disconnect();
    _passwordController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.settings_outlined, size: 22),
          SizedBox(width: 10),
          Text('Settings'),
        ],
      ),
      content: SizedBox(
        width: 570,
        child: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: widget.settings,
            builder: (context, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionLabel('PLAYER'),
                  const SizedBox(height: 5),
                  const Text(
                    'Choose the accent used for active Player controls, '
                    'Storyboard selections, Bookmarks, markers, and export state.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final choice in _choices)
                        _ColorChoice(
                          choice: choice,
                          selected: widget.settings.accentArgb == choice.argb,
                          onPressed: () {
                            unawaited(
                              widget.settings.setAccentArgb(choice.argb).catchError(
                                    (_) {},
                                  ),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: widget.settings.accentArgb ==
                            PlayerSettingsService.defaultAccentArgb
                        ? null
                        : () {
                            unawaited(
                              widget.settings.resetAccent().catchError((_) {}),
                            );
                          },
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 0),
                    ),
                    child: const Text('RESET TO AMBER'),
                  ),
                  const _SettingsDivider(),
                  const _SectionLabel('REDLEAF'),
                  const SizedBox(height: 6),
                  const Text(
                    'Redleaf is a document search and research engine. MLT Player '
                    'connects to Redleaf so indexed SRT transcripts with linked '
                    'audio or video can be handed off for fast scrubbing, clipping, '
                    'composition, watermarking, and export.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildRedleafForm(context),
                  const _SettingsDivider(),
                  const _SectionLabel('MEDIA ENGINE'),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: 'MLT Runtime',
                    value: widget.mltVersion.trim().isEmpty
                        ? 'Unknown'
                        : widget.mltVersion.trim(),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'MLT is the media engine used for playback, frame-accurate '
                    'navigation, thumbnails, composition, and export.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: Colors.white54,
                    ),
                  ),
                  const _SettingsDivider(),
                  const _SectionLabel('ABOUT'),
                  const SizedBox(height: 8),
                  Text(
                    'MLT Player 1.0',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'by Nathaniel Westveer',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'A filesystem-first media browser, project organizer, and '
                    'precision player for Linux. The filesystem owns the media. '
                    'Projects organize it. MLT plays and transforms it.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const SelectableText(
                    'github.com/nathanfx330/MLT-Player',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }

  Widget _buildRedleafForm(BuildContext context) {
    final redleaf = widget.redleaf;
    final signingIn = redleaf.status == RedleafConnectionStatus.signingIn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _serverController,
          enabled: !signingIn,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Server',
            hintText: 'http://127.0.0.1:5000',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _usernameController,
          enabled: !signingIn,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            isDense: true,
            labelText: 'Username',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passwordController,
          enabled: !signingIn,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!signingIn) {
              unawaited(_signIn());
            }
          },
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Password',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscurePassword ? 'Show password' : 'Hide password',
              onPressed: signingIn
                  ? null
                  : () => setState(
                        () => _obscurePassword = !_obscurePassword,
                      ),
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'The server address and username are remembered. Your password is '
          'used to create the Redleaf session and is not saved by MLT Player.',
          style: TextStyle(
            fontSize: 10.5,
            height: 1.35,
            color: Colors.white38,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: signingIn ? null : _signIn,
              icon: signingIn
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login, size: 17),
              label: Text(signingIn ? 'SIGNING IN…' : 'SIGN IN'),
            ),
            if (redleaf.isConnected) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _disconnect,
                child: const Text('DISCONNECT'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        _RedleafStatusBlock(redleaf: redleaf),
      ],
    );
  }
}

class _RedleafStatusBlock extends StatelessWidget {
  const _RedleafStatusBlock({required this.redleaf});

  final RedleafConnectionService redleaf;

  @override
  Widget build(BuildContext context) {
    final (icon, color, title) = switch (redleaf.status) {
      RedleafConnectionStatus.connected => (
          Icons.check_circle,
          Colors.greenAccent,
          'Connected to Redleaf',
        ),
      RedleafConnectionStatus.signingIn => (
          Icons.sync,
          Theme.of(context).colorScheme.primary,
          'Signing in to Redleaf…',
        ),
      RedleafConnectionStatus.error => (
          Icons.error_outline,
          Colors.redAccent,
          'Redleaf connection failed',
        ),
      RedleafConnectionStatus.disconnected => (
          Icons.radio_button_unchecked,
          Colors.white38,
          'Not connected to Redleaf',
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0x0CFFFFFF),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                if (redleaf.isConnected) ...[
                  const SizedBox(height: 5),
                  Text(
                    'Server: ${redleaf.serverUrl}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white60,
                    ),
                  ),
                  Text(
                    'User: ${redleaf.username}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white60,
                    ),
                  ),
                  if (redleaf.instanceId.isNotEmpty)
                    Text(
                      'Instance: ${_shortInstanceId(redleaf.instanceId)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                  if (redleaf.projectName.isNotEmpty)
                    Text(
                      'Project: ${redleaf.projectName}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white60,
                      ),
                    ),
                  const SizedBox(height: 10),
                  const Divider(height: 1, color: Colors.white12),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'INDEXED FILES',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          unawaited(redleaf.refreshInventory());
                        },
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          minimumSize: const Size(0, 24),
                        ),
                        icon: const Icon(Icons.refresh, size: 13),
                        label: const Text(
                          'REFRESH',
                          style: TextStyle(fontSize: 9.5),
                        ),
                      ),
                    ],
                  ),
                  if (redleaf.inventoryLoaded) ...[
                    Text(
                      '${_formatCount(redleaf.totalDocumentCount)} total indexed files',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _InventoryTypeWrap(redleaf: redleaf),
                  ] else if (redleaf.inventoryError != null) ...[
                    Text(
                      'File inventory unavailable',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      redleaf.inventoryError!,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: Colors.white54,
                      ),
                    ),
                  ] else ...[
                    const Text(
                      'No file inventory has been read yet.',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.white54,
                      ),
                    ),
                  ],
                ],
                if (redleaf.status == RedleafConnectionStatus.error &&
                    redleaf.lastError != null) ...[
                  const SizedBox(height: 5),
                  Text(
                    redleaf.lastError!,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _shortInstanceId(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 12) {
      return trimmed;
    }
    return '${trimmed.substring(0, 12)}…';
  }

  static String _formatCount(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer();

    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[i]);
    }

    return value < 0 ? '-$buffer' : buffer.toString();
  }
}

class _InventoryTypeWrap extends StatelessWidget {
  const _InventoryTypeWrap({required this.redleaf});

  final RedleafConnectionService redleaf;

  @override
  Widget build(BuildContext context) {
    final entries = redleaf.fileTypeCounts.entries.toList()
      ..sort(
        (a, b) => a.key.toUpperCase().compareTo(b.key.toUpperCase()),
      );

    final items = <Widget>[
      for (final entry in entries)
        _InventoryTypePill(
          label: entry.key,
          count: entry.value,
        ),
      if (redleaf.unknownFileTypeCount > 0)
        _InventoryTypePill(
          label: 'UNKNOWN',
          count: redleaf.unknownFileTypeCount,
        ),
    ];

    if (items.isEmpty) {
      return const Text(
        'No indexed file types reported.',
        style: TextStyle(
          fontSize: 10.5,
          color: Colors.white54,
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: items,
    );
  }
}

class _InventoryTypePill extends StatelessWidget {
  const _InventoryTypePill({
    required this.label,
    required this.count,
  });

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.white12),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: label.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.white60,
              ),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: _formatCount(count),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatCount(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer();

    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[i]);
    }

    return value < 0 ? '-$buffer' : buffer.toString();
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Divider(height: 1, color: Colors.white12),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white54,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        color: Colors.white54,
      ),
    );
  }
}

class _AccentChoice {
  const _AccentChoice(this.label, this.argb);

  final String label;
  final int argb;
}

class _ColorChoice extends StatelessWidget {
  const _ColorChoice({
    required this.choice,
    required this.selected,
    required this.onPressed,
  });

  final _AccentChoice choice;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = Color(choice.argb);

    return Tooltip(
      message: choice.label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 50,
          height: 46,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? Colors.white70 : Colors.white12,
              width: selected ? 2 : 1,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(5),
            ),
            child: selected
                ? const Icon(
                    Icons.check,
                    size: 20,
                    color: Colors.black87,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
