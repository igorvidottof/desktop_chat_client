import '../../../domain/models/models.dart';

const _unchanged = Object();

class AuthState {
  const AuthState({
    this.initializing = true,
    this.probing = false,
    this.loggingIn = false,
    this.loggingOut = false,
    this.account,
    this.sessionError,
    this.probeError,
    this.loginError,
    this.logoutError,
    this.info,
    this.logoutNotice,
    this.sessionEpoch = 0,
  });
  final bool initializing;
  final bool probing;
  final bool loggingIn;
  final bool loggingOut;
  final AccountSummary? account;
  final SessionError? sessionError;
  final ProbeError? probeError;
  final LoginError? loginError;
  final LogoutError? logoutError;
  final ServerInfo? info;
  final String? logoutNotice;
  final int sessionEpoch;
  AuthState copyWith({
    bool? initializing,
    bool? probing,
    bool? loggingIn,
    bool? loggingOut,
    Object? account = _unchanged,
    Object? sessionError = _unchanged,
    Object? probeError = _unchanged,
    Object? loginError = _unchanged,
    Object? logoutError = _unchanged,
    Object? info = _unchanged,
    Object? logoutNotice = _unchanged,
    int? sessionEpoch,
  }) => AuthState(
    initializing: initializing ?? this.initializing,
    probing: probing ?? this.probing,
    loggingIn: loggingIn ?? this.loggingIn,
    loggingOut: loggingOut ?? this.loggingOut,
    account:
        identical(account, _unchanged)
            ? this.account
            : account as AccountSummary?,
    sessionError:
        identical(sessionError, _unchanged)
            ? this.sessionError
            : sessionError as SessionError?,
    probeError:
        identical(probeError, _unchanged)
            ? this.probeError
            : probeError as ProbeError?,
    loginError:
        identical(loginError, _unchanged)
            ? this.loginError
            : loginError as LoginError?,
    logoutError:
        identical(logoutError, _unchanged)
            ? this.logoutError
            : logoutError as LogoutError?,
    info: identical(info, _unchanged) ? this.info : info as ServerInfo?,
    logoutNotice:
        identical(logoutNotice, _unchanged)
            ? this.logoutNotice
            : logoutNotice as String?,
    sessionEpoch: sessionEpoch ?? this.sessionEpoch,
  );
}
