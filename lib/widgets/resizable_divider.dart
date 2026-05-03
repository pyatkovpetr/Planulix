import 'package:flutter/material.dart';

/// A thin draggable divider for resizing panels horizontally
class ResizableDivider extends StatefulWidget {
  final ValueChanged<double> onDrag;
  final bool vertical; // true = horizontal drag (resizes width)
  const ResizableDivider({super.key, required this.onDrag, this.vertical = true});

  @override
  State<ResizableDivider> createState() => _ResizableDividerState();
}

class _ResizableDividerState extends State<ResizableDivider> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.vertical ? SystemMouseCursors.resizeLeftRight : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.vertical ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragEnd: widget.vertical ? (_) => setState(() => _dragging = false) : null,
        onHorizontalDragUpdate: widget.vertical ? (d) => widget.onDrag(d.delta.dx) : null,
        onVerticalDragStart: !widget.vertical ? (_) => setState(() => _dragging = true) : null,
        onVerticalDragEnd: !widget.vertical ? (_) => setState(() => _dragging = false) : null,
        onVerticalDragUpdate: !widget.vertical ? (d) => widget.onDrag(d.delta.dy) : null,
        child: widget.vertical
            ? SizedBox(
                width: 5,
                child: Center(
                  child: Container(
                    width: _hovering || _dragging ? 2 : 1,
                    color: _dragging
                        ? const Color(0xFF8b5cf6)
                        : _hovering
                            ? const Color(0xFF8b5cf6).withAlpha(150)
                            : const Color(0xFF1a2234),
                  ),
                ),
              )
            : SizedBox(
                height: 5,
                child: Center(
                  child: Container(
                    height: _hovering || _dragging ? 2 : 1,
                    color: _dragging
                        ? const Color(0xFF8b5cf6)
                        : _hovering
                            ? const Color(0xFF8b5cf6).withAlpha(150)
                            : const Color(0xFF1a2234),
                  ),
                ),
              ),
      ),
    );
  }
}
