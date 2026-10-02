import 'dart:io';

import 'package:drift/native.dart';
import 'package:localsend_app/chat/chat_database.dart';
import 'package:test/test.dart';

void main() {
  late ChatDatabase database;
  final sentAt = DateTime.utc(2026, 10, 2, 12, 34, 56);

  setUp(() async {
    database = ChatDatabase(NativeDatabase.memory());
    await database.initialize();
    await database.upsertPeer('peer', 'Phone', '192.168.1.2', 53318);
  });
  tearDown(() async => database.close());

  test('rejects untrusted devices and persists nothing', () async {
    await expectLater(
      database.receive('peer', 'id', 'hello', sentAt, read: false),
      throwsA(isA<ChatStorageException>()),
    );
    expect(await database.messages('peer'), isEmpty);
  });

  test(
    'acknowledgement retry deduplicates and keeps original receive time',
    () async {
      await database.setAuthorized('peer', true);
      final first = await database.receive(
        'peer',
        'id',
        '你好 👋\nhello',
        sentAt,
        read: false,
      );
      final retry = await database.receive(
        'peer',
        'id',
        '你好 👋\nhello',
        sentAt,
        read: false,
      );
      expect(retry, first);
      expect(await database.messages('peer'), hasLength(1));
      expect((await database.peers()).single.unread, 1);
      await expectLater(
        database.receive('peer', 'id', 'different', sentAt, read: false),
        throwsA(isA<ChatStorageException>()),
      );
      await database.markRead('peer');
      expect((await database.peers()).single.unread, 0);
    },
  );

  test(
    'retains more than 30 messages and paginates by local insertion order',
    () async {
      for (var i = 0; i < 125; i++) {
        await database.addOutgoing(
          'peer',
          '$i',
          'message $i',
          sentAt.subtract(Duration(minutes: i)),
        );
      }
      final latest = await database.messages('peer');
      final older = await database.messages(
        'peer',
        before: latest.first.sequence,
      );
      final oldest = await database.messages(
        'peer',
        before: older.first.sequence,
      );
      expect(latest, hasLength(50));
      expect(older, hasLength(50));
      expect(oldest, hasLength(25));
      expect(
        [...oldest, ...older, ...latest].map((m) => m.id),
        List.generate(125, (i) => '$i'),
      );
    },
  );

  test(
    'rename and address update preserve trust; revoke rejects further messages',
    () async {
      await database.setAuthorized('peer', true);
      await database.upsertPeer('peer', 'Renamed phone', '192.168.1.3', 53318);
      expect(await database.authorized('peer'), isTrue);
      await database.receive('peer', 'id', 'hello', sentAt, read: false, ip: '192.168.1.4');
      expect((await database.peers()).single.ip, '192.168.1.4');
      expect((await database.peers()).single.alias, 'Renamed phone');
      await database.setAuthorized('peer', false);
      await expectLater(
        database.receive('peer', 'new', 'hello', sentAt, read: false, ip: '192.168.1.5'),
        throwsA(isA<ChatStorageException>()),
      );
      expect(await database.messages('peer'), hasLength(1));
      expect((await database.peers()).single.ip, '192.168.1.4');
      await database.clear(peer: 'peer');
      expect(await database.authorized('peer'), isFalse);
    },
  );

  test(
    'chat switch rejects incoming messages and clear keeps authorization',
    () async {
      await database.setAuthorized('peer', true);
      await database.receive('peer', 'id', 'hello', sentAt, read: false);
      await database.setEnabled(false);
      await expectLater(
        database.receive('peer', 'new', 'hello', sentAt, read: false),
        throwsA(isA<ChatStorageException>()),
      );
      await database.clear();
      expect(await database.authorized('peer'), isTrue);
    },
  );

  test(
    'restart restores records and marks interrupted sends unconfirmed',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'localsend-chat-test-',
      );
      final file = File('${directory.path}/chat.sqlite');
      final first = ChatDatabase(NativeDatabase(file));
      try {
        await first.initialize();
        await first.upsertPeer('peer', 'Phone', '192.168.1.2', 53318);
        await first.setAuthorized('peer', true);
        await first.addOutgoing('peer', 'id', 'persist me', sentAt);
        await first.close();
        final second = ChatDatabase(NativeDatabase(file));
        try {
          await second.initialize();
          final message = (await second.messages('peer')).single;
          expect(message.status, 'unconfirmed');
          expect(message.sentAt, sentAt);
          expect(message.text, 'persist me');
          expect(await second.authorized('peer'), isTrue);
        } finally {
          await second.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
