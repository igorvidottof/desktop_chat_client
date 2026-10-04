import '../../domain/models/models.dart';
import '../services/matrix_bridge_service.dart';
import 'model_mapping.dart';
import '../../src/rust/api/simple.dart' as native;
import 'auth_repository.dart';

class MatrixAuthRepository implements AuthRepository {
  MatrixAuthRepository(this.bridge);
  final MatrixBridgeService bridge;
  AccountSummary? _account;
  @override
  AccountSummary? get account => _account;
  @override
  Future<SessionState> initialize() => safeBridgeCall(
    () async {
      final result = await bridge.initialize();
      _account = result.account == null ? null : mapAccount(result.account!);
      return SessionState(account: _account);
    },
    SessionError.values,
    SessionError.internal,
    native.SessionError,
  );
  @override
  Future<ServerInfo> probe(String address) => safeBridgeCall(
    () async {
      final info = await bridge.probe(address);
      return ServerInfo(
        serverAddress: info.serverAddress,
        supportsPasswordLogin: info.supportsPasswordLogin,
      );
    },
    ProbeError.values,
    ProbeError.internal,
    native.ProbeError,
  );
  @override
  Future<AccountSummary> login(
    String address,
    String username,
    String password,
  ) => safeBridgeCall(
    () async {
      return _account = mapAccount(
        await bridge.login(address, username, password),
      );
    },
    LoginError.values,
    LoginError.internal,
    native.LoginError,
  );
  @override
  Future<LogoutResult> logout() => safeBridgeCall(
    () async {
      final result = await bridge.logout();
      _account = null;
      return LogoutResult(
        remoteStatus: RemoteLogoutStatus.values.byName(
          result.remoteStatus.name,
        ),
        storeCleanupPending: result.storeCleanupPending,
      );
    },
    LogoutError.values,
    LogoutError.internal,
    native.LogoutError,
  );
}
