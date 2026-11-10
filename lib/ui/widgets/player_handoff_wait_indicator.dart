// lib/ui/widgets/player_handoff_wait_indicator.dart

import 'package:flutter/material.dart';

import '../../services/player_handoff_wait_controller.dart';

/// Compact, non-modal status while Player waits for an earlier MLT thumbnail
/// decode to finish. This does not cancel work or bypass the safety barrier.
class PlayerHandoffWaitIndicator extends StatelessWidget {
  const PlayerHandoffWaitIndicator({
    super.key,
    required this.controller,
  });

  final PlayerHandoffWaitController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.showIndicator) return const SizedBox.shrink();

        return IgnorePointer(
          child: Material(
            key: const ValueKey('player-thumbnail-drain-indicator'),
            color: const Color(0xFF222222),
            elevation: 7,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 11,
              ),
              child: Semantics(
                liveRegion: true,
                label: 'Finishing thumbnail before opening Player',
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFE8A33D),
                      ),
                    ),
                    SizedBox(width: 11),
                    Text(
                      'Finishing thumbnail…',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
