@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/crypto.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/server.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';

void main() {
  test('native bridge correlates concurrent chat replies and transports certificate identity', () async {
    final name = Platform.isWindows
        ? 'rust_lib_localsend_app.dll'
        : Platform.isMacOS
        ? 'librust_lib_localsend_app.dylib'
        : 'librust_lib_localsend_app.so';
    final library = File(Platform.environment['LOCALSEND_CHAT_TEST_LIBRARY'] ?? '${Directory.current.path}/../../target/debug/$name');
    if (!library.existsSync()) {
      markTestSkipped('Build the native bridge with cargo build -p rust_lib_localsend_app');
      return;
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path)).timeout(const Duration(seconds: 10));
    final receiver = await generateSecurityContext();
    final sender = await generateSecurityContext();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final server = await startServer(
      port: port,
      tls: TlsConfig(cert: receiver.certificate, privateKey: receiver.privateKey),
      alias: 'Receiver',
      version: '2.2',
      deviceModel: 'Test',
      deviceType: null,
      fingerprint: receiver.certificateHash,
      pin: null,
      verifyChecksums: true,
      web: const WebParams(
        mode: WebMode.disabled(),
        i18N: WebI18n(
          waiting: '',
          enterPin: '',
          invalidPin: '',
          tooManyAttempts: '',
          rejected: '',
          uploadRejected: '',
          busy: '',
          files: '',
          fileName: '',
          size: '',
          dropHint: '',
        ),
        pages: WebPages(downloadHtml: null, uploadHtml: null, error403Html: null),
      ),
      showToken: 'test',
    );
    final pending = <RsServerEvent_ChatRequest>[];
    final bothArrived = Completer<void>();
    final subscription = server.listen().listen((event) {
      if (event is RsServerEvent_ChatRequest) {
        pending.add(event);
        if (pending.length == 2) bothArrived.complete();
      }
    });
    try {
      final client = createClient(
        version: LsHttpClientVersion.v2,
        privateKey: sender.privateKey,
        cert: sender.certificate,
        expectedFingerprint: receiver.certificateHash,
        timeoutMs: 15000,
      );
      final info = client.chatRequest(ip: '127.0.0.1', port: port, operation: 'info', body: '{}');
      final authorize = client.chatRequest(ip: '127.0.0.1', port: port, operation: 'authorize', body: '{"alias":"Phone","port":53318}');
      // Register the error listener before deliberately rejecting this request.
      final declined = expectLater(authorize, throwsA(isA<RsHttpClientError_StatusCode>()));
      await bothArrived.future.timeout(const Duration(seconds: 10));
      expect(pending.map((e) => e.requestId).toSet(), hasLength(2));
      expect(pending.every((e) => e.fingerprint == sender.certificateHash), isTrue);
      for (final event in pending.reversed) {
        await server.respondChat(
          requestId: event.requestId,
          status: event.operation == 'info' ? 200 : 403,
          body: jsonEncode({'operation': event.operation}),
        );
      }
      expect(jsonDecode(await info)['operation'], 'info');
      await declined;
      // A late or duplicate reply must not consume another request's responder.
      await server.respondChat(requestId: pending.first.requestId, status: 200, body: '{}');
    } finally {
      await server.stop();
      await subscription.cancel();
      RustLib.dispose();
    }
  });
}
