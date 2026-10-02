// LocalSend Chat fork: persistent, device-keyed text conversations.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

class ChatStorageException implements Exception {
  final int status;
  const ChatStorageException(this.status);
}

class ChatPeer {
  final String fingerprint;
  final String alias;
  final String ip;
  final int port;
  final bool authorized;
  final String? lastText;
  final int unread;

  ChatPeer(QueryRow row)
    : fingerprint = row.read<String>('fingerprint'),
      alias = row.read<String>('alias'),
      ip = row.read<String>('ip'),
      port = row.read<int>('port'),
      authorized = row.read<int>('authorized') != 0,
      lastText = row.readNullable<String>('last_text'),
      unread = row.read<int>('unread');
}

class ChatMessage {
  final int sequence;
  final String id;
  final String peer;
  final bool outgoing;
  final String text;
  final DateTime sentAt;
  final DateTime? receivedAt;
  final String status;

  ChatMessage(QueryRow row)
    : sequence = row.read<int>('sequence'),
      id = row.read<String>('message_id'),
      peer = row.read<String>('peer'),
      outgoing = row.read<int>('outgoing') != 0,
      text = row.read<String>('text'),
      sentAt = DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('sent_at'),
        isUtc: true,
      ),
      receivedAt = _date(row.readNullable<int>('received_at')),
      status = row.read<String>('status');

  static DateTime? _date(int? time) => time == null ? null : DateTime.fromMillisecondsSinceEpoch(time, isUtc: true);
}

/// SQL schema is explicit so storage migrations do not depend on model codegen.
class ChatDatabase extends GeneratedDatabase {
  ChatDatabase(super.executor);

  static Future<ChatDatabase> open({required bool portable}) async {
    final String directory;
    if (portable) {
      directory = File(Platform.resolvedExecutable).parent.path;
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      directory = p.join(Platform.environment['APPDATA']!, 'LocalSendChat');
    } else {
      directory = (await getApplicationSupportDirectory()).path;
    }
    await Directory(directory).create(recursive: true);
    final temporaryDirectory = (await getTemporaryDirectory()).path;
    return ChatDatabase(
      NativeDatabase.createInBackground(
        File(p.join(directory, 'chat.sqlite')),
        isolateSetup: () => sqlite.sqlite3.tempDirectory = temporaryDirectory,
      ),
    );
  }

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE chat_settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL)',
      );
      await customStatement("INSERT INTO chat_settings VALUES ('enabled', 1)");
      await customStatement(
        'CREATE TABLE chat_peers (fingerprint TEXT PRIMARY KEY, alias TEXT NOT NULL, ip TEXT NOT NULL, '
        'port INTEGER NOT NULL, authorized INTEGER NOT NULL DEFAULT 0)',
      );
      await customStatement(
        'CREATE TABLE chat_messages (sequence INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL, '
        'peer TEXT NOT NULL, outgoing INTEGER NOT NULL, text TEXT NOT NULL, sent_at INTEGER NOT NULL, received_at INTEGER, '
        'status TEXT NOT NULL, is_read INTEGER NOT NULL, UNIQUE(peer, outgoing, message_id))',
      );
      await customStatement(
        'CREATE INDEX chat_messages_peer_sequence ON chat_messages(peer, sequence)',
      );
    },
  );

  Future<void> initialize() => customStatement(
    "UPDATE chat_messages SET status = 'unconfirmed' WHERE status = 'sending'",
  );

  Future<bool> enabled() async =>
      (await customSelect(
        "SELECT value FROM chat_settings WHERE key = 'enabled'",
      ).getSingle()).read<int>('value') !=
      0;

  Future<void> setEnabled(bool value) => customStatement(
    "UPDATE chat_settings SET value = ? WHERE key = 'enabled'",
    [value ? 1 : 0],
  );

  Future<void> upsertPeer(
    String fingerprint,
    String alias,
    String ip,
    int port,
  ) => customStatement(
    'INSERT INTO chat_peers(fingerprint, alias, ip, port) VALUES (?, ?, ?, ?) '
    'ON CONFLICT(fingerprint) DO UPDATE SET alias = excluded.alias, ip = excluded.ip, port = excluded.port',
    [fingerprint, alias, ip, port],
  );

  Future<void> setAuthorized(String fingerprint, bool authorized) => customStatement(
    'UPDATE chat_peers SET authorized = ? WHERE fingerprint = ?',
    [authorized ? 1 : 0, fingerprint],
  );

  Future<bool> authorized(String fingerprint) async {
    final row = await customSelect(
      'SELECT authorized FROM chat_peers WHERE fingerprint = ?',
      variables: [Variable(fingerprint)],
    ).getSingleOrNull();
    return row?.read<int>('authorized') == 1;
  }

  Future<List<ChatPeer>> peers() async => (await customSelect(
    'SELECT p.*, (SELECT text FROM chat_messages m WHERE m.peer = p.fingerprint ORDER BY sequence DESC LIMIT 1) AS last_text, '
    '(SELECT COUNT(*) FROM chat_messages m WHERE m.peer = p.fingerprint AND is_read = 0) AS unread '
    'FROM chat_peers p ORDER BY (SELECT MAX(sequence) FROM chat_messages m WHERE m.peer = p.fingerprint) DESC, p.alias',
  ).get()).map(ChatPeer.new).toList();

  Future<List<ChatMessage>> messages(
    String peer, {
    int? before,
    int limit = 50,
  }) async {
    final rows = await customSelect(
      'SELECT * FROM chat_messages WHERE peer = ? AND sequence < ? ORDER BY sequence DESC LIMIT ?',
      variables: [
        Variable(peer),
        Variable(before ?? 9223372036854775807),
        Variable(limit),
      ],
    ).get();
    return rows.reversed.map(ChatMessage.new).toList();
  }

  Future<void> addOutgoing(
    String peer,
    String id,
    String text,
    DateTime sentAt,
  ) => customStatement(
    "INSERT INTO chat_messages(message_id, peer, outgoing, text, sent_at, status, is_read) VALUES (?, ?, 1, ?, ?, 'sending', 1)",
    [id, peer, text, sentAt.toUtc().millisecondsSinceEpoch],
  );

  Future<void> updateStatus(
    String peer,
    String id,
    String status, {
    DateTime? receivedAt,
  }) => customStatement(
    'UPDATE chat_messages SET status = ?, received_at = COALESCE(?, received_at) WHERE peer = ? AND outgoing = 1 AND message_id = ?',
    [status, receivedAt?.toUtc().millisecondsSinceEpoch, peer, id],
  );

  /// The acknowledgement is issued only after this transaction commits.
  Future<DateTime> receive(
    String peer,
    String id,
    String text,
    DateTime sentAt, {
    required bool read,
    String? ip,
  }) => transaction(() async {
    if (!await enabled() || !await authorized(peer)) throw const ChatStorageException(403);
    if (ip != null) await customStatement('UPDATE chat_peers SET ip = ? WHERE fingerprint = ? AND ip != ?', [ip, peer, ip]);
    final previous = await customSelect(
      'SELECT text, sent_at, received_at FROM chat_messages WHERE peer = ? AND outgoing = 0 AND message_id = ?',
      variables: [Variable(peer), Variable(id)],
    ).getSingleOrNull();
    if (previous != null) {
      if (previous.read<String>('text') != text || previous.read<int>('sent_at') != sentAt.toUtc().millisecondsSinceEpoch) {
        throw const ChatStorageException(409);
      }
      return DateTime.fromMillisecondsSinceEpoch(
        previous.read<int>('received_at'),
        isUtc: true,
      );
    }
    final receivedAt = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch, isUtc: true);
    await customStatement(
      "INSERT INTO chat_messages(message_id, peer, outgoing, text, sent_at, received_at, status, is_read) VALUES (?, ?, 0, ?, ?, ?, 'received', ?)",
      [
        id,
        peer,
        text,
        sentAt.toUtc().millisecondsSinceEpoch,
        receivedAt.millisecondsSinceEpoch,
        read ? 1 : 0,
      ],
    );
    return receivedAt;
  });

  Future<void> markRead(String peer) => customStatement(
    'UPDATE chat_messages SET is_read = 1 WHERE peer = ?',
    [peer],
  );

  Future<void> clear({String? peer}) =>
      peer == null ? customStatement('DELETE FROM chat_messages') : customStatement('DELETE FROM chat_messages WHERE peer = ?', [peer]);
}
