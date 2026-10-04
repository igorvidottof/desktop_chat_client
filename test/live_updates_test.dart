import 'dart:async';

import 'package:desktop_chat_client/conversation_list.dart';
import 'package:desktop_chat_client/conversation_screen.dart';
import 'package:desktop_chat_client/matrix_updates.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const room = ConversationSummary(
  id: '!room:example.org',
  displayName: 'Test room',
);
MessageSummary message(String id, int time, {bool own = false}) =>
    MessageSummary(
      id: id,
      senderId: own ? '@me:example.org' : '@other:example.org',
      body: id,
      timestampMs: time,
      isOwn: own,
    );
MatrixUpdate update({
  MatrixUpdateKind kind = MatrixUpdateKind.message,
  String? roomId = '!room:example.org',
  MessageSummary? message,
  MatrixSyncStatus status = MatrixSyncStatus.connected,
  String id = '1',
  int sequence = 1,
}) => MatrixUpdate(
  subscriptionId: id,
  sequence: sequence,
  kind: kind,
  conversationId: roomId,
  message: message,
  status: status,
);

class FakeSource implements MatrixUpdateSource {
  final controller = StreamController<MatrixUpdate>.broadcast(sync: true);
  bool disposed = false;
  @override
  Stream<MatrixUpdate> get updates => controller.stream;
  @override
  Future<void> dispose() async {
    disposed = true;
    await controller.close();
  }
}

Widget screen(
  Stream<MatrixUpdate> updates,
  ValueNotifier<bool> active, {
  MessageHistoryLoader? load,
  TextMessageSender? send,
}) => MaterialApp(
  home: ConversationScreen(
    conversation: room,
    sessionActive: active,
    updates: updates,
    load: load ?? ({required conversationId}) async => [message('initial', 10)],
    send:
        send ??
        ({required conversationId, required body}) async =>
            const SendMessageResult(eventId: 'own'),
  ),
);

void main() {
  test(
    'merge uses event IDs, preserves history order and bounds recent messages',
    () {
      final history = [message('a', 30), message('b', 10)];
      expect(
        mergeMessages(history, [
          message('a', 30),
          message('c', 40),
        ]).map((m) => m.id),
        ['a', 'b', 'c'],
      );
      expect(
        mergeMessages(
          [message('a', 10), message('c', 30)],
          [message('b', 20)],
        ).map((m) => m.id),
        ['a', 'b', 'c'],
      );
      expect(
        mergeMessages([], List.generate(100, (i) => message('$i', i))).length,
        50,
      );
    },
  );

  testWidgets('live matching-room messages appear once in timestamp position', (
    tester,
  ) async {
    final source = FakeSource();
    final active = ValueNotifier(true);
    await tester.pumpWidget(screen(source.updates, active));
    await tester.pumpAndSettle();
    source.controller.add(update(message: message('later', 30)));
    source.controller.add(update(message: message('middle', 20)));
    source.controller.add(update(message: message('later', 30)));
    source.controller.add(
      update(roomId: '!other:example.org', message: message('other', 40)),
    );
    source.controller.add(update(message: null));
    await tester.pump();
    expect(find.text('later'), findsOneWidget);
    expect(find.text('other'), findsNothing);
    expect(
      tester.getTopLeft(find.text('initial')).dy,
      lessThan(tester.getTopLeft(find.text('middle')).dy),
    );
    expect(
      tester.getTopLeft(find.text('middle')).dy,
      lessThan(tester.getTopLeft(find.text('later')).dy),
    );
    await tester.pumpWidget(const SizedBox());
    expect(source.controller.hasListener, isFalse);
    source.controller.add(update(message: message('late', 50)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await source.dispose();
    active.dispose();
  });

  testWidgets(
    'history completion retains incoming events and ignores duplicates',
    (tester) async {
      final source = FakeSource();
      final active = ValueNotifier(true);
      final pending = Completer<List<MessageSummary>>();
      await tester.pumpWidget(
        screen(
          source.updates,
          active,
          load: ({required conversationId}) => pending.future,
        ),
      );
      source.controller.add(update(message: message('live', 20)));
      pending.complete([message('initial', 10), message('live', 20)]);
      await tester.pumpAndSettle();
      expect(find.text('live'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await source.dispose();
      active.dispose();
    },
  );

  testWidgets('send refresh and later sync render own event once', (
    tester,
  ) async {
    final source = FakeSource();
    final active = ValueNotifier(true);
    var loads = 0;
    await tester.pumpWidget(
      screen(
        source.updates,
        active,
        load: ({required conversationId}) async {
          loads++;
          return [
            message('initial', 10),
            if (loads > 1) message('own', 20, own: true),
          ];
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sent body');
    await tester.pump();
    await tester.tap(find.text('Enviar'));
    await tester.pumpAndSettle();
    source.controller.add(update(message: message('own', 20, own: true)));
    await tester.pump();
    expect(find.text('own'), findsOneWidget);
    expect(find.text('Mensagem enviada.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await source.dispose();
    active.dispose();
  });

  testWidgets(
    'transient sync failure preserves history; logout rejects old updates',
    (tester) async {
      final source = FakeSource();
      final active = ValueNotifier(true);
      await tester.pumpWidget(screen(source.updates, active));
      await tester.pumpAndSettle();
      source.controller.add(
        update(
          kind: MatrixUpdateKind.status,
          status: MatrixSyncStatus.reconnecting,
        ),
      );
      await tester.pump();
      expect(find.text('initial'), findsOneWidget);
      expect(find.textContaining('Reconectando'), findsOneWidget);
      active.value = false;
      source.controller.add(update(message: message('old account', 40)));
      await tester.pumpAndSettle();
      expect(find.text('old account'), findsNothing);
      expect(find.text('initial'), findsNothing);
      expect(source.controller.hasListener, isFalse);
      await tester.pumpWidget(const SizedBox());
      await source.dispose();
      active.dispose();
      final next = FakeSource();
      final newActive = ValueNotifier(true);
      await tester.pumpWidget(screen(next.updates, newActive));
      await tester.pumpAndSettle();
      next.controller.add(update(message: message('new account', 50)));
      await tester.pump();
      expect(find.text('new account'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await next.dispose();
      newActive.dispose();
    },
  );

  testWidgets('encrypted history stays explicitly unsupported on live input', (
    tester,
  ) async {
    final source = FakeSource();
    final active = ValueNotifier(true);
    await tester.pumpWidget(
      screen(
        source.updates,
        active,
        load:
            ({required conversationId}) async =>
                throw MessageHistoryError.encryptionUnsupported,
      ),
    );
    await tester.pumpAndSettle();
    source.controller.add(update(message: message('ignored', 30)));
    await tester.pump();
    expect(find.text('ignored'), findsNothing);
    expect(
      find.text(
        messageHistoryErrorMessage(MessageHistoryError.encryptionUnsupported),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await source.dispose();
    active.dispose();
  });

  testWidgets(
    'list refreshes metadata once while messages never reload it; screens share source',
    (tester) async {
      final source = FakeSource();
      var loads = 0;
      var factories = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationList(
              updates: () {
                factories++;
                return source;
              },
              load: () async {
                loads++;
                return [
                  ConversationSummary(
                    id: room.id,
                    displayName: loads == 1 ? 'Original' : 'Renamed',
                  ),
                ];
              },
              loadHistory: ({required conversationId}) async => [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      source.controller.add(update(message: message('unrelated', 20)));
      await tester.pump();
      expect(loads, 1);
      source.controller.add(
        update(kind: MatrixUpdateKind.conversationsChanged, roomId: null),
      );
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(find.text('Renamed'), findsOneWidget);
      await tester.tap(find.text('Renamed'));
      await tester.pumpAndSettle();
      source.controller.add(update(message: message('visible', 20)));
      await tester.pump();
      expect(find.text('visible'), findsOneWidget);
      expect(loads, 2);
      expect(factories, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(source.disposed, isTrue);
    },
  );

  test(
    'native boundary broadcasts, acknowledges after delivery and closes on disposal',
    () async {
      final native = StreamController<MatrixUpdate>();
      final received = <String>[];
      final acks = <int>[];
      var opens = 0;
      var closes = 0;
      final source = NativeMatrixUpdateSource(
        open: () async {
          opens++;
          return '1';
        },
        listen: ({required subscriptionId}) => native.stream,
        acknowledge: ({required subscriptionId, required sequence}) async {
          expect(received.length, 2);
          acks.add(sequence);
        },
        close: ({required subscriptionId}) async {
          closes++;
        },
      );
      final a = source.updates.listen((_) => received.add('list'));
      final b = source.updates.listen((_) => received.add('screen'));
      await Future<void>.delayed(Duration.zero);
      native.add(update(sequence: 7));
      await Future<void>.delayed(Duration.zero);
      expect(received, ['list', 'screen']);
      expect(acks, [7]);
      expect(opens, 1);
      await a.cancel();
      await b.cancel();
      await source.dispose();
      expect(closes, 1);
      expect(native.hasListener, isFalse);
      await native.close();
    },
  );

  test(
    'dispose during registration closes late subscription; reattachment never requests a sync start',
    () async {
      final pending = Completer<String>();
      final closed = <String>[];
      final source = NativeMatrixUpdateSource(
        open: () => pending.future,
        close: ({required subscriptionId}) async => closed.add(subscriptionId),
      );
      await source.dispose();
      pending.complete('late');
      await Future<void>.delayed(Duration.zero);
      expect(closed, ['late']);
      final native = StreamController<MatrixUpdate>();
      var opens = 0;
      final fresh = NativeMatrixUpdateSource(
        open: () async {
          opens++;
          return '$opens';
        },
        listen:
            ({required subscriptionId}) =>
                opens == 1 ? native.stream : const Stream.empty(),
        close: ({required subscriptionId}) async {},
      );
      await Future<void>.delayed(Duration.zero);
      // Disposal mimics the old Dart layer. A new source can attach independently.
      await fresh.dispose();
      expect(opens, 1);
      await native.close();
    },
  );
}
