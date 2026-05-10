import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({
    super.key,
    required this.text,
    required this.baseStyle,
    this.pathRegex,
    this.onPathOpen,
    this.codeStyle,
  });

  final String text;
  final TextStyle baseStyle;
  final RegExp? pathRegex;
  final void Function(String path)? onPathOpen;
  final TextStyle? codeStyle;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) {
      return SelectableText('...', style: baseStyle);
    }
    final blocks = _splitFencedCode(text);
    if (blocks.length == 1 && !blocks.first.isCode) {
      return _plainText(context, blocks.first.text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          if (block.isCode)
            _codeBlock(context, block)
          else
            _plainText(context, block.text),
      ],
    );
  }

  Widget _plainText(BuildContext context, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    final regex = pathRegex;
    final onOpen = onPathOpen;
    if (regex == null || onOpen == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SelectableText(value.trim(), style: baseStyle),
      );
    }

    final matches = regex.allMatches(value).toList();
    if (matches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SelectableText(value.trim(), style: baseStyle),
      );
    }

    final children = <Widget>[];
    var lastEnd = 0;
    for (final m in matches) {
      if (m.start > lastEnd) {
        final chunk = value.substring(lastEnd, m.start).trim();
        if (chunk.isNotEmpty) {
          children.add(SelectableText(chunk, style: baseStyle));
        }
      }
      final path = m.group(0)!;
      children.add(_pathButton(path, onOpen));
      lastEnd = m.end;
    }
    if (lastEnd < value.length) {
      final chunk = value.substring(lastEnd).trim();
      if (chunk.isNotEmpty) {
        children.add(SelectableText(chunk, style: baseStyle));
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _pathButton(String path, void Function(String path) onOpen) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TextButton.icon(
        onPressed: () => onOpen(path),
        icon: const Icon(Icons.open_in_new, size: 14),
        label: Text(
          path,
          overflow: TextOverflow.ellipsis,
          maxLines: 3,
          style: const TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            decoration: TextDecoration.underline,
          ),
        ),
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF60a5fa),
          backgroundColor: const Color(0xFF0f172a),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }

  Widget _codeBlock(BuildContext context, _MarkdownBlock block) {
    final lang = block.language.trim();
    final style =
        codeStyle ??
        baseStyle.copyWith(
          fontFamily: 'monospace',
          color: const Color(0xFFe2e8f0),
          height: 1.45,
        );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0b1120),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lang.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      lang,
                      style: const TextStyle(
                        color: Color(0xFF94a3b8),
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy code',
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: block.text.trimRight()),
                    ),
                    icon: const Icon(Icons.copy, size: 14),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                  ),
                ],
              ),
            ),
          if (lang.isEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Copy code',
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: block.text.trimRight()),
                ),
                icon: const Icon(Icons.copy, size: 14),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(10, lang.isEmpty ? 0 : 6, 10, 10),
            child: SelectableText(block.text.trimRight(), style: style),
          ),
        ],
      ),
    );
  }
}

class _MarkdownBlock {
  const _MarkdownBlock.text(this.text) : isCode = false, language = '';
  const _MarkdownBlock.code(this.text, this.language) : isCode = true;

  final bool isCode;
  final String text;
  final String language;
}

List<_MarkdownBlock> _splitFencedCode(String input) {
  final blocks = <_MarkdownBlock>[];
  var cursor = 0;
  while (cursor < input.length) {
    final start = input.indexOf('```', cursor);
    if (start < 0) {
      final tail = input.substring(cursor);
      if (tail.isNotEmpty) blocks.add(_MarkdownBlock.text(tail));
      break;
    }
    if (start > cursor) {
      blocks.add(_MarkdownBlock.text(input.substring(cursor, start)));
    }
    var lineEnd = input.indexOf('\n', start + 3);
    if (lineEnd < 0) {
      blocks.add(_MarkdownBlock.text(input.substring(start)));
      break;
    }
    final language = input.substring(start + 3, lineEnd).trim();
    final end = input.indexOf('```', lineEnd + 1);
    if (end < 0) {
      blocks.add(_MarkdownBlock.code(input.substring(lineEnd + 1), language));
      break;
    }
    blocks.add(
      _MarkdownBlock.code(input.substring(lineEnd + 1, end), language),
    );
    cursor = end + 3;
  }
  return blocks.isEmpty ? [_MarkdownBlock.text(input)] : blocks;
}
