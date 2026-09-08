import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/capture_record.dart';
import '../storage/capture_store.dart';
import '../utils/format_utils.dart';
import '../widgets/json_viewer.dart';
import '../widgets/status_badge.dart';

/// 抓包详情页 - 展示请求/响应完整信息
class DetailScreen extends StatefulWidget {
  final String recordId;

  const DetailScreen({super.key, required this.recordId});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen>
    with SingleTickerProviderStateMixin {
  final CaptureStore _store = CaptureStore();
  CaptureRecord? _record;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadRecord();
  }

  void _loadRecord() {
    setState(() {
      _record = _store.getRecord(widget.recordId);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_record == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('详情')),
        body: const Center(child: Text('记录不存在')),
      );
    }

    final record = _record!;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${record.method} ${FormatUtils.truncateUrl(record.path, maxLength: 30)}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _store.isFavorite(record.id) ? Icons.star : Icons.star_border,
              color: _store.isFavorite(record.id) ? Colors.amber : null,
            ),
            onPressed: () {
              _store.toggleFavorite(record.id);
              _loadRecord();
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: record.url));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URL 已复制')),
              );
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: '概览'),
            Tab(text: '请求'),
            Tab(text: '响应'),
            Tab(text: 'Headers'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildOverviewTab(record),
          _buildRequestTab(record),
          _buildResponseTab(record),
          _buildHeadersTab(record),
        ],
      ),
    );
  }

  // ---- 概览 Tab ----
  Widget _buildOverviewTab(CaptureRecord record) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildInfoCard(
          title: '基本信息',
          children: [
            _buildInfoRow('请求方法', record.method),
            _buildInfoRow('状态码', record.statusText),
            _buildInfoRow('协议', record.isHttps ? 'HTTPS' : 'HTTP'),
            _buildInfoRow('耗时', FormatUtils.formatDuration(record.duration)),
            _buildInfoRow('时间', FormatUtils.formatDateTime(record.timestamp)),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoCard(
          title: 'URL 信息',
          children: [
            _buildInfoRow('完整 URL', record.url, selectable: true),
            _buildInfoRow('域名', record.host),
            _buildInfoRow('路径', record.path),
            _buildInfoRow('端口', record.request.port?.toString() ?? (record.isHttps ? '443' : '80')),
          ],
        ),
        const SizedBox(height: 16),
        _buildInfoCard(
          title: '数据大小',
          children: [
            _buildInfoRow('请求大小', FormatUtils.formatBytes(record.requestSize)),
            _buildInfoRow('响应大小', FormatUtils.formatBytes(record.responseSize)),
            _buildInfoRow('总计', FormatUtils.formatBytes(record.requestSize + record.responseSize)),
          ],
        ),
        if (record.error != null) ...[
          const SizedBox(height: 16),
          _buildInfoCard(
            title: '错误信息',
            children: [
              _buildInfoRow('错误', record.error!, selectable: true),
            ],
          ),
        ],
      ],
    );
  }

  // ---- 请求 Tab ----
  Widget _buildRequestTab(CaptureRecord record) {
    final req = record.request;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (req.queryParams != null && req.queryParams!.isNotEmpty) ...[
          _buildSectionTitle('Query 参数'),
          _buildKeyValueTable(req.queryParams!),
          const SizedBox(height: 16),
        ],
        _buildSectionTitle('请求 Body'),
        if (req.body == null || req.body!.isEmpty)
          _buildEmptyBody('无请求 Body')
        else if (req.isJson)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: JsonViewer(jsonString: req.bodyAsString),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                req.bodyAsString,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---- 响应 Tab ----
  Widget _buildResponseTab(CaptureRecord record) {
    final res = record.response;
    if (res == null) {
      return const Center(child: Text('无响应数据'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            StatusBadge(statusCode: res.statusCode),
            const SizedBox(width: 12),
            Text(
              '${res.statusCode} ${res.reasonPhrase ?? ''}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _buildSectionTitle('响应 Body'),
        if (res.body == null || res.body!.isEmpty)
          _buildEmptyBody('无响应 Body')
        else if (res.isJson)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: JsonViewer(jsonString: res.bodyAsString),
            ),
          )
        else if (res.isImage)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text('[图片数据]')),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                res.bodyAsString,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---- Headers Tab ----
  Widget _buildHeadersTab(CaptureRecord record) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionTitle('请求 Headers'),
        _buildKeyValueTable(record.request.headers),
        const SizedBox(height: 24),
        _buildSectionTitle('响应 Headers'),
        if (record.response != null)
          _buildKeyValueTable(record.response!.headers)
        else
          _buildEmptyBody('无响应 Headers'),
      ],
    );
  }

  // ---- 通用组件 ----

  Widget _buildInfoCard({
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool selectable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
              ),
            ),
          ),
          Expanded(
            child: selectable
                ? SelectableText(
                    value,
                    style: const TextStyle(fontSize: 13),
                  )
                : Text(
                    value,
                    style: const TextStyle(fontSize: 13),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildKeyValueTable(Map<String, String> data) {
    if (data.isEmpty) return _buildEmptyBody('无数据');

    return Card(
      child: Column(
        children: data.entries.map((entry) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Colors.grey.shade200,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 140,
                  child: Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.purple[700],
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    entry.value,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmptyBody(String text) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}
