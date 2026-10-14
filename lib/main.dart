import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const JarvisApp());
}

class ChatMessage {
  final ChatRole role;
  final String text;

  ChatMessage({required this.role, required this.text});
}

enum ChatRole { user, assistant, system }

class JarvisApp extends StatefulWidget {
  const JarvisApp({super.key});

  @override
  State<JarvisApp> createState() => _JarvisAppState();
}

class _JarvisAppState extends State<JarvisApp> {
  static const nativeChannel = MethodChannel('jarvis/native');

  // Hardcoded Grok API Key
  static const grokApiKey = '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';
  static const grokEndpoint = 'https://api.x.ai/v1/chat/completions';

  final messageController = TextEditingController();
  final scrollController = ScrollController();

  final List<ChatMessage> messages = [];

  CameraController? cameraController;
  Timer? inactivityTimer;
  Timer? visionTimer;

  bool isListening = false;
  bool isProcessing = false;
  bool cameraEnabled = false;
  bool visionEnabled = false;
  bool wakeWordServiceEnabled = false;

  String status = 'Sleeping';
  String lastWakeWord = '';

  @override
  void initState() {
    super.initState();

    nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'wakeWordDetected') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final keyword = args['keyword']?.toString() ?? 'Wake word detected';
        await activateAssistant(keyword);
      }
    });

    _addMessage(
      ChatMessage(
        role: ChatRole.assistant,
        text: 'Jarvis online hai. Wake word ya message bhej bhai.',
      ),
    );
  }

  @override
  void dispose() {
    inactivityTimer?.cancel();
    visionTimer?.cancel();
    cameraController?.dispose();
    messageController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void _addMessage(ChatMessage message) {
    if (!mounted) return;

    setState(() {
      messages.add(message);
    });

    Future.delayed(const Duration(milliseconds: 100), () {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> startWakeWordBridge() async {
    final microphoneStatus = await Permission.microphone.request();

    if (!microphoneStatus.isGranted) {
      _setStatus('Microphone permission denied');
      return;
    }

    try {
      await nativeChannel.invokeMethod('startWakeWordService');
      setState(() {
        wakeWordServiceEnabled = true;
        status = 'Offline wake-word listener active';
      });
    } catch (error) {
      _setStatus('Native wake-word service unavailable.');
    }
  }

  Future<void> stopWakeWordBridge() async {
    try {
      await nativeChannel.invokeMethod('stopWakeWordService');
    } catch (_) {}

    setState(() {
      wakeWordServiceEnabled = false;
      status = 'Wake-word listener stopped';
    });
  }

  Future<void> activateAssistant(String keyword) async {
    lastWakeWord = keyword;
    setState(() {
      isListening = true;
      status = 'Activated: $keyword';
    });
    _resetInactivityTimer();
    await startCamera();

    _addMessage(
      ChatMessage(
        role: ChatRole.system,
        text: '$keyword suna. Jarvis active hai for 30 seconds.',
      ),
    );
  }

  void _resetInactivityTimer() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(const Duration(seconds: 30), sleepAssistant);
  }

  Future<void> sleepAssistant() async {
    visionTimer?.cancel();
    visionTimer = null;
    await stopCamera();

    if (!mounted) return;

    setState(() {
      isListening = false;
      cameraEnabled = false;
      visionEnabled = false;
      status = 'Sleeping';
    });

    _addMessage(
      ChatMessage(
        role: ChatRole.system,
        text: '30 seconds inactivity. Jarvis sleep mode mein chala gaya.',
      ),
    );
  }

  Future<void> startCamera() async {
    final cameraPermission = await Permission.camera.request();
    if (!cameraPermission.isGranted) {
      _setStatus('Camera permission denied');
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      _setStatus('No camera available');
      return;
    }

    final selectedCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      selectedCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await controller.initialize();

    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() {
      cameraController = controller;
      cameraEnabled = true;
    });
  }

  Future<void> stopCamera() async {
    final controller = cameraController;
    if (controller == null) return;

    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
    await controller.dispose();

    if (mounted) {
      setState(() {
        cameraController = null;
        cameraEnabled = false;
      });
    }
  }

  Future<void> sendMessage() async {
    final text = messageController.text.trim();
    if (text.isEmpty || isProcessing) return;

    messageController.clear();
    _resetInactivityTimer();

    _addMessage(ChatMessage(role: ChatRole.user, text: text));

    setState(() {
      isProcessing = true;
      status = 'Grok is thinking';
    });

    try {
      final response = await callGrokText(text);
      final json = parsePossibleJson(response);

      final reply = json['reply']?.toString() ?? response;
      final command = json['command'];

      _addMessage(ChatMessage(role: ChatRole.assistant, text: reply));

      if (command is Map) {
        await executeCommand(Map<String, dynamic>.from(command));
      }
    } catch (error) {
      _addMessage(ChatMessage(role: ChatRole.system, text: 'Grok error: $error'));
    } finally {
      if (mounted) {
        setState(() {
          isProcessing = false;
          status = isListening ? 'Active' : 'Sleeping';
        });
      }
    }
  }

  Future<String> callGrokText(String userText) async {
    final response = await http.post(
      Uri.parse(grokEndpoint),
      headers: {
        'Authorization': 'Bearer $grokApiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'grok-2-vision-1212',
        'temperature': 0.8,
        'messages': [
          {
            'role': 'system',
            'content': '''
Tum Jarvis ho — ek savage, unfiltered, aur hardcore "bakchod" Hindi-English Android assistant ho jo dost ki tarah baat karta hai. Full attitude me raho, zarurat padne par gaali/slang ya mazaak use karo, par user ke phone ko control karne ke liye JSON output format strict follow karo:
{
  "reply": "tera bakchod aur mazedaar jawaab",
  "command": {
    "type": "none|open_app|flashlight|volume_up|volume_down|volume_mute",
    "app": "whatsapp|instagram|null",
    "value": "null"
  }
}
''',
          },
          {'role': 'user', 'content': userText},
        ],
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return extractAssistantText(body);
  }

  String extractAssistantText(Map<String, dynamic> body) {
    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) return '';
    final message = choices.first['message'];
    if (message is! Map) return '';
    final content = message['content'];
    if (content is String) return content;
    return '';
  }

  Map<String, dynamic> parsePossibleJson(String text) {
    try {
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) return parsed;
    } catch (_) {}
    return {
      'reply': text,
      'command': {'type': 'none'},
    };
  }

  Future<void> executeCommand(Map<String, dynamic> command) async {
    final type = command['type']?.toString() ?? 'none';
    final app = command['app']?.toString();

    switch (type) {
      case 'open_app':
        if (app == 'whatsapp') {
          await openExternalApp('whatsapp://send', fallback: 'https://wa.me/');
        } else if (app == 'instagram') {
          await openExternalApp('instagram://app', fallback: 'https://instagram.com/');
        }
        break;
      case 'flashlight':
        await invokeNative('toggleFlashlight', {'enabled': true});
        break;
      case 'volume_up':
        await invokeNative('volumeUp');
        break;
      case 'volume_down':
        await invokeNative('volumeDown');
        break;
      case 'volume_mute':
        await invokeNative('volumeMute');
        break;
    }
  }

  Future<void> openExternalApp(String primaryUrl, {required String fallback}) async {
    final primary = Uri.parse(primaryUrl);
    if (await canLaunchUrl(primary)) {
      await launchUrl(primary, mode: LaunchMode.externalApplication);
      return;
    }
    await launchUrl(Uri.parse(fallback), mode: LaunchMode.externalApplication);
  }

  Future<void> invokeNative(String method, [dynamic arguments]) async {
    try {
      await nativeChannel.invokeMethod(method, arguments);
    } catch (_) {}
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      status = value;
    });
  }

  Widget buildCameraOverlay() {
    final controller = cameraController;
    if (!cameraEnabled || controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 16,
      right: 16,
      width: 130,
      height: 180,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(controller),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('BAKCHOD JARVIS'),
          actions: [
            Icon(isListening ? Icons.mic : Icons.mic_off, color: isListening ? Colors.greenAccent : Colors.grey),
            const SizedBox(width: 16),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(14)),
                    child: Text(status),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        return Align(
                          alignment: msg.role == ChatRole.user ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 5),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: msg.role == ChatRole.user ? Colors.deepPurple : Colors.grey.shade900,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Text(msg.text),
                          ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: messageController,
                            decoration: InputDecoration(
                              hintText: 'Jarvis ko gaali ya hukum de...',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: sendMessage,
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              buildCameraOverlay(),
            ],
          ),
        ),
      ),
    );
  }
}
