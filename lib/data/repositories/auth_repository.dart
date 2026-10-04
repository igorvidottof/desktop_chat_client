import '../../domain/models/models.dart';

abstract interface class AuthRepository {
  AccountSummary? get account;
  Future<SessionState> initialize();
  Future<ServerInfo> probe(String address);
  Future<AccountSummary> login(
    String address,
    String username,
    String password,
  );
  Future<LogoutResult> logout();
}
