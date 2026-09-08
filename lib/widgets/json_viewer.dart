import 'dart:convert';

import 'package:flutter/material.dart';

/// JSON 格式化查看器 - 支持折叠/展开、语法高亮、复制
class JsonViewer extends StatefulWidget {
  final String jsonString;
  final bool copyEnabled;

  const JsonViewer({
    super.key,
    required this.jsonString,
    this.copyEnabled = true,
  });

  @override
  State<JsonViewer> createState() => _JsonViewerState();
}

class _JsonViewerState extends State<JsonViewer> {
  late dynamic _parsed;
  bool _parseError = false;
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(JsonViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jsonString != widget.jsonString) {
      _parse();
    }
  }

  void _parse() {
    try {
      _parsed = jsonDecode(widget.jsonString);
      _parseError = false;
    } catch (_) {
      _parseError = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_parseError) {
      return _buildRawText();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.copyEnabled) _buildToolbar(),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildNode(_parsed, '', 0),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Row(
      children: [
        TextButton.icon(
          onPressed: () {
            setState(() => _collapsed.clear());
          },
          icon: const Icon(Icons.unfold_more, size: 16),
          label: const Text('全部展开'),
        ),
        TextButton.icon(
          onPressed: () {
            setState(() {
              _collapsed.clear();
              _collapseAll(_parsed, '');
            });
          },
          icon: const Icon(Icons.unfold_less, size: 16),
          label: const Text('全部折叠'),
        ),
      ],
    );
  }

  void _collapseAll(dynamic node, String path) {
    if (node is Map) {
      _collapsed.add(path);
      for (final entry in node.entries) {
        _collapseAll(entry.value, '$path.${entry.key}');
      }
    } else if (node is List) {
      _collapsed.add(path);
      for (var i = 0; i < node.length; i++) {
        _collapseAll(node[i], '$path[$i]');
      }
    }
  }

  Widget _buildRawText() {
    return SelectableText(
      widget.jsonString,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.5,
      ),
    );
  }

  Widget _buildNode(dynamic node, String path, int depth) {
    if (node is Map) {
      return _buildObject(node, path, depth);
    } else if (node is List) {
      return _buildArray(node, path, depth);
    } else {
      return _buildPrimitive(node);
    }
  }

  Widget _buildObject(Map map, String path, int depth) {
    final isCollapsed = _collapsed.contains(path);
    final indent = depth * 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: indent),
            GestureDetector(
              onTap: () {
                setState(() {
                  if (isCollapsed) {
                    _collapsed.remove(path);
                  } else {
                    _collapsed.add(path);
                  }
                });
              },
              child: Icon(
                isCollapsed ? Icons.chevron_right : Icons.expand_more,
                size: 18,
                color: Colors.grey,
              ),
            ),
            Text(
              isCollapsed ? '{...} (${map.length} 项)' : '{',
              style: TextStyle(
                color: Colors.grey[600],
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ],
        ),
        if (!isCollapsed)
          ...map.entries.map((entry) {
            final childPath = '$path.${entry.key}';
            return Padding(
              padding: EdgeInsets.only(left: indent + 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '"${entry.key}"',
                    style: const TextStyle(
                      color: Color(0xFF7C3AED),
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                  const Text(
                    ': ',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                  if (entry.value is! Map && entry.value is! List)
                    _buildPrimitive(entry.value)
                  else
                    _buildNode(entry.value, childPath, 0),
                ],
              ),
            );
          }).toList(),
        if (!isCollapsed)
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: Text(
              '}',
              style: TextStyle(
                color: Colors.grey[600],
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildArray(List list, String path, int depth) {
    final isCollapsed = _collapsed.contains(path);
    final indent = depth * 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: indent),
            GestureDetector(
              onTap: () {
                setState(() {
                  if (isCollapsed) {
                    _collapsed.remove(path);
                  } else {
                    _collapsed.add(path);
                  }
                });
              },
              child: Icon(
                isCollapsed ? Icons.chevron_right : Icons.expand_more,
                size: 18,
                color: Colors.grey,
              ),
            ),
            Text(
              isCollapsed ? '[...] (${list.length} 项)' : '[',
              style: TextStyle(
                color: Colors.grey[600],
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ],
        ),
        if (!isCollapsed)
          ...list.asMap().entries.map((entry) {
            final childPath = '$path[${entry.key}]';
            return Padding(
              padding: EdgeInsets.only(left: indent + 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${entry.key}: ',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                  if (entry.value is! Map && entry.value is! List)
                    _buildPrimitive(entry.value)
                  else
                    _buildNode(entry.value, childPath, 0),
                ],
              ),
            );
          }).toList(),
        if (!isCollapsed)
          Padding(
            padding: EdgeInsets.only(left: indent),
            child: Text(
              ']',
              style: TextStyle(
                color: Colors.grey[600],
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPrimitive(dynamic value) {
    Color color;
    String text;

    if (value == null) {
      color = Colors.grey;
      text = 'null';
    } else if (value is bool) {
      color = const Color(0xFFDC2626);
      text = value.toString();
    } else if (value is num) {
      color = const Color(0xFF059669);
      text = value.toString();
    } else {
      color = const Color(0xFF2563EB);
      text = '"$value"';
    }

    return Flexible(
      child: SelectableText(
        text,
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: 13,
        ),
      ),
    );
  }
}
