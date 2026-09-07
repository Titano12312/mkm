import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/socket_service.dart';

/// Toasts for messages arriving outside the open view (DMs, groups, and
/// server channels alike). The SnackBar has a View action that jumps
/// straight into the conversation — nothing arrives silently anymore.
///
/// Own messages never toast. Counts are baselined on first sight so
/// history loads don't burst a toast per old message.
class MessageToastHost extends StatefulWidget {
  const MessageToastHost({super.key});
  @override
  State<MessageToastHost> createState() => _MessageToastHostState();
}

class _MessageToastHostState extends State<MessageToastHost> {
  final Map<String, int> _seenCounts = {};

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<SocketService>();

    final counts = <String, int>{};
    for (final c in chat.conversations) {
      counts['conv:${c.id}'] = chat.convMessagesFor(c.id).length;
    }
    for (final t in chat.textChannels) {
      counts['channel:${t.id}'] = chat.messagesFor(t.id).length;
    }
    // Diff post-frame: SnackBars must not be shown during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _diff(counts));
    return const SizedBox.shrink();
  }

  void _diff(Map<String, int> counts) {
    if (!mounted) return;
    final chat = context.read<SocketService>();
    for (final entry in counts.entries) {
      final prev = _seenCounts[entry.key];
      if (prev == null) {
        _seenCounts[entry.key] = entry.value; // baseline, no toast
        continue;
      }
      if (entry.value <= prev) continue;
      _seenCounts[entry.key] = entry.value;

      final parts = entry.key.split(':');
      final isConv = parts[0] == 'conv';
      final id = parts.sublist(1).join(':');
      // Skip the open view.
      if (isConv && id == chat.activeConversationId) continue;
      if (!isConv && id == chat.activeTextChannelId) continue;
      // Skip our own sends (echo of what we just wrote).
      final lastAuthor = isConv
          ? (chat.convMessagesFor(id).isEmpty
              ? null
              : chat.convMessagesFor(id).last.authorId)
          : (chat.messagesFor(id).isEmpty ? null : chat.messagesFor(id).last.authorId);
      if (lastAuthor == chat.userId) continue;
      // Blocked authors stay silent everywhere, toasts included.
      if (lastAuthor != null && chat.blockedIds.contains(lastAuthor)) continue;

      final label = isConv
          ? (chat.conversationById(id)?.title(chat.userId) ?? 'New message')
          : '#$id';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('New message in $label'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () {
              if (isConv) {
                chat.openConversation(id);
              } else {
                chat.selectTextChannel(id);
              }
            },
          ),
        ),
      );
    }
  }
}
