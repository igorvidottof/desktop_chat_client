# desktop_chat_client

Cliente de mensagens Matrix para desktop (macOS, Windows e Linux), criando em
Flutter. A comunicação Matrix é implementada em Rust com `matrix-sdk` e exposta
ao Flutter por `flutter_rust_bridge`.

## Requisitos

- Flutter **3.47.6** no `PATH` (versão registrada em `.fvmrc`).
- Rust **stable**, instalado via `rustup`, com Cargo no `PATH`.
  O build Flutter e a CI usam stable; comandos Cargo locais em `rust/` usam
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
flutter pub get
flutter run -d macos
```

No Windows ou Linux, substitua o comando de execução pelo correspondente ao host:

```sh
flutter run -d windows
flutter run -d linux
```

O build Flutter compila e integra Rust automaticamente; os bindings já estão no
repositório. Informe o homeserver HTTPS **https://matrix.org** (foi o único testado) e uma conta Matrix existente com login
por senha (se não tiver, crie uma em **https://account.matrix.org/register** se não tiver).

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

A partir de `rust/`:

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

Para baixar artefatos disponíveis, basta estar conectado ao GitHub e ter acesso
de leitura ao repositório; não é necessário fazer fork. Acesse **Actions**, abra
uma execução bem-sucedida e baixe o artefato da sua plataforma em **Artifacts**.

Para gerar seus próprios artefatos, faça um fork, habilite os workflows na aba
**Actions**, selecione **Windows Release**, **Linux Release** ou **macOS Release**
e clique em **Run workflow** na branch `main`. Aguarde a conclusão e baixe o artefato.

Extraia o conteúdo completo,
mantendo executável, bibliotecas e dados juntos. No macOS, extraia também o ZIP
interno `desktop-chat-client-macos-universal.zip`, que contém o aplicativo `.app`.

### Windows: runtime ausente

Se aparecer `VCRUNTIME140.dll was not found`, falta o runtime Microsoft Visual C++.
Instale o **Microsoft Visual C++ Redistributable for Visual Studio 2015–2022 (x64)**
pelo [download oficial da Microsoft](https://aka.ms/vc14/vc_redist.x64.exe) e abra
o aplicativo novamente. Essa é uma dependência de runtime da Microsoft; não baixe
DLLs individuais de sites de terceiros.

## Arquitetura

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

Flutter cuida da apresentação e do estado da interface; Rust cuida da comunicação
do protocolo Matrix, sincronização e sessão.

## Segurança

Credenciais de sessão e dados de restauração são gerenciados no lado nativo/Rust.
Tokens e o segredo do armazenamento ficam no cofre do sistema, sem exposição à
interface Flutter. A senha de login não é persistida.

## Limitações

- E2EE está fora do escopo; salas criptografadas não suportam histórico nem envio.
- Histórico limitado a até 50 eventos recentes, sem paginação; envio apenas de texto.
- Os releases não têm garantia de assinatura/notarização para distribuição pública;
  o macOS usa assinatura ad-hoc, sem Developer ID ou notarização.
