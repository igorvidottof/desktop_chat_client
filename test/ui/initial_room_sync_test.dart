import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart' as native;
import 'package:desktop_chat_client/ui/rooms/widgets/rooms_view.dart';
import '../support/repository_fakes.dart';

class NativeTransportFixture {
  final events = StreamController<native.MatrixUpdate>.broadcast(sync: true);
  late final NativeMatrixUpdateSource source;
  int sequence = 0;
  int closes = 0;
  NativeTransportFixture() {
    source = NativeMatrixUpdateSource(
      open: () async => 'fixture',
      listen: ({required subscriptionId}) => events.stream,
      acknowledge: ({required subscriptionId, required sequence}) async {},
      close: ({required subscriptionId}) async {
        closes++;
      },
    );
  }
  void emit(
    native.MatrixUpdateKind kind,
    native.MatrixSyncStatus status, {
    String? roomId,
  }) {
    events.add(
      native.MatrixUpdate(
        subscriptionId: 'fixture',
        sequence: ++sequence,
        kind: kind,
        conversationId: roomId,
        message: null,
        status: status,
      ),
    );
  }
}

void main() {
  for (final emptyResult in [false, true]) {
    testWidgets(
      'Re-login aguarda sync inicial antes de confirmar lista vazia ($emptyResult)',
      (tester) async {
        final transports = <NativeTransportFixture>[];
        final pendingRooms = Completer<List<native.ConversationSummary>>();
        var loads = 0;
        final auth =
            FakeAuthRepository()
              ..initializeAction =
                  () async => const SessionState(account: fixtureAccount);
        final bridge = MatrixBridgeService(
          openUpdates: () {
            final fixture = NativeTransportFixture();
            transports.add(fixture);
            return fixture.source;
          },
          rooms: () {
            loads++;
            if (transports.length == 1) {
              return Future.value(const [
                native.ConversationSummary(
                  id: 'old',
                  displayName: 'Sala anterior',
                ),
              ]);
            }
            return transports.last.source.initialRoomSyncPending
                ? Future.value([])
                : pendingRooms.future;
          },
        );
        await tester.pumpWidget(ChatApp(bridge: bridge, authRepository: auth));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          for (final transport in transports) {
            await transport.events.close();
          }
        });
        await tester.pumpAndSettle();
        final previous =
            tester.widget<RoomsView>(find.byType(RoomsView)).viewModel;
        expect(find.text('Sala anterior'), findsOneWidget);
        await tester.tap(find.text('Logout'));
        await tester.pumpAndSettle();
        expect(previous.isClosed, isTrue);
        expect(transports.single.closes, 1);
        expect(transports.single.events.hasListener, isFalse);
        await tester.tap(find.text('Entrar'));
        await tester.pump();
        final current =
            tester.widget<RoomsView>(find.byType(RoomsView)).viewModel;
        expect(current, isNot(same(previous)));
        expect(current.state.rooms, isEmpty);
        expect(loads, 2);
        expect(current.state.refreshing, isFalse);
        expect(find.text('Carregando conversas…'), findsOneWidget);
        expect(find.textContaining('Nenhuma conversa'), findsNothing);
        final transport = transports.last;
        transport.emit(
          native.MatrixUpdateKind.resyncRequired,
          native.MatrixSyncStatus.connecting,
        );
        await tester.pump();
        expect(loads, 3);
        expect(current.state.refreshing, isFalse);
        expect(find.text('Carregando conversas…'), findsOneWidget);
        expect(find.textContaining('Nenhuma conversa'), findsNothing);
        transport.emit(
          native.MatrixUpdateKind.status,
          native.MatrixSyncStatus.connected,
        );
        await tester.pump();
        expect(loads, 3);
        expect(transport.source.initialRoomSyncPending, isTrue);
        expect(find.text('Carregando conversas…'), findsOneWidget);
        transport.emit(
          native.MatrixUpdateKind.conversationsChanged,
          native.MatrixSyncStatus.connected,
        );
        await tester.pump();
        expect(loads, 4);
        expect(transport.source.initialRoomSyncPending, isFalse);
        expect(find.text('Carregando conversas…'), findsOneWidget);
        pendingRooms.complete(
          emptyResult
              ? []
              : const [
                native.ConversationSummary(id: 'new', displayName: 'Nova sala'),
              ],
        );
        await tester.pumpAndSettle();
        expect(find.text('Carregando conversas…'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Sala anterior'), findsNothing);
        expect(
          find.text('Nova sala'),
          emptyResult ? findsNothing : findsOneWidget,
        );
        expect(
          find.textContaining('Nenhuma conversa'),
          emptyResult ? findsOneWidget : findsNothing,
        );
        expect(loads, 4);
        expect(transports, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Restauração confirma vazio com snapshot nativo já sincronizado',
    (tester) async {
      final transport = NativeTransportFixture();
      var loads = 0;
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      await tester.pumpWidget(
        ChatApp(
          authRepository: auth,
          bridge: MatrixBridgeService(
            openUpdates: () => transport.source,
            rooms: () async {
              loads++;
              return [];
            },
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await transport.events.close();
      });
      await tester.pump();
      expect(find.text('Carregando conversas…'), findsOneWidget);
      transport.emit(
        native.MatrixUpdateKind.resyncRequired,
        native.MatrixSyncStatus.connected,
      );
      await tester.pumpAndSettle();
      expect(transport.source.initialRoomSyncPending, isFalse);
      expect(find.text('Carregando conversas…'), findsNothing);
      expect(find.textContaining('Nenhuma conversa'), findsOneWidget);
      expect(loads, 2);
    },
  );

  for (final status in [
    native.MatrixSyncStatus.reconnecting,
    native.MatrixSyncStatus.authenticationRequired,
  ]) {
    testWidgets(
      'Falha antes do sync inicial oferece ação sem spinner preso ($status)',
      (tester) async {
        final transport = NativeTransportFixture();
        final auth =
            FakeAuthRepository()
              ..initializeAction =
                  () async => const SessionState(account: fixtureAccount);
        await tester.pumpWidget(
          ChatApp(
            authRepository: auth,
            bridge: MatrixBridgeService(
              openUpdates: () => transport.source,
              rooms: () async => [],
            ),
          ),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await transport.events.close();
        });
        await tester.pump();
        transport.emit(native.MatrixUpdateKind.status, status);
        await tester.pumpAndSettle();
        expect(find.text('Carregando conversas…'), findsNothing);
        expect(find.textContaining('Nenhuma conversa'), findsNothing);
        expect(find.text('Tentar novamente'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        if (status == native.MatrixSyncStatus.reconnecting) {
          expect(find.textContaining('Verifique a conexão'), findsOneWidget);
        } else {
          expect(
            find.textContaining('A sessão não está autenticada'),
            findsOneWidget,
          );
        }
        await tester.tap(find.text('Tentar novamente'));
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        transport.emit(
          native.MatrixUpdateKind.status,
          native.MatrixSyncStatus.connected,
        );
        transport.emit(
          native.MatrixUpdateKind.conversationsChanged,
          native.MatrixSyncStatus.connected,
        );
        await tester.pumpAndSettle();
        expect(find.text('Tentar novamente'), findsNothing);
        expect(find.textContaining('Nenhuma conversa'), findsOneWidget);
      },
    );
  }
}
