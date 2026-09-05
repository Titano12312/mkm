import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import '../services/socket_service.dart';
import 'user_avatar.dart';

/// Settings sheet: avatar photo, username rename, account email.
/// Opened from the gear icon in the sidebar user strip.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _name;
  bool _savingName = false;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: context.read<SocketService>().username);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    setState(() {
      _savingName = true;
      _error = null;
    });
    try {
      final err = await context.read<SocketService>().updateUsername(_name.text);
      if (!mounted) return;
      if (err == null) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Username updated.')),
        );
      } else {
        setState(() => _error = _usernameErrorText(err));
      }
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _pickAvatar() async {
    final chat = context.read<SocketService>();
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return; // user cancelled
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 2 * 1024 * 1024) {
        setState(() => _error = 'Image too large — 2 MB max.');
        return;
      }
      final path = '${chat.userId}/avatar.jpg';
      await AuthService.client.storage.from('avatars').uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
          );
      final url = AuthService.client.storage.from('avatars').getPublicUrl(path);
      // Cache-bust so every device refetches the new photo immediately.
      final err = await chat.updateAvatarUrl('$url?t=${DateTime.now().millisecondsSinceEpoch}');
      if (!mounted) return;
      if (err != null) setState(() => _error = 'Could not save photo ($err).');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not upload photo — retry.');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Settings',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Row(
              children: [
                GestureDetector(
                  onTap: _uploading ? null : _pickAvatar,
                  child: Stack(
                    children: [
                      UserAvatar(
                        avatarUrl: chat.myAvatarUrl,
                        username: chat.username,
                        radius: 30,
                      ),
                      if (_uploading)
                        const Positioned.fill(
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF5757),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.edit, size: 12, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(chat.username,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(chat.myEmail ?? '…',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Username', style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    autocorrect: false,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '2–24 letters, numbers, _',
                      hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF1E1F22),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    onSubmitted: (_) => _saveName(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _savingName ? null : _saveName,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF5757),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _savingName
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text('Friends add you with this exact name.',
                style: TextStyle(color: Colors.grey, fontSize: 11)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

String _usernameErrorText(String code) {
  switch (code) {
    case 'taken':
      return 'That username is taken — try another.';
    case 'invalid':
      return 'Use 2–24 letters, numbers or underscores.';
    case 'offline':
      return 'Not connected — retry in a moment.';
    default:
      return 'Could not save ($code).';
  }
}

/// Opens the settings sheet (adaptive: bottom sheet, works both layouts).
Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF2B2D31),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const SettingsSheet(),
  );
}
