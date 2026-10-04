import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:desktop_chat_client/app/app_binding.dart';
import 'package:desktop_chat_client/app/chat_app.dart';
import 'package:desktop_chat_client/data/services/matrix_bridge_service.dart';
import 'package:desktop_chat_client/data/services/native_matrix_updates.dart';
import 'package:desktop_chat_client/domain/models/models.dart';
import 'package:desktop_chat_client/ui/rooms/widgets/rooms_view.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart' as native;
import '../../support/repository_fakes.dart';

class TrackingSource implements MatrixUpdateSource {
  @override
  bool get initialRoomSyncPending => false;
  final events = StreamController<native.MatrixUpdate>.broadcast(sync: true);
  int closes = 0;
  @override
  Stream<native.MatrixUpdate> get updates => events.stream;
  @override
  Future<void> dispose() async {
    closes++;
    await events.close();
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => Get.testMode = true);
  tearDown(() async => Get.reset());

  test(
    'Binding compartilha transporte, troca conversa e recria sessão após logout',
    () async {
      final sources = <TrackingSource>[];
      var loads = 0;
      final bridge = MatrixBridgeService(
        openUpdates: () {
          final source = TrackingSource();
          sources.add(source);
          return source;
        },
        rooms: () async {
          loads++;
          return const [
            native.ConversationSummary(id: 'a', displayName: 'A'),
            native.ConversationSummary(id: 'b', displayName: 'B'),
          ];
        },
        history: ({required conversationId}) async => [],
      );
      final repository =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final binding = AppBinding(bridge: bridge, authRepository: repository)
        ..dependencies();
      addTearDown(binding.dispose);
      final auth = binding.auth;
      await settle();
      final rooms = binding.rooms!;
      expect(sources, hasLength(1));
      rooms.selectRoom(roomA);
      await settle();
      final chatA = binding.chat!;
      rooms.selectRoom(roomB);
      await settle();
      expect(chatA.isClosed, isTrue);
      expect(binding.chat!.roomId, 'b');
      expect(sources, hasLength(1));
      expect(sources.single.closes, 0);
      sources.single.events.add(
        const native.MatrixUpdate(
          subscriptionId: '',
          sequence: 0,
          kind: native.MatrixUpdateKind.conversationsChanged,
          conversationId: null,
          message: null,
          status: native.MatrixSyncStatus.connected,
        ),
      );
      await settle();
      expect(loads, 2);
      final chatB = binding.chat!;
      await auth.logout();
      expect(rooms.isClosed, isTrue);
      expect(chatB.isClosed, isTrue);
      expect(sources.single.closes, 1);
      expect(sources.single.events.hasListener, isFalse);
      expect(binding.rooms, isNull);
      expect(binding.chat, isNull);
      expect(auth.isClosed, isFalse);
      await auth.login('address', 'user', 'synthetic');
      await settle();
      expect(binding.auth, same(auth));
      expect(binding.rooms, isNot(same(rooms)));
      expect(sources, hasLength(2));
      final nextRooms = binding.rooms!;
      binding.dispose();
      expect(auth.isClosed, isTrue);
      expect(nextRooms.isClosed, isTrue);
      expect(sources.last.closes, 1);
      binding.dispose();
      expect(sources.last.closes, 1);
    },
  );

  testWidgets('Reconstruir raiz preserva auth, salas e o consumidor nativo', (
    tester,
  ) async {
    final source = TrackingSource();
    var opens = 0;
    var initializes = 0;
    final auth =
        FakeAuthRepository()
          ..initializeAction = () async {
            initializes++;
            return const SessionState(account: fixtureAccount);
          };
    final rooms = FakeRoomRepository();
    final chat = FakeChatRepository();
    final bridge = MatrixBridgeService(
      openUpdates: () {
        opens++;
        return source;
      },
    );
    Widget app() => ChatApp(
      bridge: bridge,
      authRepository: auth,
      roomRepository: rooms,
      chatRepository: chat,
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text(roomA.displayName));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(initializes, 1);
    expect(rooms.loads, 1);
    expect(chat.loads, 1);
    expect(source.closes, 0);
    await tester.pumpWidget(const SizedBox());
    expect(source.closes, 1);
    expect(rooms.events.hasListener, isFalse);
    expect(chat.events.hasListener, isFalse);
    await rooms.events.close();
    await chat.events.close();
  });

  testWidgets(
    'Re-login mostra carregamento de salas vazias e rejeita a sessão anterior',
    (tester) async {
      final sources = <TrackingSource>[];
      final oldRefresh = Completer<List<native.ConversationSummary>>();
      final initialNewRooms = Completer<List<native.ConversationSummary>>();
      final newRooms = Completer<List<native.ConversationSummary>>();
      var loads = 0;
      final auth =
          FakeAuthRepository()
            ..initializeAction =
                () async => const SessionState(account: fixtureAccount);
      final bridge = MatrixBridgeService(
        openUpdates: () {
          final source = TrackingSource();
          sources.add(source);
          return source;
        },
        rooms: () {
          loads++;
          return switch (loads) {
            1 => Future.value(const [
              native.ConversationSummary(
                id: 'old',
                displayName: 'Sala anterior',
              ),
            ]),
            2 => oldRefresh.future,
            3 => initialNewRooms.future,
            4 => newRooms.future,
            _ => throw StateError('Carregamento inesperado'),
          };
        },
      );
      void changed(TrackingSource source) => source.events.add(
        const native.MatrixUpdate(
          subscriptionId: '',
          sequence: 0,
          kind: native.MatrixUpdateKind.conversationsChanged,
          conversationId: null,
          message: null,
          status: native.MatrixSyncStatus.connected,
        ),
      );
      await tester.pumpWidget(ChatApp(bridge: bridge, authRepository: auth));
      addTearDown(() async => tester.pumpWidget(const SizedBox()));
      await tester.pumpAndSettle();
      final previous =
          tester.widget<RoomsView>(find.byType(RoomsView)).viewModel;
      expect(find.text('Sala anterior'), findsOneWidget);
      changed(sources.single);
      await tester.pump();
      expect(previous.state.refreshing, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Logout'));
      await tester.pumpAndSettle();
      expect(previous.isClosed, isTrue);
      expect(sources.single.closes, 1);
      expect(sources.single.events.hasListener, isFalse);
      expect(find.text('Entrar'), findsOneWidget);
      await tester.tap(find.text('Entrar'));
      await tester.pump();
      final current =
          tester.widget<RoomsView>(find.byType(RoomsView)).viewModel;
      expect(current, isNot(same(previous)));
      expect(current.state.loading, isTrue);
      expect(find.text('Sala anterior'), findsNothing);
      expect(find.text('Carregando conversas…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Nenhuma conversa'), findsNothing);
      initialNewRooms.complete([]);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Nenhuma conversa'), findsOneWidget);
      changed(sources.last);
      expect(current.state.refreshing, isTrue);
      expect(current.state.loading, isFalse);
      await tester.pump();
      expect(find.text('Carregando conversas…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('Nenhuma conversa'), findsNothing);
      expect(find.text('Selecione uma conversa'), findsOneWidget);
      oldRefresh.complete(const [
        native.ConversationSummary(
          id: 'stale',
          displayName: 'Resultado antigo',
        ),
      ]);
      await tester.pump();
      expect(current.state.rooms, isEmpty);
      expect(find.text('Resultado antigo'), findsNothing);
      expect(find.text('Carregando conversas…'), findsOneWidget);
      newRooms.complete(const [
        native.ConversationSummary(id: 'new', displayName: 'Nova sala'),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Carregando conversas…'), findsNothing);
      expect(find.text('Nova sala'), findsOneWidget);
      expect(find.text('Sala anterior'), findsNothing);
      expect(find.text('Resultado antigo'), findsNothing);
      expect(sources, hasLength(2));
      expect(loads, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(current.isClosed, isTrue);
      expect(sources.last.closes, 1);
    },
  );

  test('Raízes isoladas não reutilizam registros de outra aplicação', () async {
    final firstRepository = FakeAuthRepository();
    final secondRepository = FakeAuthRepository();
    final first = AppBinding(
      bridge: MatrixBridgeService(
        openUpdates: EmptyMatrixUpdateSource.new,
        rooms: () async => [],
      ),
      authRepository: firstRepository,
    )..dependencies();
    final second = AppBinding(
      bridge: MatrixBridgeService(
        openUpdates: EmptyMatrixUpdateSource.new,
        rooms: () async => [],
      ),
      authRepository: secondRepository,
    )..dependencies();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await settle();
    expect(first.auth, isNot(same(second.auth)));
    first.dispose();
    expect(first.auth.isClosed, isTrue);
    expect(second.auth.isClosed, isFalse);
    await second.auth.login('address', 'user', 'synthetic');
    expect(second.auth.state.account, fixtureAccount);
    expect(first.auth.state.account, isNull);
    second.dispose();
    expect(second.auth.isClosed, isTrue);
  });
}
