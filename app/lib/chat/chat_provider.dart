// LocalSend Chat fork: all network requests use the existing isolate actions.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:localsend_app/chat/chat_database.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/verify_page.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/util/future_queue.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';

final chatDatabaseProvider = Provider<ChatDatabase>((ref) => throw StateError('Chat database not initialized'));
final chatProvider = NotifierProvider<ChatService, ChatState>((ref) => ChatService(ref.read(chatDatabaseProvider)));

class ChatState {
  final bool enabled;
  final List<ChatPeer> peers;
  final Map<String, bool> supported;
  final int revision;
  const ChatState({this.enabled = true, this.peers = const [], this.supported = const {}, this.revision = 0});
}

class ChatService extends Notifier<ChatState> {
  final ChatDatabase database;
  final _queues = <String, FutureQueue>{};
  final _inFlight = <String>{};
  final _probing = <String>{};
  StreamSubscription? _discovery;
  bool _authorizing = false;
  int _refreshId = 0;
  String? activePeer;
  bool Function()? isActivePeerVisible;
  ChatService(this.database);

  @override
  ChatState init() => const ChatState();

  Future<void> start() async {
    await refresh();
    _discovery = ref.stream(nearbyDevicesProvider).listen((_) => unawaited(probeNearby()));
    await probeNearby();
  }

  @override
  void dispose() {
    unawaited(_discovery?.cancel());
    super.dispose();
  }

  Future<void> refresh() async {
    final id = ++_refreshId;
    final peers = await database.peers();
    final enabled = await database.enabled();
    if (id != _refreshId) return;
    state = ChatState(enabled: enabled, peers: peers, supported: state.supported, revision: state.revision + 1);
  }

  Future<void> setEnabled(bool enabled) async {
    await database.setEnabled(enabled);
    await refresh();
  }

  Future<void> revoke(String peer) async {
    await database.setAuthorized(peer, false);
    await refresh();
  }

  Future<void> clear({String? peer}) async {
    await database.clear(peer: peer);
    await refresh();
  }

  Future<void> markRead(String peer) async {
    await database.markRead(peer);
    await refresh();
  }

  Future<Map<String, dynamic>> _request(String fingerprint, String ip, int port, String operation, [Map<String, dynamic>? payload]) async {
    final response = await ref
        .redux(parentIsolateProvider)
        .dispatchTakeResult(
          IsolateChatRequestAction(
            ip: ip,
            port: port,
            fingerprint: fingerprint,
            operation: operation,
            body: jsonEncode(payload ?? {}),
          ),
        );
    return jsonDecode(response) as Map<String, dynamic>;
  }

  Future<void> probeNearby({bool force = false}) async {
    if (!ref.read(settingsProvider).https) return;
    final devices = ref.read(nearbyDevicesProvider).devices.values.where((d) => d.https && d.ip != null).toList();
    await Future.wait(
      devices.map((device) async {
        final key = '${device.fingerprint}:${device.ip}:${device.port}';
        if (_probing.contains(key)) return;
        if (!force && state.supported.containsKey(device.fingerprint)) {
          final stored = state.peers.where((p) => p.fingerprint == device.fingerprint).firstOrNull;
          if (state.supported[device.fingerprint] == true &&
              (stored?.alias != device.alias || stored?.ip != device.ip || stored?.port != device.port)) {
            await database.upsertPeer(device.fingerprint, device.alias, device.ip!, device.port);
            await refresh();
          }
          return;
        }
        _probing.add(key);
        try {
          final info = await _request(device.fingerprint, device.ip!, device.port, 'info');
          final supported = info['version'] == 1;
          state = ChatState(
            enabled: state.enabled,
            peers: state.peers,
            supported: {...state.supported, device.fingerprint: supported},
            revision: state.revision + 1,
          );
          if (supported) {
            await database.upsertPeer(device.fingerprint, device.alias, device.ip!, device.port);
            await refresh();
          }
        } catch (error) {
          // Only a 404 proves lack of support; a timeout can be temporary.
          if (error.toString().contains('chat:404')) {
            state = ChatState(
              enabled: state.enabled,
              peers: state.peers,
              supported: {...state.supported, device.fingerprint: false},
              revision: state.revision + 1,
            );
          }
        } finally {
          _probing.remove(key);
        }
      }),
    );
  }

  Future<void> authorize(ChatPeer peer) async {
    _checkChat();
    final device = ref.read(nearbyDevicesProvider).devices[peer.fingerprint];
    if (device != null && !device.https) throw StateError(t.chat.httpsRequired);
    final ip = device?.ip ?? peer.ip;
    final port = device?.port ?? peer.port;
    try {
      final settings = ref.read(settingsProvider);
      await _request(peer.fingerprint, ip, port, 'authorize', {'alias': settings.alias, 'port': settings.port});
      await database.upsertPeer(peer.fingerprint, device?.alias ?? peer.alias, ip, port);
      await database.setAuthorized(peer.fingerprint, true);
      await refresh();
    } catch (error) {
      if (error.toString().contains('chat:404')) throw StateError(t.chat.unsupported);
      if (error.toString().contains('chat:403')) throw StateError(t.chat.authorizationDeclined);
      rethrow;
    }
  }

  Future<ChatPeer> peerForDevice(Device device) async {
    _checkChat();
    if (!device.https) throw StateError(t.chat.httpsRequired);
    if (device.ip == null) throw StateError(t.chat.actionFailed);
    try {
      final info = await _request(device.fingerprint, device.ip!, device.port, 'info');
      if (info['version'] != 1) throw StateError(t.chat.unsupported);
      await database.upsertPeer(device.fingerprint, device.alias, device.ip!, device.port);
      await refresh();
      return state.peers.firstWhere((peer) => peer.fingerprint == device.fingerprint);
    } catch (error) {
      if (error.toString().contains('chat:404')) throw StateError(t.chat.unsupported);
      rethrow;
    }
  }

  void _checkChat() {
    if (!state.enabled) throw StateError(t.chat.disabled);
    if (!ref.read(settingsProvider).https) throw StateError(t.chat.httpsRequired);
  }

  Future<void> send(ChatPeer peer, String text) async {
    _checkChat();
    if (text.trim().isEmpty) return;
    if (utf8.encode(text).length > 32768) throw StateError(t.chat.tooLong);
    if (!await database.authorized(peer.fingerprint)) throw StateError(t.chat.authorizationRequired);
    final id = const Uuid().v4();
    final sentAt = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch, isUtc: true);
    await database.addOutgoing(peer.fingerprint, id, text, sentAt);
    await refresh();
    _enqueue(peer, id, text, sentAt);
  }

  Future<void> retry(ChatPeer peer, ChatMessage message) async {
    _checkChat();
    if (!message.outgoing || message.status != 'unconfirmed' || !_inFlight.add(message.id)) return;
    try {
      if (!await database.authorized(peer.fingerprint)) throw StateError(t.chat.authorizationRequired);
      await database.updateStatus(peer.fingerprint, message.id, 'sending');
      await refresh();
      _enqueue(peer, message.id, message.text, message.sentAt);
    } catch (_) {
      _inFlight.remove(message.id);
      rethrow;
    }
  }

  void _enqueue(ChatPeer peer, String id, String text, DateTime sentAt) {
    _inFlight.add(id);
    (_queues[peer.fingerprint] ??= FutureQueue()).add(() async {
      try {
        _checkChat();
        if (!await database.authorized(peer.fingerprint)) throw const ChatStorageException(403);
        final device = ref.read(nearbyDevicesProvider).devices[peer.fingerprint];
        if (device != null && !device.https) throw const ChatStorageException(403);
        final response = await _request(peer.fingerprint, device?.ip ?? peer.ip, device?.port ?? peer.port, 'messages', {
          'id': id,
          'text': text,
          'sentAtUtc': sentAt.toUtc().toIso8601String(),
        });
        if (response['id'] != id) throw const FormatException('Invalid acknowledgement');
        await database.updateStatus(peer.fingerprint, id, 'delivered', receivedAt: DateTime.parse(response['receivedAtUtc'] as String));
      } catch (_) {
        await database.updateStatus(peer.fingerprint, id, 'unconfirmed');
      } finally {
        _inFlight.remove(id);
        await refresh();
      }
    });
  }

  Future<void> onRequest(HttpServerChatRequestEvent event) async {
    var status = 503;
    Map<String, dynamic> reply = {};
    try {
      if (event.operation == 'info') {
        reply = {'version': 1, 'enabled': await database.enabled(), 'authorized': await database.authorized(event.fingerprint)};
        status = 200;
      } else if (!await database.enabled()) {
        status = 403;
      } else if (event.operation == 'authorize') {
        status = await _onAuthorize(event);
      } else if (event.operation == 'messages') {
        final body = jsonDecode(event.body) as Map<String, dynamic>;
        final receivedAt = await database.receive(
          event.fingerprint,
          body['id'] as String,
          body['text'] as String,
          DateTime.parse(body['sentAtUtc'] as String),
          read:
              activePeer == event.fingerprint &&
              (isActivePeerVisible?.call() ?? false) &&
              WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        );
        reply = {'id': body['id'], 'receivedAtUtc': receivedAt.toIso8601String()};
        status = 200;
        await refresh();
      } else {
        status = 404;
      }
    } on ChatStorageException catch (error) {
      status = error.status;
    } on FormatException {
      status = 400;
    } catch (_) {
      status = 503;
    } finally {
      ref.redux(parentIsolateProvider).dispatch(IsolateChatReplyAction(event.requestId, status, jsonEncode(reply)));
    }
  }

  Future<int> _onAuthorize(HttpServerChatRequestEvent event) async {
    final body = jsonDecode(event.body) as Map<String, dynamic>;
    final alias = body['alias'];
    final port = body['port'];
    if (alias is! String || alias.trim().isEmpty || alias.length > 128 || port is! int || port < 1 || port > 65535) return 400;
    if (event.fingerprint == ref.read(securityProvider).certificateHash) return 403;
    if (await database.authorized(event.fingerprint)) {
      await database.upsertPeer(event.fingerprint, alias, event.ip, port);
      await refresh();
      return 200;
    }
    if (_authorizing) return 429;
    _authorizing = true;
    Timer? timer;
    try {
      final context = Routerino.context;
      if (!context.mounted) return 503;
      final fingerprint = CombinedFingerprint.load(context, event.fingerprint);
      final navigator = Navigator.of(context, rootNavigator: true);
      late final DialogRoute<bool> route;
      route = DialogRoute<bool>(
        context: context,
        builder: (dialogContext) {
          timer ??= Timer(const Duration(seconds: 55), () {
            if (route.isActive) navigator.removeRoute(route, false);
          });
          return AlertDialog(
            title: Text(t.chat.authorizationTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$alias\n${event.ip}\n\n${t.chat.authorizationNotice}'),
                  const SizedBox(height: 16),
                  Wrap(
                    children: fingerprint.icons.map((icon) => Padding(padding: const EdgeInsets.all(4), child: Icon(icon))).toList(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(t.general.decline)),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(t.general.accept)),
            ],
          );
        },
      );
      final accepted = await navigator.push(route);
      if (accepted != true || !await database.enabled()) return 403;
      await database.transaction(() async {
        await database.upsertPeer(event.fingerprint, alias, event.ip, port);
        await database.setAuthorized(event.fingerprint, true);
      });
      await refresh();
      return 200;
    } finally {
      timer?.cancel();
      _authorizing = false;
    }
  }
}
