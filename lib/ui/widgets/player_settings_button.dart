// lib/ui/widgets/player_settings_button.dart

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/player_settings_service.dart';

class MltPlayerSettingsButton extends StatelessWidget {
  const MltPlayerSettingsButton({
    super.key,
    required this.settings,
    required this.mltVersion,
    this.onClosed,
  });

  final PlayerSettingsService settings;
  final String mltVersion;
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
        await showDialog<void>(
          context: context,
          builder: (context) => _MltPlayerSettingsDialog(
            settings: settings,
            mltVersion: mltVersion,
          ),
        );
        onClosed?.call();
      },
      icon: const Icon(Icons.settings_outlined),
    );
  }
}

class _MltPlayerSettingsDialog extends StatelessWidget {
  const _MltPlayerSettingsDialog({
    required this.settings,
    required this.mltVersion,
  });

  final PlayerSettingsService settings;
  final String mltVersion;

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
        width: 520,
        child: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: settings,
            builder: (context, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionLabel('PLAYER COLOR'),
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
                          selected: settings.accentArgb == choice.argb,
                          onPressed: () {
                            unawaited(
                              settings.setAccentArgb(choice.argb).catchError(
                                (_) {},
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: settings.accentArgb ==
                            PlayerSettingsService.defaultAccentArgb
                        ? null
                        : () {
                            unawaited(
                              settings.resetAccent().catchError((_) {}),
                            );
                          },
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 0),
                    ),
                    child: const Text('RESET TO AMBER'),
                  ),
                  const SizedBox(height: 14),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 14),
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
                    'MLT Player is a media player and media manager for Linux, '
                    'built to cover many of the tasks an NLE would normally be '
                    'used for without requiring a full editing application: '
                    'sorting, rating, trimming, bookmarking, and exporting.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Flutter owns the application. MLT owns the media.',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Runtime: MLT $mltVersion',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 4),
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
