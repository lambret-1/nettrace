import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../proxy/certificate_manager.dart';
import '../proxy/proxy_server.dart';
import '../storage/capture_store.dart';

/// 设置页 - CA 证书、代理配置、黑白名单、关于
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final CaptureStore _store = CaptureStore();
  final CertificateManager _certManager = CertificateManager();
  final ProxyServer _proxy = ProxyServer();

  bool _useWhitelist = false;
  bool _darkMode = false;
  bool _autoClear = false;
  final TextEditingController _domainController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    setState(() {
      _useWhitelist = _store.useWhitelist;
      _darkMode = _store.darkMode;
      _autoClear = _store.autoClearOnStart;
    });
  }

  Future<void> _installCaCert() async {
    try {
      final path = await _certManager.exportCaCertToFile();
      await Share.shareXFiles(
        [XFile(path)],
        text: 'NetTrace CA 证书 - 请在 iOS 设置中安装并信任',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出证书失败: $e')),
        );
      }
    }
  }

  void _showCaInstructions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('CA 证书安装指南'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('1. 点击「导出并安装证书」，选择「存储到文件」'),
              SizedBox(height: 8),
              Text('2. 打开 iOS 设置 → 通用 → VPN与设备管理'),
              SizedBox(height: 8),
              Text('3. 找到 NetTrace CA 描述文件，点击安装'),
              SizedBox(height: 8),
              Text('4. 安装完成后，进入 设置 → 通用 → 关于本机 → 证书信任设置'),
              SizedBox(height: 8),
              Text('5. 开启 NetTrace CA 证书的完全信任开关'),
              SizedBox(height: 8),
              Text('6. 返回 NetTrace，HTTPS 请求即可解密查看'),
              SizedBox(height: 16),
              Text(
                '注意：此证书仅用于本地抓包解密，请不要在不信任的网络中安装。',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  void _showProxyInstructions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('代理配置指南'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('1. 启动 NetTrace 抓包服务'),
              const SizedBox(height: 8),
              const Text('2. 打开 iOS 设置 → Wi-Fi → 点击已连接网络右侧 ⓘ'),
              const SizedBox(height: 8),
              const Text('3. 滚动到「配置代理」，选择「手动」'),
              const SizedBox(height: 8),
              Text('服务器: ${AppConstants.proxyHost}'),
              Text('端口: ${AppConstants.proxyPort}'),
              const SizedBox(height: 8),
              const Text('4. 保存后，所有 HTTP/HTTPS 请求将经过 NetTrace'),
              const SizedBox(height: 16),
              const Text(
                '注意：部分 APP 可能忽略系统代理设置，此类 APP 的流量无法被抓取。',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(
                ClipboardData(text: '${AppConstants.proxyHost}:${AppConstants.proxyPort}'),
              );
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('代理地址已复制')),
              );
            },
            child: const Text('复制代理地址'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showDomainDialog({bool isWhitelist = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isWhitelist ? '添加白名单域名' : '添加黑名单域名'),
        content: TextField(
          controller: _domainController,
          decoration: const InputDecoration(
            hintText: '例如: example.com',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () {
              _domainController.clear();
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final domain = _domainController.text.trim();
              if (domain.isNotEmpty) {
                if (isWhitelist) {
                  await _store.addWhitelist(domain);
                } else {
                  await _store.addBlacklist(domain);
                }
                _domainController.clear();
                if (mounted) {
                  Navigator.pop(ctx);
                  setState(() {});
                }
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Widget _buildDomainList({required bool isWhitelist}) {
    final domains = isWhitelist ? _store.getWhitelist() : _store.getBlacklist();
    final list = domains.toList()..sort();

    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Text(
            isWhitelist ? '暂无白名单域名' : '暂无黑名单域名',
            style: TextStyle(color: Colors.grey[500]),
          ),
        ),
      );
    }

    return Column(
      children: list.map((domain) {
        return Dismissible(
          key: Key(domain),
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          direction: DismissDirection.endToStart,
          onDismissed: (_) async {
            if (isWhitelist) {
              await _store.removeWhitelist(domain);
            } else {
              await _store.removeBlacklist(domain);
            }
            setState(() {});
          },
          child: ListTile(
            title: Text(domain),
            trailing: const Icon(Icons.chevron_right),
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // ---- HTTPS 解密 ----
          _buildSectionHeader('HTTPS 解密'),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('CA 证书状态'),
            subtitle: Text(_certManager.isReady ? '已生成' : '未初始化'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showCaInstructions,
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('导出并安装 CA 证书'),
            subtitle: const Text('解密 HTTPS 流量必需'),
            onTap: _installCaCert,
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('证书安装指南'),
            onTap: _showCaInstructions,
          ),

          // ---- 代理配置 ----
          _buildSectionHeader('代理配置'),
          ListTile(
            leading: const Icon(Icons.wifi_outlined),
            title: const Text('代理地址'),
            subtitle: Text('${AppConstants.proxyHost}:${AppConstants.proxyPort}'),
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: '${AppConstants.proxyHost}:${AppConstants.proxyPort}'),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')),
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('代理配置指南'),
            onTap: _showProxyInstructions,
          ),

          // ---- 域名过滤 ----
          _buildSectionHeader('域名过滤'),
          SwitchListTile(
            secondary: const Icon(Icons.filter_alt_outlined),
            title: const Text('使用白名单模式'),
            subtitle: const Text('开启后仅抓取白名单内域名'),
            value: _useWhitelist,
            onChanged: (value) {
              setState(() => _useWhitelist = value);
              _store.useWhitelist = value;
              _proxy.useWhitelist = value;
            },
          ),
          ExpansionTile(
            leading: const Icon(Icons.block_outlined),
            title: const Text('黑名单域名'),
            subtitle: const Text('这些域名的请求将被跳过（不解密）'),
            children: [
              _buildDomainList(isWhitelist: false),
              TextButton.icon(
                onPressed: () => _showDomainDialog(isWhitelist: false),
                icon: const Icon(Icons.add),
                label: const Text('添加黑名单域名'),
              ),
            ],
          ),
          ExpansionTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('白名单域名'),
            subtitle: const Text('白名单模式下仅抓取这些域名'),
            children: [
              _buildDomainList(isWhitelist: true),
              TextButton.icon(
                onPressed: () => _showDomainDialog(isWhitelist: true),
                icon: const Icon(Icons.add),
                label: const Text('添加白名单域名'),
              ),
            ],
          ),

          // ---- 通用设置 ----
          _buildSectionHeader('通用'),
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('深色模式'),
            value: _darkMode,
            onChanged: (value) {
              setState(() => _darkMode = value);
              _store.darkMode = value;
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cleaning_services_outlined),
            title: const Text('启动时自动清空记录'),
            value: _autoClear,
            onChanged: (value) {
              setState(() => _autoClear = value);
              _store.autoClearOnStart = value;
            },
          ),

          // ---- 关于 ----
          _buildSectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('NetTrace'),
            subtitle: Text('版本 1.0.0'),
          ),
          const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('开源协议'),
            subtitle: Text('MIT License'),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('隐私声明'),
            subtitle: Text('所有数据仅存储在本地，不上传任何服务器'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.grey[600],
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _domainController.dispose();
    super.dispose();
  }
}
