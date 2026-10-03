import 'package:desktop_chat_client/main.dart';
import 'package:desktop_chat_client/src/rust/api/simple.dart';
import 'package:desktop_chat_client/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String greeting;

  setUpAll(() async {
    await RustLib.init();
    greeting = await hello();
  });

  tearDownAll(() => RustLib.dispose());

  testWidgets('Displays the greeting returned by the real Rust bridge', (
    tester,
  ) async {
    expect(greeting, 'Hello from Rust!');
    await tester.pumpWidget(MyApp(greeting: greeting));
    expect(find.text('Hello from Rust!'), findsOneWidget);
  });
}
