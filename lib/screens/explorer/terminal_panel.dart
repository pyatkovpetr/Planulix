import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../providers/app_state.dart';

class TerminalPanel extends StatefulWidget {
  final String cwd;
  const TerminalPanel({super.key, required this.cwd});
  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  late final Terminal _terminal;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _connected = false;
  bool _disposed = false;
  String? _error;

  static const _maxReconnectDelayMs = 30000;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 5000);
    _terminal.onOutput = (data) {
      _channel?.sink.add(jsonEncode({'type': 'input', 'data': data}));
    };
    _connect();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectAttempts++;
    final delayMs = (500 * (1 << (_reconnectAttempts - 1).clamp(0, 6)))
        .clamp(500, _maxReconnectDelayMs);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _connect();
    });
  }

  void _connect() {
    if (_disposed) return;
    // Tear down any previous connection so we never leak a subscription.
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _reconnectTimer?.cancel();

    try {
      final api = context.read<AppState>().api;
      final url = api.terminalWebSocketUrl(widget.cwd);

      // Note: web_socket_channel doesn't support custom headers on all platforms.
      // We pass the token via query if possible, otherwise the server must use query fallback.
      final uri = Uri.parse('$url&token=${Uri.encodeQueryComponent(api.authToken ?? '')}');
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;

      _sub = channel.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message as String);
            if (data['type'] == 'output') {
              _terminal.write(data['data'] as String);
            } else if (data['type'] == 'error') {
              _terminal.write('\r\n\x1b[31mError: ${data['data']}\x1b[0m\r\n');
            }
          } catch (_) {
            _terminal.write(message.toString());
          }
        },
        onError: (err) {
          if (!mounted) return;
          setState(() { _connected = false; _error = err.toString(); });
          _scheduleReconnect();
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _connected = false);
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _reconnectAttempts = 0;
      setState(() { _connected = true; _error = null; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      _scheduleReconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0a0f1a),
      child: Column(
        children: [
          // Terminal header
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: Color(0xFF0a0f1a),
              border: Border(bottom: BorderSide(color: Color(0xFF1a2234))),
            ),
            child: Row(
              children: [
                Icon(
                  _connected ? Icons.terminal : Icons.error_outline,
                  size: 12,
                  color: _connected ? const Color(0xFF22c55e) : const Color(0xFFef4444),
                ),
                const SizedBox(width: 6),
                Text(
                  _connected ? 'TERMINAL' : 'DISCONNECTED',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _connected ? const Color(0xFF22c55e) : const Color(0xFFef4444),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.cwd,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748b), fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!_connected)
                  IconButton(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh, size: 13, color: Color(0xFF94a3b8)),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, style: const TextStyle(color: Color(0xFFef4444), fontSize: 12)),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _connect, child: const Text('Reconnect')),
                        ],
                      ),
                    ),
                  )
                : TerminalView(
                    _terminal,
                    textStyle: const TerminalStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    theme: const TerminalTheme(
                      cursor: Color(0xFF8b5cf6),
                      selection: Color(0x408b5cf6),
                      foreground: Color(0xFFe2e8f0),
                      background: Color(0xFF0a0f1a),
                      black: Color(0xFF0f172a),
                      white: Color(0xFFe2e8f0),
                      red: Color(0xFFef4444),
                      green: Color(0xFF22c55e),
                      yellow: Color(0xFFf59e0b),
                      blue: Color(0xFF3b82f6),
                      magenta: Color(0xFF8b5cf6),
                      cyan: Color(0xFF06b6d4),
                      brightBlack: Color(0xFF334155),
                      brightRed: Color(0xFFfca5a5),
                      brightGreen: Color(0xFF86efac),
                      brightYellow: Color(0xFFfcd34d),
                      brightBlue: Color(0xFF93c5fd),
                      brightMagenta: Color(0xFFc4b5fd),
                      brightCyan: Color(0xFF67e8f9),
                      brightWhite: Color(0xFFf8fafc),
                      searchHitBackground: Color(0xFFf59e0b),
                      searchHitBackgroundCurrent: Color(0xFFf59e0b),
                      searchHitForeground: Color(0xFF0f172a),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
