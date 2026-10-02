import 'package:flutter/material.dart';
import 'package:localsend_app/chat/chat_provider.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:refena_flutter/refena_flutter.dart';

Future<bool> confirmClearChat(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.chat.clear),
        content: Text(t.chat.clearNotice),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(t.general.cancel)),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(t.chat.clear)),
        ],
      ),
    ) ??
    false;

class ChatSettingsPage extends StatelessWidget {
  const ChatSettingsPage();
  @override
  Widget build(BuildContext context) {
    final state = context.watch(chatProvider);
    final service = context.notifier(chatProvider);
    Future<void> action(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (_) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.chat.actionFailed)));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(t.chat.settings)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              SwitchListTile(
                title: Text(t.chat.enable),
                subtitle: Text(t.chat.backgroundNotice),
                value: state.enabled,
                onChanged: (enabled) => action(() => service.setEnabled(enabled)),
              ),
              const SizedBox(height: 24),
              Text(t.chat.authorizedDevices, style: Theme.of(context).textTheme.titleLarge),
              ...state.peers
                  .where((p) => p.authorized)
                  .map(
                    (peer) => ListTile(
                      title: Text(peer.alias),
                      subtitle: Text(peer.fingerprint, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: TextButton(onPressed: () => action(() => service.revoke(peer.fingerprint)), child: Text(t.chat.revoke)),
                    ),
                  ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: Text(t.chat.clearAll),
                onPressed: () async {
                  if (await confirmClearChat(context)) await action(() => service.clear());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
