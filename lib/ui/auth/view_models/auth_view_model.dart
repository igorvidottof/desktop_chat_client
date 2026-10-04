import 'dart:async';
import 'package:get/get.dart';
import '../../../domain/models/models.dart';
import '../../../data/repositories/auth_repository.dart';
import 'auth_state.dart';

class AuthViewModel extends GetxController {
  AuthViewModel({required this.repository});
  final AuthRepository repository;
  AuthState _state = const AuthState();
  AuthState get state => _state;
  set state(AuthState value) {
    if (isClosed) return;
    _state = value;
    update();
  }

  int _operation = 0;
  @override
  void onInit() {
    super.onInit();
    Future.microtask(initialize);
  }

  @override
  void onClose() {
    _operation++;
    super.onClose();
  }

  bool get _busy =>
      isClosed ||
      state.initializing ||
      state.loggingIn ||
      state.probing ||
      state.loggingOut;
  bool _current(int operation) => !isClosed && operation == _operation;

  Future<void> initialize() async {
    if (isClosed) return;
    final operation = ++_operation;
    state = state.copyWith(initializing: true, sessionError: null);
    try {
      final result = await repository.initialize();
      if (!_current(operation)) return;
      state = state.copyWith(account: result.account);
    } on SessionError catch (error) {
      if (_current(operation)) state = state.copyWith(sessionError: error);
    } catch (_) {
      if (_current(operation)) {
        state = state.copyWith(sessionError: SessionError.internal);
      }
    } finally {
      if (_current(operation)) state = state.copyWith(initializing: false);
    }
  }

  Future<void> probe(String address) async {
    if (_busy) return;
    final operation = ++_operation;
    state = state.copyWith(
      probing: true,
      info: null,
      probeError: null,
      loginError: null,
    );
    try {
      final info = await repository.probe(address);
      if (_current(operation)) state = state.copyWith(info: info);
    } on ProbeError catch (error) {
      if (_current(operation)) state = state.copyWith(probeError: error);
    } catch (_) {
      if (_current(operation)) {
        state = state.copyWith(probeError: ProbeError.internal);
      }
    } finally {
      if (_current(operation)) state = state.copyWith(probing: false);
    }
  }

  Future<void> login(String address, String username, String password) async {
    if (_busy || state.account != null) return;
    final operation = ++_operation;
    state = state.copyWith(
      loggingIn: true,
      loginError: null,
      logoutNotice: null,
      probeError: null,
      info: null,
    );
    try {
      final account = await repository.login(address, username, password);
      if (_current(operation)) {
        state = state.copyWith(
          account: account,
          sessionError: null,
          sessionEpoch: state.sessionEpoch + 1,
        );
      }
    } on LoginError catch (error) {
      if (_current(operation)) state = state.copyWith(loginError: error);
    } catch (_) {
      if (_current(operation)) {
        state = state.copyWith(loginError: LoginError.internal);
      }
    } finally {
      if (_current(operation)) state = state.copyWith(loggingIn: false);
    }
  }

  Future<void> logout() async {
    if (_busy || state.account == null) return;
    final operation = ++_operation;
    // Invalida a apresentação imediatamente, sem cancelar o encerramento nativo.
    state = state.copyWith(
      loggingOut: true,
      logoutError: null,
      info: null,
      probeError: null,
      sessionEpoch: state.sessionEpoch + 1,
    );
    try {
      final result = await repository.logout();
      if (!_current(operation)) return;
      final confirmed =
          result.remoteStatus == RemoteLogoutStatus.confirmed ||
          result.remoteStatus == RemoteLogoutStatus.alreadyInvalid;
      state = state.copyWith(
        account: null,
        sessionError: null,
        loginError: null,
        logoutNotice:
            confirmed
                ? null
                : 'A sessão local foi removida. Não foi possível confirmar a saída no servidor.',
      );
    } on LogoutError catch (error) {
      if (!_current(operation)) return;
      if (error == LogoutError.notAuthenticated) {
        await initialize();
      } else {
        state = state.copyWith(logoutError: error);
      }
    } catch (_) {
      if (_current(operation)) {
        state = state.copyWith(logoutError: LogoutError.internal);
      }
    } finally {
      if (!isClosed) state = state.copyWith(loggingOut: false);
    }
  }
}
