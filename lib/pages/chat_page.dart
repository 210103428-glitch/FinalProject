import 'dart:io'; 
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'call_page.dart';


class UserProfile {
  final String name;
  final String avatarBase64;
  final bool online;

  UserProfile({
    required this.name,
    required this.avatarBase64,
    required this.online,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'avatar': avatarBase64,
    'online': online,
  };
}

class ChatPage extends StatefulWidget {
  final bool isHost;
  const ChatPage({super.key, required this.isHost});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final List<dynamic> messages = [];
  final TextEditingController _messageController = TextEditingController();

  ServerSocket? server;
  Socket? socket;
  RawDatagramSocket? discoverySocket;

  Uint8List buffer = Uint8List(0);
  int? expectedImageSize;

  @override
  void initState() {
    super.initState();
    widget.isHost ? _startHost() : _startGuest();
    
    final profile = UserProfile(
    name: widget.isHost ? 'Host' : 'Guest',
    avatarBase64: '',
    online: true,
  );
    }
// img
  Future<void> sendImage() async {
    if (socket == null) return;

    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    final bytes = await image.readAsBytes();
    final header = '[IMG]${bytes.length}\n';

    socket!.add(utf8.encode(header));
    socket!.add(bytes);

    setState(() => messages.add({'isMe': true, 'content': bytes}));
  }

//host
  Future<void> _startHost() async {
    await _startDiscoveryResponder();

    server = await ServerSocket.bind(InternetAddress.anyIPv4, 4567);
    setState(() => messages.add({'isMe': false, 'content': '🟢 Хост запущен'}));

    server!.listen((client) {
      socket = client;
      setState(() => messages.add({'isMe': false, 'content': '✅ Гость подключился'}));
      _listenSocket();
      socket!.done.then((_) => _handleDisconnect());
    });
  }

  Future<void> _startDiscoveryResponder() async {
    discoverySocket =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8888);

    discoverySocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = discoverySocket!.receive();
        if (dg == null) return;

        if (String.fromCharCodes(dg.data) == 'WHO_IS_P2P_CHAT_HOST') {
          discoverySocket!.send(
            'P2P_CHAT_HOST'.codeUnits,
            dg.address,
            dg.port,
          );
        }
      }
    });
  }
// Гость
  Future<void> _startGuest() async {
    setState(() => messages.add({'isMe': false, 'content': '🔍 Поиск хоста...'}));
    final hostIP = await _discoverHost();

    if (hostIP == null) {
      setState(() => messages.add({'isMe': false, 'content': '❌ Хост не найден'}));
      return;
    }

    socket = await Socket.connect(hostIP, 4567);
    setState(() => messages.add({'isMe': false, 'content': '🔗 Подключено к $hostIP'}));

    _listenSocket();
    socket!.done.then((_) => _handleDisconnect());
  }

  Future<String?> _discoverHost() async {
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.broadcastEnabled = true;

    s.send(
      'WHO_IS_P2P_CHAT_HOST'.codeUnits,
      InternetAddress('255.255.255.255'),
      8888,
    );

    try {
      await for (var event in s.timeout(
        const Duration(seconds: 5),
        onTimeout: (sink) => sink.close(),
      )) {
        if (event == RawSocketEvent.read) {
          final dg = s.receive();
          if (dg == null) continue;

          if (String.fromCharCodes(dg.data).startsWith('P2P_CHAT_HOST')) {
            s.close();
            return dg.address.address;
          }
        }
      }
    } catch (_) {}

    s.close();
    return null;
  }
  
//пакет
  void _listenSocket() {
    socket!.listen((data) {
      buffer = Uint8List.fromList([...buffer, ...data]);

      while (true) {
        if (buffer.isEmpty) return;
        final idx = buffer.indexOf(10);
        if (idx == -1) return;

        final header = utf8.decode(buffer.sublist(0, idx), allowMalformed: false);

        if (header.startsWith('TXT:')) {
          final len = int.parse(header.substring(4));
          if (buffer.length - idx - 1 < len) return; 

          final msgBytes = buffer.sublist(idx + 1, idx + 1 + len);
          final msg = utf8.decode(msgBytes);
          setState(() => messages.add({'isMe': false, 'content': msg}));
          buffer = buffer.sublist(idx + 1 + len);
        } 
        else if (header.startsWith('[IMG]')) {
          final len = int.parse(header.substring(5));
          if (buffer.length - idx - 1 < len) return;
          final imgBytes = buffer.sublist(idx + 1, idx + 1 + len);
          setState(() => messages.add({'isMe': false, 'content': imgBytes}));
          buffer = buffer.sublist(idx + 1 + len);
        } 
        else if (header.startsWith('JSON:')) {
          final len = int.parse(header.substring(5));
          if (buffer.length - idx - 1 < len) return;

          final jsonStr = utf8.decode(buffer.sublist(idx + 1, idx + 1 + len));
          final data = jsonDecode(jsonStr);

          if (data['type'] == 'profile') {
          }

          buffer = buffer.sublist(idx + 1 + len);
        }

        else {
          
          buffer = buffer.sublist(idx + 1);
        }
      }
    }, onDone: _handleDisconnect, onError: (_) => _handleDisconnect());
  }


  void _handleDisconnect() {
    setState(() => messages.add({'isMe': false, 'content': '❌ Соединение прервано'}));
    socket = null;
  }
  

  void sendProfile(UserProfile profile) {
  socket!.write(jsonEncode({
    'type': 'profile',
    'data': profile.toJson(),
  }) + '\n');
}

// Chat
  void _sendMessage() {
    if (socket == null || _messageController.text.isEmpty) return;

    final msg = _messageController.text;
    try {
      final bytes = utf8.encode(msg);
      final header = 'TXT:${bytes.length}\n';
      socket!.add(utf8.encode(header));
      socket!.add(bytes);

      setState(() {
        messages.add({'isMe': true, 'content': msg});
        _messageController.clear();
      });
    } catch (_) {
      setState(() => messages.add({'isMe': false, 'content': '❌ Сообщение не отправлено'}));
    }
  }

  
  void sendSignal(Map<String, dynamic> msg) {
    final jsonStr = jsonEncode(msg);
    final length = utf8.encode(jsonStr).length;
    socket!.add(utf8.encode('$length\n'));
    socket!.add(utf8.encode(jsonStr));
  }

  void listenSocket(Uint8List data) {
    buffer = Uint8List.fromList([...buffer, ...data]);
    while (buffer.isNotEmpty) {
      final idx = buffer.indexOf(10);
      if (idx == -1) break; 
      final len = int.parse(utf8.decode(buffer.sublist(0, idx)));
      if (buffer.length < idx + 1 + len) break;
      final jsonStr = utf8.decode(buffer.sublist(idx + 1, idx + 1 + len));
      final msg = jsonDecode(jsonStr);
      buffer = buffer.sublist(idx + 1 + len);
    }
  }


  void _openImage(Uint8List imgBytes) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Center(
              child: InteractiveViewer(
                panEnabled: true,
                minScale: 1,
                maxScale: 5,
                child: Image.memory(imgBytes),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    socket?.close();
    server?.close();
    discoverySocket?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isHost ? 'Host' : 'Guest'),
        actions: [
          IconButton(
            icon:  Icon(Icons.call),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CallPage(
                    isHost: widget.isHost,
                    socket: socket, 
                  ),
                ),
              );
            },
          ),

        ],
      ),
      body: Container(
        decoration:  BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE0F7FA), Color(0xFFB2EBF2)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: messages.length,
                itemBuilder: (_, index) {
                  final msg = messages[index];
                  final ol = false;
                  final isMe = msg['isMe'] as bool;
                  final content = msg['content'];

                  if (content is String) {
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin:  EdgeInsets.symmetric(horizontal: 8.1, vertical: 4),
                        padding:  EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isMe ? const Color.fromARGB(255, 130, 224, 135) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(content,overflow: TextOverflow.ellipsis, style:  TextStyle(fontSize: 16)),
                      ),
                    );



                    





                  }

                  if (content is Uint8List) {
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: () => _openImage(content),
                        child: Container(
                          margin:  EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Image.memory(
                            content,
                            width: 151,
                            height: 151,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    );
                  }

                  return const SizedBox();
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.white,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.image),
                    onPressed: sendImage,
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(25),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: _messageController,
                        decoration:  InputDecoration(
                          hintText: 'Введите сообщение...',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),],
        ),
      ),
    );
  }
}
