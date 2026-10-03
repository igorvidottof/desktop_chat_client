import 'package:flutter/material.dart';

import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final greeting = await hello();
  runApp(MyApp(greeting: greeting));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.greeting});

  final String greeting;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desktop Chat Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('Rust Bridge')),
        body: Center(
          child: Text(
            greeting,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
      ),
    );
  }
}
