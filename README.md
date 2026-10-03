# desktop_chat_client

Minimal Flutter desktop / Rust connectivity through Flutter Rust Bridge 2.13.0.
The app initializes `RustLib`, awaits Rust's `hello()` through generated Dart
bindings, and displays the returned `Hello from Rust!` string. No Matrix SDK is
included yet.

## Toolchain

Verified with Flutter 3.47.6 (Dart 3.13.5), Rust 1.99.0, and CocoaPods 1.17.0
on Apple Silicon macOS.
The Rust version and desktop targets are pinned in `rust/rust-toolchain.toml`.
macOS requires working CocoaPods (Flutter recommends >= 1.16.2). This machine's
old `/usr/local/bin/pod` is shadowing the repaired Homebrew install; put
`/opt/homebrew/bin` first in PATH for builds and runs:

```sh
export PATH="/opt/homebrew/bin:$PATH"
```

Other desktop hosts need their normal Flutter and Rust native build toolchains.

Install the matching official generator and resolve Dart dependencies:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter pub get
```

## Bindings and native build

Edit the API in `rust/src/api/simple.rs`, then regenerate:

```sh
flutter_rust_bridge_codegen generate
```

`flutter_rust_bridge.yaml` selects `crate::api`, the `rust/` crate, and generated
Dart output in `lib/src/rust/`. The generator writes the Dart API and platform
bindings plus `rust/src/frb_generated.rs`; do not edit generated files manually.
Dart, Rust, and the generator are pinned to the same bridge release.

The official Cargokit backend in `rust_builder/` builds and bundles Rust during
Flutter desktop builds. The app depends on that local FFI build plugin; macOS
uses its CocoaPods build phase, and Linux/Windows use CMake. The crate emits
`cdylib` and `staticlib` artifacts. Cargokit source is vendored by the official
integration command.

Before widget tests, build the host dynamic library with `cargo build --release`
from `rust/`. FRB's generated loader uses `rust/target/release/` for unpackaged
tests; packaged macOS apps use the Cargokit framework.

The stable 2.13.0 Native Assets scaffold was tested, but its generated loader
could not find the code asset. This project therefore uses FRB's documented
default Cargokit backend, with no custom loader or unrelated workaround.

## Validate and run

```sh
flutter_rust_bridge_codegen generate
cd rust
cargo fmt --check
cargo check
cargo build --release
cargo clippy -- -D warnings
cargo test
cd ..
flutter analyze
flutter test
flutter build macos
flutter run -d macos
git diff --check
git status --short
```

The widget test calls the real native bridge and checks that Flutter displays
its returned value. Linux and Windows are configured but require validation on
those hosts. This increment intentionally adds no state-management package or
application architecture.

Official documentation:
- [Existing-project integration](https://cjycode.com/flutter_rust_bridge/manual/integrate/builtin)
- [Cargokit backend](https://cjycode.com/flutter_rust_bridge/manual/integrate/cargokit)

Flutter currently warns that this generated macOS plugin does not support
Swift Package Manager and that this will become an error in a future Flutter
release. The verified integration uses Flutter's supported CocoaPods fallback.
