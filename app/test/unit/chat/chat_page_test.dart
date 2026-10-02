import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:localsend_app/chat/chat_database.dart';
import 'package:localsend_app/chat/chat_provider.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/chat_page.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:mockito/mockito.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../../mocks.mocks.dart';

class _Chat extends ChatService {
  final ChatPeer peer;
  final sent = <String>[];
  _Chat(super.database, this.peer);
  @override
  ChatState init() => ChatState(peers: [peer]);
  @override
  Future<void> send(ChatPeer peer, String text) async => sent.add(text);
}

void main() {
  testWidgets('Windows Enter sends; Shift+Enter and IME composition preserve the draft', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    await initializeDateFormatting();
    final database = ChatDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    await database.initialize();
    await database.upsertPeer('peer', 'Phone', '192.168.1.2', 53318);
    await database.setAuthorized('peer', true);
    final peer = (await database.peers()).single;
    final service = _Chat(database, peer);
    final persistence = MockPersistenceService();
    when(persistence.isHttps()).thenReturn(true);
    final container = RefenaContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(database),
        chatProvider.overrideWithNotifier((_) => service),
        settingsProvider.overrideWithNotifier((_) => SettingsService(persistence)),
      ],
    );
    addTearDown(container.disposeContainer);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(home: ChatPage(peer: peer)),
      ),
    );
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    await tester.enterText(input, '你好 👋');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(service.sent, ['你好 👋']);
    final controller = tester.widget<TextField>(input).controller!;
    expect(controller.text, isEmpty);

    await tester.enterText(input, 'first line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(service.sent, hasLength(1));
    expect(controller.text, contains('\n'));

    controller.value = const TextEditingValue(text: '拼音', selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(service.sent, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
