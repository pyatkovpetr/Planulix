import 'dart:convert';

/// Human-readable extraction from Claude / Anthropic API-style `content`:
/// plain string or a list of blocks (`text`, `thinking`, `tool_use`, …).
///
/// Claude Code JSONL often includes `thinking` and `tool_use` without adjacent
/// `text` blocks — the chat UI previously showed only `type == text`, hence
/// empty bubbles rendered as «…».
String messageContentPlainText(dynamic content, {int toolDetailMaxChars = 500}) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final parts = <String>[];

    void addRaw(String s) {
      final t = s.trim();
      if (t.isNotEmpty) parts.add(t);
    }

    for (final item in content) {
      if (item is String) {
        addRaw(item);
        continue;
      }
      if (item is! Map) continue;
      final typ = (item['type'] ?? '').toString();
      switch (typ) {
        case 'text':
          addRaw('${item['text'] ?? ''}');
          break;
        case 'thinking':
          final thRaw = item['thinking'] ?? item['text'] ?? '';
          final th = thRaw.toString().trim();
          if (th.isNotEmpty) {
            parts.add('[thinking]\n$th');
          }
          break;
        case 'redacted_thinking':
          parts.add('[thinking — redacted]');
          break;
        case 'tool_use':
          final name = (item['name'] ?? 'tool').toString();
          final input = item['input'];
          var detail = '';
          if (input != null) {
            var s = input is Map || input is List
                ? jsonEncode(input)
                : input.toString();
            if (s.length > toolDetailMaxChars) {
              s = '${s.substring(0, toolDetailMaxChars)}…';
            }
            detail = s.trim();
          }
          if (detail.isNotEmpty) {
            parts.add('[tool_use: $name]\n$detail');
          } else {
            parts.add('[tool_use: $name]');
          }
          break;
        case 'tool_result':
          final inner = messageContentPlainText(
            item['content'],
            toolDetailMaxChars: toolDetailMaxChars,
          ).trim();
          if (inner.isNotEmpty) parts.add(inner);
          break;
        default:
          break;
      }
    }
    return parts.join('\n\n');
  }
  return content.toString();
}
