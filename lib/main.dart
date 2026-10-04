import 'package:flutter/material.dart';
import 'app/chat_app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const ChatApp());
}
