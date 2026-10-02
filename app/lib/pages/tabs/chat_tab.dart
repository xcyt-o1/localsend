import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/chat/chat_database.dart';
import 'package:localsend_app/chat/chat_provider.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/chat_page.dart';
import 'package:localsend_app/pages/chat_settings_page.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class ChatTab extends StatelessWidget {
  const ChatTab();

  @override
  Widget build(BuildContext context) {
    final chat = context.watch(chatProvider);
    final devices = context.watch(nearbyDevicesProvider).devices;
    final https = context.watch(settingsProvider.select((s) => s.https));
    final conversations = chat.peers.where((p) => p.authorized || p.lastText != null).toList();
    final nearby = chat.peers
        .where((p) => !p.authorized && p.lastText == null && devices.containsKey(p.fingerprint) && chat.supported[p.fingerprint] == true)
        .toList();
    Widget entry(ChatPeer peer) => Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(peer.authorized ? Icons.chat_bubble_outline : Icons.devices)),
        title: Text(peer.alias),
        subtitle: Text(peer.lastText ?? t.chat.authorizationRequired, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: peer.unread > 0 ? Badge(label: Text('${peer.unread}')) : const Icon(Icons.chevron_right),
        onTap: () => unawaited(context.push(() => ChatPage(peer: peer))),
      ),
    );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          children: [
            Row(
              children: [
                Expanded(child: Text(t.chat.title, style: Theme.of(context).textTheme.headlineMedium)),
                IconButton(
                  tooltip: t.chat.refresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    await context.global.dispatchAsync(StartSmartScan());
                    if (context.mounted) await context.notifier(chatProvider).probeNearby(force: true);
                  },
                ),
                IconButton(
                  tooltip: t.chat.settings,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => unawaited(context.push(() => const ChatSettingsPage())),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(t.chat.localOnly, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 24),
            if (!chat.enabled || !https)
              Card(
                child: Padding(padding: const EdgeInsets.all(16), child: Text(!https ? t.chat.httpsRequired : t.chat.disabled)),
              ),
            Text(t.chat.conversations, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (conversations.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text(t.chat.empty)),
            ...conversations.map(entry),
            const SizedBox(height: 24),
            Text(t.chat.nearby, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...nearby.map(entry),
            if (nearby.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Text(t.chat.noNearby)),
          ],
        ),
      ),
    );
  }
}
