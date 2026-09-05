import 'package:flutter/material.dart';

/// User avatar: photo when available, initial letter otherwise.
/// Single place for the fallback so every list agrees.
class UserAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String username;
  final double radius;
  final Color fallbackColor;
  const UserAvatar({
    super.key,
    required this.avatarUrl,
    required this.username,
    this.radius = 16,
    this.fallbackColor = const Color(0xFFFF5757),
  });

  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.grey[800],
        backgroundImage: NetworkImage(avatarUrl!),
        onBackgroundImageError: (_, __) {},
        child: const SizedBox.shrink(),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: fallbackColor,
      child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?',
          style: TextStyle(color: Colors.white, fontSize: radius * 0.85)),
    );
  }
}
