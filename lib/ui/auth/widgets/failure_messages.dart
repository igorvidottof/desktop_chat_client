import '../../../domain/models/models.dart';

String probeErrorMessage(ProbeError error) => switch (error) {
  ProbeError.invalidServerAddress =>
    'Informe uma URL HTTPS válida, sem credenciais, consulta ou fragmento.',
  ProbeError.network =>
    'Não foi possível conectar ao servidor. Verifique o endereço e a conexão e tente novamente.',
  ProbeError.tls =>
    'Não foi possível estabelecer uma conexão TLS segura. Verifique o certificado do servidor.',
  ProbeError.unusableHomeserver =>
    'O servidor não forneceu uma resposta Matrix válida para esta consulta. Verifique a URL ou tente novamente mais tarde.',
  ProbeError.internal =>
    'Não foi possível concluir a verificação. Tente novamente.',
};

String loginErrorMessage(LoginError error) => switch (error) {
  LoginError.invalidServerAddress => probeErrorMessage(
    ProbeError.invalidServerAddress,
  ),
  LoginError.invalidInput => 'Informe o usuário e a senha.',
  LoginError.passwordLoginUnsupported =>
    'Este servidor não oferece login com senha.',
  LoginError.invalidCredentials =>
    'Usuário ou senha inválidos. Digite novamente para tentar.',
  LoginError.network => probeErrorMessage(ProbeError.network),
  LoginError.tls => probeErrorMessage(ProbeError.tls),
  LoginError.rateLimited =>
    'Muitas tentativas. Aguarde antes de tentar novamente.',
  LoginError.alreadyAuthenticated =>
    'Já existe uma conta autenticada. Verifique a sessão novamente.',
  LoginError.loginInProgress =>
    'Já existe uma tentativa de login em andamento.',
  LoginError.unusableHomeserver => probeErrorMessage(
    ProbeError.unusableHomeserver,
  ),
  LoginError.secureStorage =>
    'O armazenamento seguro não está disponível. O login não foi concluído. Desbloqueie o cofre do sistema e tente novamente.',
  LoginError.persistence =>
    'Não foi possível salvar a sessão. O login não foi concluído. Verifique o armazenamento e tente novamente.',
  LoginError.internal => 'Não foi possível concluir o login. Tente novamente.',
};

String sessionErrorMessage(SessionError error) => switch (error) {
  SessionError.operationInProgress =>
    'Uma operação de autenticação está em andamento. Tente novamente.',
  SessionError.network =>
    'Não foi possível validar a sessão com o servidor. Verifique a conexão e tente novamente. A sessão salva foi preservada.',
  SessionError.tls => probeErrorMessage(ProbeError.tls),
  SessionError.invalidSession =>
    'A sessão foi rejeitada pelo servidor. Entre novamente.',
  SessionError.corruptedSession =>
    'A sessão salva está incompleta ou não pôde ser lida. Verifique o armazenamento e tente novamente.',
  SessionError.secureStorage =>
    'Não foi possível acessar o armazenamento seguro. Desbloqueie o cofre do sistema e tente novamente.',
  SessionError.persistence =>
    'Não foi possível acessar os dados da sessão. Verifique o armazenamento e tente novamente.',
  SessionError.internal =>
    'Não foi possível verificar a sessão. Tente novamente.',
};

String logoutErrorMessage(LogoutError error) => switch (error) {
  LogoutError.notAuthenticated => 'A sessão já não está autenticada.',
  LogoutError.logoutInProgress => 'A saída já está em andamento.',
  LogoutError.authenticationOperationInProgress =>
    'Uma operação de autenticação está em andamento. Tente novamente.',
  LogoutError.secureStorage =>
    'Não foi possível remover a sessão do armazenamento seguro. Desbloqueie o cofre do sistema e tente Logout novamente.',
  LogoutError.localCleanup =>
    'Não foi possível concluir a remoção da sessão local. Tente Logout novamente.',
  LogoutError.internal =>
    'Não foi possível confirmar a saída. Tente Logout novamente.',
};
