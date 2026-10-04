import 'package:flutter/material.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/room_repository.dart';
import '../data/repositories/chat_repository.dart';
import '../data/services/matrix_bridge_service.dart';
import '../ui/auth/widgets/auth_view.dart';
import '../ui/rooms/widgets/desktop_shell.dart';
import '../ui/chat/widgets/chat_view.dart';
import '../ui/core/themes/app_theme.dart';
import 'app_binding.dart';

class ChatApp extends StatefulWidget {
  const ChatApp({
    super.key,
    this.bridge = const MatrixBridgeService(),
    this.authRepository,
    this.roomRepository,
    this.chatRepository,
  });
  final MatrixBridgeService bridge;
  final AuthRepository? authRepository;
  final RoomRepository? roomRepository;
  final ChatRepository? chatRepository;
  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  late final AppBinding _binding;
  @override
  void initState() {
    super.initState();
    _binding = AppBinding(
      bridge: widget.bridge,
      authRepository: widget.authRepository,
      roomRepository: widget.roomRepository,
      chatRepository: widget.chatRepository,
    )..dependencies();
  }

  @override
  void dispose() {
    _binding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Desktop Chat',
    theme: buildAppTheme(),
    home: AuthView(
      viewModel: _binding.auth,
      authenticatedView:
          () => DesktopShell(
            auth: _binding.auth,
            rooms: _binding.rooms!,
            conversationBuilder:
                (room) =>
                    ChatView(key: ValueKey(room.id), viewModel: _binding.chat!),
          ),
    ),
  );
}
