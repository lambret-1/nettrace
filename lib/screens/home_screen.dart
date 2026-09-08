import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/capture_record.dart';
import '../models/filter_result.dart';
import '../proxy/proxy_server.dart';
import '../storage/capture_store.dart';
import '../utils/format_utils.dart';
import '../utils/har_exporter.dart';
import '../widgets/request_tile.dart';
import 'detail_screen.dart';
import 'filter_screen.dart';
import 'settings_screen.dart';

/// 主页 - 抓包列表
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProxyServer _proxy = ProxyServer();
  final CaptureStore _store = CaptureStore();

  List<CaptureRecord> _records = [];
  List<CaptureRecord> _filteredRecords = [];
  bool _isRunning = false;
  bool _showOnlyFavorites = false;
  String _searchQuery = '';
  String? _methodFilter;
  String? _statusFilter;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _store.init();

    // 设置代理回调
    _proxy.onRequestCaptured = (record) {
      _store.addRecord(record);
      if (mounted) {
        setState(() {
          _records.insert(0, record);
          _applyFilter();
        });
      }
    };
    _proxy.onStateChanged = (running) {
      if (mounted) setState(() => _isRunning = running);
    };

    // 加载历史记录
    _loadRecords();
  }

  void _loadRecords() {
    setState(() {
      _records = _store.getAllRecords();
      _applyFilter();
    });
  }

  void _applyFilter() {
    var filtered = _records;

    if (_showOnlyFavorites) {
      filtered = filtered.where((r) => _store.isFavorite(r.id)).toList();
    }

    if (_methodFilter != null) {
      filtered = filtered
          .where((r) => r.method.toUpperCase() == _methodFilter)
          .toList();
    }

    if (_statusFilter != null) {
      filtered = filtered.where((r) {
        final code = r.statusCode ?? 0;
        switch (_statusFilter) {
          case '2xx':
            return code >= 200 && code < 300;
          case '3xx':
            return code >= 300 && code < 400;
          case '4xx':
            return code >= 400 && code < 500;
          case '5xx':
            return code >= 500;
          default:
            return true;
        }
      }).toList();
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered
          .where((r) =>
              r.url.toLowerCase().contains(q) ||
              r.host.toLowerCase().contains(q))
          .toList();
    }

    _filteredRecords = filtered;
  }

  Future<void> _toggleProxy() async {
    if (_isRunning) {
      await _proxy.stop();
    } else {
      // 同步过滤配置
      _proxy.blacklist = _store.getBlacklist();
      _proxy.whitelist = _store.getWhitelist();
      _proxy.useWhitelist = _store.useWhitelist;

      final success = await _proxy.start();
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('代理启动失败，端口可能被占用')),
        );
      }
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空记录'),
        content: const Text('确定要清空所有抓包记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _store.clearAllRecords();
      if (mounted) {
        setState(() {
          _records = [];
          _filteredRecords = [];
        });
      }
    }
  }

  Future<void> _exportHar() async {
    if (_filteredRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可导出的记录')),
      );
      return;
    }

    final path = await HarExporter.exportToFile(_filteredRecords);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出到: $path')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NetTrace'),
        actions: [
          IconButton(
            icon: Icon(_showOnlyFavorites ? Icons.star : Icons.star_border),
            onPressed: () {
              setState(() {
                _showOnlyFavorites = !_showOnlyFavorites;
                _applyFilter();
              });
            },
            tooltip: '仅显示收藏',
          ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: () async {
              final result = await Navigator.push<FilterResult>(
                context,
                MaterialPageRoute(
                  builder: (_) => FilterScreen(
                    currentMethod: _methodFilter,
                    currentStatus: _statusFilter,
                  ),
                ),
              );
              if (result != null) {
                setState(() {
                  _methodFilter = result.method;
                  _statusFilter = result.status;
                  _applyFilter();
                });
              }
            },
            tooltip: '筛选',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'export':
                  _exportHar();
                  break;
                case 'clear':
                  _clearAll();
                  break;
                case 'settings':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.ios_share, size: 18),
                    SizedBox(width: 8),
                    Text('导出 HAR'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 18),
                    SizedBox(width: 8),
                    Text('清空记录'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('设置'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 代理状态横幅
          _buildStatusBar(),
          // 搜索栏
          _buildSearchBar(),
          // 记录列表
          Expanded(
            child: _filteredRecords.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    itemCount: _filteredRecords.length,
                    itemBuilder: (context, index) {
                      final record = _filteredRecords[index];
                      return RequestTile(
                        record: record,
                        isFavorite: _store.isFavorite(record.id),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DetailScreen(recordId: record.id),
                            ),
                          );
                        },
                        onLongPress: () {
                          _showRecordMenu(record);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      // 悬浮启动按钮
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleProxy,
        backgroundColor: _isRunning ? Colors.red : Theme.of(context).primaryColor,
        icon: Icon(_isRunning ? Icons.stop : Icons.play_arrow),
        label: Text(_isRunning ? '停止抓包' : '启动抓包'),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: _isRunning
          ? Colors.green.withOpacity(0.1)
          : Colors.grey.withOpacity(0.1),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isRunning ? Colors.green : Colors.grey,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _isRunning
                ? '抓包中  ${AppConstants.proxyHost}:${AppConstants.proxyPort}'
                : '代理未启动',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _isRunning ? Colors.green[700] : Colors.grey[600],
            ),
          ),
          const Spacer(),
          Text(
            '${_filteredRecords.length} 条记录',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索 URL 或域名...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                      _applyFilter();
                    });
                  },
                )
              : null,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onChanged: (value) {
          setState(() {
            _searchQuery = value;
            _applyFilter();
          });
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.network_check,
            size: 64,
            color: Colors.grey[300],
          ),
          const SizedBox(height: 16),
          Text(
            _isRunning ? '等待抓包数据...' : '点击下方按钮启动抓包',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 8),
          if (!_isRunning)
            Text(
              '然后在 WiFi 设置中配置代理\n${AppConstants.proxyHost}:${AppConstants.proxyPort}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[400],
              ),
            ),
        ],
      ),
    );
  }

  void _showRecordMenu(CaptureRecord record) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制 URL'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: record.url));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('URL 已复制')),
                );
              },
            ),
            ListTile(
              leading: Icon(
                _store.isFavorite(record.id) ? Icons.star : Icons.star_border,
              ),
              title: Text(_store.isFavorite(record.id) ? '取消收藏' : '收藏'),
              onTap: () {
                _store.toggleFavorite(record.id);
                Navigator.pop(ctx);
                _loadRecords();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除此记录', style: TextStyle(color: Colors.red)),
              onTap: () {
                _store.deleteRecord(record.id);
                Navigator.pop(ctx);
                _loadRecords();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
