import 'dart:async';

import 'src/rust/api/simple.dart';

/// Fonte da sessão de apresentação; vários widgets compartilham um consumidor nativo.
abstract interface class MatrixUpdateSource {
  Stream<MatrixUpdate> get updates;
  Future<void> dispose();
}

typedef MatrixUpdateSourceFactory = MatrixUpdateSource Function();

class EmptyMatrixUpdateSource implements MatrixUpdateSource {
  @override
  Stream<MatrixUpdate> get updates => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

/// ACK ocorre após entrega síncrona aos widgets, limitando a porta FRB a um evento.
/// Widgets cancelam suas assinaturas; não pausam nem retêm filas de eventos.
class NativeMatrixUpdateSource implements MatrixUpdateSource {
  NativeMatrixUpdateSource({
    Future<String> Function() open = openMatrixUpdates,
    Stream<MatrixUpdate> Function({required String subscriptionId}) listen =
        matrixUpdates,
    Future<void> Function({
          required String subscriptionId,
          required int sequence,
        })
        acknowledge =
        acknowledgeMatrixUpdate,
    Future<void> Function({required String subscriptionId}) close =
        closeMatrixUpdates,
  }) : _open = open,
       _listen = listen,
       _acknowledge = acknowledge,
       _close = close {
    unawaited(_attach());
  }

  final Future<String> Function() _open;
  final Stream<MatrixUpdate> Function({required String subscriptionId}) _listen;
  final Future<void> Function({
    required String subscriptionId,
    required int sequence,
  })
  _acknowledge;
  final Future<void> Function({required String subscriptionId}) _close;

  final _updates = StreamController<MatrixUpdate>.broadcast(sync: true);
  StreamSubscription<MatrixUpdate>? _subscription;
  String? _id;
  bool _disposed = false;

  @override
  Stream<MatrixUpdate> get updates => _updates.stream;

  Future<void> _attach() async {
    try {
      final id = await _open();
      if (_disposed) {
        await _close(subscriptionId: id);
        return;
      }
      _id = id;
      _subscription = _listen(subscriptionId: id).listen(
        (update) {
          if (!_disposed && _id == update.subscriptionId) {
            _updates.add(update);
            unawaited(
              _acknowledge(subscriptionId: id, sequence: update.sequence),
            );
          }
        },
        onError: (_) => _reconnecting(),
        onDone: () {
          // Reanexar a fonte não inicia outro sync. Hot restart segue esta mesma API.
          if (!_disposed) unawaited(_attach());
        },
      );
    } catch (_) {
      _reconnecting();
    }
  }

  void _reconnecting() {
    if (_disposed) return;
    _updates.add(
      const MatrixUpdate(
        subscriptionId: '',
        sequence: 0,
        kind: MatrixUpdateKind.status,
        conversationId: null,
        message: null,
        status: MatrixSyncStatus.reconnecting,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final id = _id;
    _id = null;
    if (id != null) await _close(subscriptionId: id);
    await _subscription?.cancel();
    await _updates.close();
  }
}
