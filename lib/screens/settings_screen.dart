import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
  CaStatus _caStatus = CaStatus.none;
  String _appVersion = '加载中...';
  final TextEditingController _domainController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadCaStatus();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    }
  }

  Future<void> _loadCaStatus() async {
    final status = await _certManager.getCaStatus();
    if (mounted) {
      setState(() => _caStatus = status);
    }
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
      final path = await _certManager.exportCaMobileConfig();
      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/x-apple-aspen-config')],
        subject: 'NetTrace CA 证书',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出证书失败: $e')),
        );
      }
    }
  }

  /// 导出原始 .cer(DER) 证书文件（兜底方案）
  Future<void> _installCaCertDer() async {
    try {
      final path = await _certManager.exportCaCertDer();
      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/pkix-cert')],
        subject: 'NetTrace CA 证书 (.cer)',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出证书失败: $e')),
        );
      }
    }
  }

  /// 用户确认已完成证书安装与信任
  Future<void> _confirmCaTrusted() async {
    await _certManager.setCaStatus(CaStatus.fullyTrusted);
    if (mounted) {
      setState(() => _caStatus = CaStatus.fullyTrusted);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已确认，HTTPS 解密已启用')),
      );
    }
  }

  /// 重置 CA 证书
  Future<void> _resetCa() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置 CA 证书'),
        content: const Text('确定要重置 CA 证书吗？重置后需要重新生成、安装并信任证书。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重置', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _certManager.resetCA();
      // 重新初始化生成新证书
      await _certManager.init();
      await _certManager.setCaStatus(CaStatus.generated);
      if (mounted) {
        setState(() => _caStatus = CaStatus.generated);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CA 证书已重置，请重新安装并信任')),
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
              Text('1. 点击「导出 CA 证书」，选择「存储到文件」或 AirDrop 到本机'),
              SizedBox(height: 8),
              Text('2. 系统会提示「已下载描述文件」'),
              SizedBox(height: 8),
              Text('3. 打开 iOS 设置 → 通用 → VPN与设备管理'),
              SizedBox(height: 8),
              Text('4. 找到 NetTrace CA 描述文件，点击安装'),
              SizedBox(height: 8),
              Text('5. 安装完成后，进入 设置 → 通用 → 关于本机 → 证书信任设置'),
              SizedBox(height: 8),
              Text('6. 开启 NetTrace CA 证书的完全信任开关'),
              SizedBox(height: 8),
              Text('7. 返回 NetTrace，点击「我已完成安装与信任」'),
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
          _buildCaStatusCard(),

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
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('NetTrace'),
            subtitle: Text('版本 $_appVersion'),
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

  /// CA 证书状态卡片 - 根据 CaStatus 显示不同内容
  Widget _buildCaStatusCard() {
    IconData icon;
    String title;
    String subtitle;
    Color color;
    List<Widget> actions = [];

    switch (_caStatus) {
      case CaStatus.none:
        icon = Icons.error_outline;
        title = 'CA 证书未生成';
        subtitle = 'APP 启动时会自动生成，请稍候或重启 APP';
        color = Colors.grey;
        break;
      case CaStatus.generated:
        icon = Icons.warning_amber_outlined;
        title = 'CA 证书已在 APP 本地生成';
        subtitle = '尚未安装到 iOS 系统，HTTPS 无法解密';
        color = Colors.orange;
        actions = [
          ElevatedButton.icon(
            onPressed: _installCaCert,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('导出 CA 证书 (推荐)'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _installCaCertDer,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            label: const Text('导出 .cer 原始证书 (兜底)'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _showCaInstructions,
            icon: const Icon(Icons.help_outline, size: 18),
            label: const Text('查看安装指南'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _confirmCaTrusted,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('我已完成安装与信任'),
          ),
        ];
        break;
      case CaStatus.installedNotTrust:
        icon = Icons.warning_amber_outlined;
        title = 'CA 证书已安装，但未开启信任';
        subtitle = '请前往 设置 → 关于本机 → 证书信任设置 开启开关';
        color = Colors.orange;
        actions = [
          OutlinedButton.icon(
            onPressed: _showCaInstructions,
            icon: const Icon(Icons.help_outline, size: 18),
            label: const Text('查看信任设置指南'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _confirmCaTrusted,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('我已开启完全信任'),
          ),
        ];
        break;
      case CaStatus.fullyTrusted:
        icon = Icons.verified_user;
        title = 'CA 证书已生成 + 系统已信任';
        subtitle = 'HTTPS 解密已启用，可以正常抓包';
        color = Colors.green;
        actions = [
          OutlinedButton.icon(
            onPressed: _installCaCert,
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('重新导出 CA 证书'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _resetCa,
            icon: const Icon(Icons.refresh, size: 18, color: Colors.red),
            label: const Text('重置 CA 证书', style: TextStyle(color: Colors.red)),
          ),
        ];
        break;
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_caStatus == CaStatus.generated ||
                _caStatus == CaStatus.installedNotTrust) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '⚠️ 重要：仅安装描述文件不够，还必须在「设置 → 通用 → 关于本机 → 证书信任设置」中开启 NetTrace CA 的完全信任开关，否则 HTTPS 依旧无法解密。',
                  style: TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              ...actions,
            ],
          ],
        ),
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
