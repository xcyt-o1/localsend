import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:localsend_app/chat/chat_database.dart';
import 'package:localsend_app/chat/chat_provider.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/chat_settings_page.dart';
import 'package:localsend_app/pages/verify_page.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class ChatPage extends StatefulWidget {
  final ChatPeer peer;
  const ChatPage({required this.peer});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with Refena, WidgetsBindingObserver {
  final _input = TextEditingController();
  late final FocusNode _focus;
  ChatService? _service;
  Future<List<ChatMessage>>? _messages;
  int _revision = -1;
  int _limit = 50;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode(
      onKeyEvent: (_, event) {
        if (defaultTargetPlatform != TargetPlatform.windows ||
            (event is! KeyDownEvent && event is! KeyRepeatEvent) ||
            (event.logicalKey != LogicalKeyboardKey.enter && event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
            (_input.value.composing.isValid && !_input.value.composing.isCollapsed)) {
          return KeyEventResult.ignored;
        }
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        if (HardwareKeyboard.instance.isShiftPressed) {
          final value = _input.value;
          final start = value.selection.isValid ? value.selection.start : value.text.length;
          final end = value.selection.isValid ? value.selection.end : value.text.length;
          setState(
            () => _input.value = TextEditingValue(
              text: value.text.replaceRange(start, end, '\n'),
              selection: TextSelection.collapsed(offset: start + 1),
            ),
          );
          return KeyEventResult.handled;
        }
        unawaited(_send());
        return KeyEventResult.handled;
      },
    );
    WidgetsBinding.instance.addObserver(this);
    ensureRef((ref) {
      _service = ref.notifier(chatProvider);
      _service!.activePeer = widget.peer.fingerprint;
      _service!.isActivePeerVisible = () => mounted && ModalRoute.of(context)?.isCurrent == true;
      unawaited(_service!.markRead(widget.peer.fingerprint));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _service?.activePeer = widget.peer.fingerprint;
      unawaited(_service?.markRead(widget.peer.fingerprint));
    } else {
      _service?.activePeer = null;
    }
  }

  @override
  void dispose() {
    if (_service?.activePeer == widget.peer.fingerprint) _service?.activePeer = null;
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error is StateError ? error.message : t.chat.actionFailed)));
    }
  }

  Future<void> _send() async {
    if (_busy || _input.text.trim().isEmpty || _service == null) return;
    final text = _input.text;
    setState(() => _busy = true);
    await _action(() async {
      await _service!.send(widget.peer, text);
      if (mounted && _input.text == text) _input.clear();
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<List<ChatMessage>> _loadMessages(String peer) async {
    final database = context.read(chatDatabaseProvider);
    final loaded = <ChatMessage>[];
    int? before;
    for (var page = 0; page < _limit ~/ 50; page++) {
      final messages = await database.messages(peer, before: before);
      loaded.insertAll(0, messages);
      if (messages.length < 50) break;
      before = messages.first.sequence;
    }
    return loaded;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch(chatProvider);
    final peer = state.peers.where((p) => p.fingerprint == widget.peer.fingerprint).firstOrNull ?? widget.peer;
    final https = context.watch(settingsProvider.select((s) => s.https));
    final allowed = state.enabled && https && peer.authorized;
    if (_revision != state.revision) {
      _revision = state.revision;
      _messages = _loadMessages(peer.fingerprint);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(peer.alias),
        actions: [
          IconButton(
            tooltip: t.chat.verify,
            icon: const Icon(Icons.verified_user_outlined),
            onPressed: () => unawaited(
              context.push(
                () => VerifyPage(fingerprint: CombinedFingerprint.load(context, peer.fingerprint)),
              ),
            ),
          ),
          IconButton(
            tooltip: t.chat.clear,
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirmClearChat(context)) await _action(() => _service!.clear(peer: peer.fingerprint));
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              if (!allowed)
                MaterialBanner(
                  content: Text(
                    !https
                        ? t.chat.httpsRequired
                        : !state.enabled
                        ? t.chat.disabled
                        : t.chat.authorizationRequired,
                  ),
                  actions: [
                    if (https && state.enabled)
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                await _action(() => _service!.authorize(peer));
                                if (mounted) setState(() => _busy = false);
                              },
                        child: Text(t.chat.requestAuthorization),
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
              Expanded(
                child: FutureBuilder<List<ChatMessage>>(
                  future: _messages,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) return Center(child: Text(t.chat.storageError));
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    final messages = snapshot.data!.reversed.toList();
                    if (messages.isEmpty) return Center(child: Text(t.chat.startConversation));
                    return ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: messages.length + 1,
                      itemBuilder: (context, index) {
                        if (index == messages.length) {
                          if (messages.length < _limit) return const SizedBox.shrink();
                          return TextButton(
                            onPressed: () => setState(() {
                              _limit += 50;
                              _revision = -1;
                            }),
                            child: Text(t.chat.loadOlder),
                          );
                        }
                        final message = messages[index];
                        final date = DateFormat.yMd(LocaleSettings.currentLocale.languageTag).format(message.sentAt.toLocal());
                        final previousDate = index + 1 < messages.length
                            ? DateFormat.yMd(LocaleSettings.currentLocale.languageTag).format(messages[index + 1].sentAt.toLocal())
                            : null;
                        return Column(
                          children: [
                            if (date != previousDate)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                child: Text(date, style: Theme.of(context).textTheme.labelMedium),
                              ),
                            Align(
                              alignment: message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                constraints: const BoxConstraints(maxWidth: 640),
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: message.outgoing
                                      ? Theme.of(context).colorScheme.primaryContainer
                                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SelectableText(message.text),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      spacing: 8,
                                      children: [
                                        Text(DateFormat('HH:mm:ss').format(message.sentAt.toLocal()), style: Theme.of(context).textTheme.labelSmall),
                                        if (message.outgoing)
                                          Text(switch (message.status) {
                                            'delivered' => t.chat.delivered,
                                            'sending' => t.chat.sending,
                                            _ => t.chat.unconfirmed,
                                          }, style: Theme.of(context).textTheme.labelSmall),
                                        IconButton(
                                          tooltip: t.chat.copy,
                                          visualDensity: VisualDensity.compact,
                                          iconSize: 16,
                                          icon: const Icon(Icons.copy),
                                          onPressed: () => Clipboard.setData(ClipboardData(text: message.text)),
                                        ),
                                        if (message.outgoing && message.status == 'unconfirmed')
                                          TextButton(
                                            onPressed: allowed ? () => _action(() => _service!.retry(peer, message)) : null,
                                            child: Text(t.chat.retry),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          enabled: allowed,
                          minLines: 1,
                          maxLines: 5,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(hintText: t.chat.messageHint, border: const OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        tooltip: t.chat.send,
                        icon: const Icon(Icons.send),
                        onPressed: allowed && !_busy && _input.text.trim().isNotEmpty ? _send : null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
