# desktop_chat_client

Flutter desktop Matrix messenger with a Rust backend through Flutter Rust Bridge
2.13.0. Existing flows include homeserver probing, password login, secure session
restoration, joined rooms, bounded text history, sending, native live updates,
E2EE message presentation, and cooperative logout with deferred native cleanup.

## Setup

The current Flutter toolchain is Flutter 3.47.6 / Dart 3.13.5. The native toolchain
is pinned to Rust 1.99.0 in `rust/rust-toolchain.toml`. macOS requires Xcode and
CocoaPods; the project uses the existing Cargokit/CocoaPods integration. On this
machine, select the Homebrew CocoaPods installation when building:

```sh
export PATH="/opt/homebrew/bin:$PATH"
flutter pub get
flutter run -d macos
```

Linux and Windows require their respective Flutter desktop and Rust toolchains.
Configured targets alone do not establish successful builds on those hosts.

## Validation

```sh
dart format lib/app lib/data lib/domain lib/ui lib/main.dart test
flutter analyze
flutter test
flutter build macos
git diff --check
```

Tests use fake repositories or injected bridge functions and require no native
library, Matrix account, credentials, live homeserver, or network access. They
cover safe failures, restoration/logout presentation, stale results, subscription
cleanup, bounded reconciliation, desktop layouts, and keyboard composition.

## Native bindings

Generated files remain in `lib/src/rust/` and `rust/src/frb_generated.rs`. Do not
edit them by hand. Only regenerate when intentionally changing the Rust API:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
```

Native changes should be checked from `rust/` with `cargo fmt --check`,
`cargo clippy -- -D warnings`, and `cargo test`. The architecture/UI checkpoint
makes no native API changes and requires no regeneration.

## Desktop behavior and limits

At widths of 800 logical pixels and above, the 304-pixel conversation sidebar
stays visible beside the selected conversation. Below 800 pixels, the same room
selection drives a single pane with a back action. Message bodies are selectable;
Enter sends and Shift+Enter adds a newline. Input is cleared only after server
acceptance. The immediate input affordance preserves the native limit of 10,000
Unicode scalar values; Rust remains authoritative for validation.

The timeline retains at most 50 messages. There is no pagination, attachments,
search, reactions, or additional authentication flow. Remote send failures can
leave acceptance uncertain: check history before explicitly retrying. Logout
keeps the existing truthful progress screen while Rust completes cooperative
shutdown, including its normal long poll.

Live authentication, encrypted messaging, quit/relaunch restoration, and logout
must also be checked manually with a suitable test account. Fake tests do not
prove production homeserver behavior. Linux and Windows builds require those
hosts. The existing generated macOS plugin uses CocoaPods and currently emits a
Flutter Swift Package Manager compatibility warning.
