# Desktop Chat Client 💬

Cliente de mensagns Matrix para desktop (macOS, Windows e Linux), criado em
Flutter. A comunicação Matrix é implementada em Rust com `matrix-sdk` e exposta
ao Flutter por `flutter_rust_bridge`.

## Requisitos

- [FVM](https://fvm.app/documentation/getting-started/installation) instalado no `PATH`
  para gerenciar o Flutter **3.47.6** utilizado no projeto.
- Rust **stable**, instalado via `rustup`, com Cargo no `PATH`.
  O build Flutter e a CI usam stable enquanto comandos Cargo locais em `rust/` usam
  **1.99.0**, fixado em `rust/rust-toolchain.toml` e instalado pelo rustup.
- macOS 12 ou superior: Xcode, ferramentas de linha de comando e CocoaPods **1.16.2 ou superior**.
- Windows: Visual Studio com **Desenvolvimento para desktop com C++**, Rust MSVC
  e NASM no `PATH` (usado pelo AWS-LC).
- Linux: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`,
  `liblzma-dev` e `libdbus-1-dev` (nomes de pacotes Ubuntu/Debian).

O cofre do sistema deve estar disponível para login e restauração de sessão:
Keychain no macOS, cofre de credenciais no Windows ou Secret Service desbloqueado
no Linux. O primeiro build precisa de internet para baixar dependências.

## Como executar

Na raiz do projeto, usando Flutter 3.47.6:

```sh
fvm use
flutter pub get
flutter run -d macos
```

No Windows ou Linux, substitua o comando de execução pelo correspondente ao host:

```sh
flutter run -d windows
flutter run -d linux
```

O build Flutter compila e integra Rust automaticamente; os bindings já estão no
repositório. Informe o homeserver HTTPS [Matrix.org](https://matrix.org) (foi o único testado) e uma conta Matrix existente com login
por senha (se não tiver, crie uma no [site oficial](https://account.matrix.org/register)).

## Funcionalidades implementadas

- Conexão com homeserver Matrix e autenticação por senha.
- Restauração de sessão e logout.
- Listagem de salas e histórico recente de mensagens.
- Envio de mensagens de texto e atualização contínua das conversas.
- Indicadores de mensagens não lidas e marcação de leitura.
- Aceitação de convites e criação de salas privadas com convites.

## Testes

Na raiz do projeto:

```sh
flutter analyze
flutter test
```

Na pasta `rust/`:

```sh
cargo test --locked
```

Os testes usam fakes e servidores locais de teste; não exigem credenciais nem
homeserver de produção.

## Artefatos de release / CI

Os workflows GitHub Actions em `.github/workflows/` executam em pushes para
`main` ou manualmente e produzem estes artefatos após builds bem-sucedidos:

| Plataforma | Arquitetura                                    | Artefato                              |
| ---------- | ---------------------------------------------- | ------------------------------------- |
| Windows    | x64                                            | `desktop-chat-client-windows-release` |
| Linux      | x64                                            | `desktop-chat-client-linux-x64`       |
| Linux      | ARM64                                          | `desktop-chat-client-linux-arm64`     |
| macOS      | Universal (Apple Silicon arm64 e Intel x86_64) | `desktop-chat-client-macos-universal` |

Para baixar artefatos (executores do app) é necessário estar logado no Github. Acesse o [repositório do app](https://github.com/igorvidottof/desktop_chat_client/actions), abra
uma execução bem-sucedida e baixe o artefato da sua plataforma em **Artifacts**.

Para gerar seus próprios artefatos, faça um fork, habilite os workflows na aba
**Actions**, selecione **Windows Release**, **Linux Release** ou **macOS Release**
e clique em **Run workflow** na branch `main`. Aguarde a conclusão e baixe o artefato.

Extraia o conteúdo completo,
mantendo executável, bibliotecas e dados juntos. No macOS, extraia também o ZIP
interno `desktop-chat-client-macos-universal.zip`, que contém o aplicativo `.app`.

### Windows: runtime ausente

Ao executar o app no Windows, se aparecer algo como `VCRUNTIME140.dll was not found`, é necessário baixar o runtime Microsoft Visual C++.
Instale o **Microsoft Visual C++ Redistributable for Visual Studio 2015–2022 (x64)**
pelo [download oficial da Microsoft](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170#latest-supported-redistributable-version) e abra
o aplicativo novamente. Essa é uma dependência de runtime da Microsoft. Não baixe
DLLs individuais de sites de terceiros.

## Principais decisões técnicas

- Clara definição de arquitetura descrita abaixo, mantendo Flutter e Rust totalmente separados.
- Criação de CI pipeline para buildar os apps para todos os sistemas operacionais requeridos a partir dos commits à branch main, evitando assim processos manuais.
- Credenciais de sessão e dados de restauração são gerenciados no lado nativo/Rust.
- Tokens e o segredo do armazenamento ficam no cofre do sistema, sem exposição à
  interface Flutter.
- A senha de login não é persistida em nenhum local, evitando brechas e possíveis vazamentos.

## Arquitetura

O projeto segue as [recomendações oficiais de arquitetura do Flutter](https://docs.flutter.dev/app-architecture),
com Views e ViewModels na camada de UI e Repositories e Services na camada de dados.
GetX implementa os ViewModels e a composição de dependências.

```text
Flutter UI
    ↓
GetX ViewModels
    ↓
Repositories / Services
    ↓
flutter_rust_bridge
    ↓
Rust / Matrix SDK
```

O Flutter cuida da apresentação e do estado da interface, ao passo que o Rust cuida da comunicação
do protocolo Matrix, sincronização e sessão.

Tomei cuidado para garantir que as responsabilidades não se misturem, mantendo assim uma arquitetura limpa e escalável.

## Limitações

- Tentei implementar E2EE, porém pelo tempo escasso não consegui implementá-lo totalmente, logo, salas criptografadas não suportam histórico nem envio.
- O histórico é limitado a até 50 eventos recentes, sem paginação e com o envio apenas de textos simples.
- Algumas melhorias de UI/UX como notificação ao enviar e receber mensagens foram deixadas de lado em prol de configurar o ambiente RUST de maneira segura.
- Os builds para os sistemas operacionais não foram extensamente testados (o app deve funcionar de maneira fluída para macOS, Windows x64 e Linux Ubuntu 24.04).
