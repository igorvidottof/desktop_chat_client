# desktop_chat_client

Cliente desktop Matrix com interface Flutter e backend Rust, integrados por
Flutter Rust Bridge. Inclui login por senha, salas já ingressadas, histórico
recente, envio e recebimento de texto, restauração de sessão e logout.

- [Principais decisões técnicas](docs/decisoes-tecnicas.md)
- [Limitações e itens pendentes](docs/limitacoes.md)

## Configuração

Execute os comandos na raiz do projeto, salvo indicação contrária.

### Ferramentas

| Componente          | Versão ou configuração do projeto                                                                                          |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Flutter / Dart      | SDK local identificado: Flutter 3.47.6 / Dart 3.13.5; Flutter não está fixado por um gerenciador de versões no repositório |
| Rust                | 1.99.0, fixado em `rust/rust-toolchain.toml`, com Rustfmt e Clippy                                                         |
| Flutter Rust Bridge | 2.13.0 no Dart, Rust e gerador de bindings                                                                                 |
| Matrix Rust SDK     | 0.19.1, com SQLite embarcado, TLS via Rustls                                                                               |
| GetX                | 4.7.3 no `pubspec.lock`                                                                                                    |

Instale Flutter e Rust por meio do `rustup`, com os executáveis no `PATH`.
`pubspec.lock` e `rust/Cargo.lock` registram as dependências resolvidas. O primeiro
build precisa de internet para baixar pacotes e a toolchain Rust. Não é necessário
instalar um servidor Matrix ou guardar credenciais em arquivos do projeto.

Prepare o ambiente nativo do sistema em que vai executar a aplicação:

| Sistema | Requisitos                                                                                                                        |
| ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| macOS   | Xcode, ferramentas de linha de comando e CocoaPods; a integração existente usa Cargokit/CocoaPods.                                |
| Linux   | Compilador e bibliotecas desktop exigidos pelo Flutter, além de um Secret Service acessível e desbloqueado para guardar a sessão. |
| Windows | Visual Studio com ferramentas de desenvolvimento desktop C++, toolchain Rust MSVC e acesso ao cofre de credenciais do sistema.    |

Consulte as instruções oficiais de instalação do Flutter para
[macOS](https://docs.flutter.dev/platform-integration/macos/setup),
[Linux](https://docs.flutter.dev/platform-integration/linux/setup) e
[Windows](https://docs.flutter.dev/platform-integration/windows/setup).

Confira o ambiente e obtenha as dependências:

```sh
flutter --version
flutter doctor -v
flutter pub get
flutter devices
```

Confira a toolchain fixada a partir de `rust/`:

```sh
cd rust
rustup show active-toolchain
rustc --version
cd ..
```

## Execução

Use o comando correspondente ao sistema do host:

```sh
flutter run -d macos
```

```sh
flutter run -d linux
```

```sh
flutter run -d windows
```

O build Flutter integra a biblioteca Rust por meio de `rust_builder/`; não há
backend separado para iniciar. Os bindings já estão no repositório.
No ambiente macOS usado no desenvolvimento, selecione o CocoaPods do Homebrew
caso outra instalação no `PATH` cause falhas:

```sh
export PATH="/opt/homebrew/bin:$PATH"
flutter run -d macos
```

Esse caminho é específico de instalações em `/opt/homebrew`; ajuste-o conforme
sua instalação local.

### Usar a aplicação

1. Informe a URL HTTPS do homeserver e verifique se ele aceita login por senha.
2. Entre com uma conta Matrix existente, que já participe de uma sala. Cadastro
   e ingresso em salas não fazem parte deste cliente.
3. Aguarde a sincronização, selecione uma sala e envie texto. `Enter` envia;
   `Shift+Enter` insere uma quebra de linha. A entrada é limpa após a confirmação
   de envio pelo servidor.
4. Feche e reabra o aplicativo para usar a restauração de sessão. Use a ação de
   logout para encerrar a sessão local e solicitar a saída ao servidor.

O cofre do sistema deve estar disponível para login e restauração. Senhas não
são persistidas; tokens e o segredo do store ficam sob responsabilidade de Rust.
Consulte as [limitações](docs/limitacoes.md) do escopo atual.

## Verificação

Para alterações Dart, na raiz:

```sh
dart format lib/app lib/data lib/domain lib/ui lib/main.dart test
flutter analyze
flutter test
```

Os testes Dart usam repositórios falsos ou funções da bridge injetadas, sem
biblioteca nativa carregada, conta Matrix, credenciais ou homeserver real.
Cobrem estados, falhas, resultados obsoletos, assinaturas, reconciliação de
mensagens, layouts e mensagens não lidas.

Para alterações Rust, a partir de `rust/`:

```sh
cargo fmt --check
cargo clippy -- -D warnings
cargo test
```

Os testes Rust incluem cofre falso, ciclo da sessão, sincronização
com o SDK. Alguns usam servidor HTTP de teste em loopback; não precisam de
credenciais ou homeserver de produção.

Para gerar um build, execute na raiz o comando do sistema local:

```sh
flutter build macos
```

```sh
flutter build linux
```

```sh
flutter build windows
```

Cada plataforma precisa ser validada no host correspondente. Esses comandos
são procedimentos, não um registro de aprovação dos builds. Veja as
[verificações pendentes](docs/limitacoes.md#verificações-ainda-necessárias).

## Regenerar a bridge

Somente quando a API pública Rust mudar, instale o gerador compatível e execute
na raiz:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
```

Garanta que o diretório de executáveis do Cargo esteja no `PATH`. A configuração
está em `flutter_rust_bridge.yaml`; os arquivos gerados ficam em `lib/src/rust/`
e `rust/src/frb_generated.rs`. Não os edite manualmente. Depois da geração,
execute as verificações Dart, Rust e o build nativo do host.
