import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/motion.dart';
import 'social_dialogs.dart';

/// Empty home: shown when no channel and no conversation is open.
/// Per taste rules: composed (not a bare string), states HOW to populate,
/// one primary intent (add a friend), secondary link for groups.
class HomeEmpty extends StatelessWidget {
  const HomeEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final reduce = Motion.reduce(context);
    final mark = ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Image.asset(
        'assets/logo.png',
        width: 72,
        height: 72,
        fit: BoxFit.cover,
      ),
    );
    return Container(
      color: const Color(0xFF313338),
      // Ambient brand blobs drifting behind the content (transform-only,
      // low opacity, static under reduced motion).
      child: Stack(
        children: [
          if (!reduce) ...[
            const Positioned(
              top: -60,
              left: -70,
              child: _Blob(color: Color(0xFF5865F2), delay: 0),
            ),
            const Positioned(
              bottom: -80,
              right: -60,
              child: _Blob(color: Color(0xFF949CF7), delay: 1500),
            ),
          ],
          Center(
            child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              reduce
                  ? mark
                  : mark
                      .animate()
                      .scale(
                        begin: const Offset(0.6, 0.6),
                        end: const Offset(1, 1),
                        duration: Motion.playful,
                        curve: Motion.spring,
                      )
                      .fadeIn(duration: Motion.fast),
              const SizedBox(height: 20),
              const Text('No chats yet',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Add friends to start private chats. Groups are optional — create one only if you want it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: () => showAddFriendDialog(context),
                  icon: const Icon(Icons.person_add, size: 18),
                  label: const Text('Add a friend', style: TextStyle(fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5865F2),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => showCreateGroupDialog(context),
                child: const Text('or create a group',
                    style: TextStyle(color: Color(0xFF949CF7), fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
      ),
        ],
      ),
    );
  }
}

/// Soft radial brand glow. Drifts slowly on a loop; pure decoration.
class _Blob extends StatelessWidget {
  final Color color;
  final int delay;
  const _Blob({required this.color, required this.delay});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withAlpha(46), color.withAlpha(0)],
        ),
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .move(
          begin: Offset.zero,
          end: const Offset(24, 32),
          duration: const Duration(seconds: 7),
          delay: Duration(milliseconds: delay),
        );
  }
}
