import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/socket_service.dart';

/// Shared social dialogs (used by the sidebar AND the empty home).
/// Single intent per dialog; errors inline under the field.

/// Add-friend dialog: invite by username (unique per account).
Future<void> showAddFriendDialog(BuildContext context) async {
  final username = TextEditingController();
  String? error;
  bool busy = false;
  final chat = context.read<SocketService>();

  Future<void> doSend(StateSetter setState, BuildContext ctx) async {
    if (busy || username.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    final err = await chat.sendFriendRequest(username.text);
    if (!ctx.mounted) return;
    if (err == null) {
      Navigator.of(ctx).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite sent.')),
      );
    } else {
      setState(() {
        busy = false;
        error = err;
      });
    }
  }

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: const Text('Add friend', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Their username:', style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: username,
              keyboardType: TextInputType.text,
              autocorrect: false,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'marco_1',
                hintStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: const Color(0xFF1E1F22),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              onSubmitted: (_) => doSend(setState, ctx),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(_friendErrorText(error!),
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: busy ? null : () => doSend(setState, ctx),
            child: const Text('Send invite'),
          ),
        ],
      ),
    ),
  );
  username.dispose();
}

String _friendErrorText(String code) {
  switch (code) {
    case 'not-found':
      return 'No user with that username yet.';
    case 'self':
      return 'That is your own username.';
    case 'already-friends':
      return 'You are already friends.';
    case 'already-pending':
      return 'Invite already pending.';
    case 'offline':
      return 'Not connected — retry in a moment.';
    default:
      return 'Could not send invite ($code).';
  }
}

/// Create-group dialog: name + pick from friends (groups are opt-in only).
Future<void> showCreateGroupDialog(BuildContext context) async {
  final chat = context.read<SocketService>();
  if (chat.friends.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add friends first, then create a group.')),
    );
    return;
  }
  final name = TextEditingController();
  final selected = <String>{};
  bool busy = false;
  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: const Color(0xFF2B2D31),
        title: const Text('New group', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Group name',
                  hintStyle: const TextStyle(color: Colors.grey),
                  filled: true,
                  fillColor: const Color(0xFF1E1F22),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Invite friends:', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in chat.friends)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(f.username,
                            style: const TextStyle(color: Colors.white, fontSize: 13)),
                        value: selected.contains(f.userId),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            selected.add(f.userId);
                          } else {
                            selected.remove(f.userId);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: busy || selected.isEmpty
                ? null
                : () async {
                    setState(() => busy = true);
                    final id = await ctx
                        .read<SocketService>()
                        .createGroup(name.text, selected.toList());
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                    if (id != null) {
                      context.read<SocketService>().openConversation(id);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Could not create group.')),
                      );
                    }
                  },
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
}
