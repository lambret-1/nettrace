/// NetTrace 全局常量
class AppConstants {
  static const String appName = 'NetTrace';
  static const String appVersion = '1.0.0';

  // 代理服务
  // 监听 0.0.0.0（全部网卡），其他APP才能通过局域网IP连接到代理
  // 127.0.0.1 仅本进程可访问，外部APP无法连接
  static const String proxyHost = '0.0.0.0';
  static const int proxyPort = 8888;

  // 存储
  static const String boxRecords = 'capture_records';
  static const String boxSettings = 'app_settings';
  static const String boxFavorites = 'favorites';
  static const String boxBlacklist = 'domain_blacklist';
  static const String boxWhitelist = 'domain_whitelist';

  // CA 证书
  static const String caCommonName = 'NetTrace Local CA';
  static const String caOrganization = 'NetTrace';
  static const int caValidityDays = 3650;
  static const int certValidityDays = 825;

  // 限制
  static const int maxRecordsInMemory = 500;
  static const int maxBodySize = 2 * 1024 * 1024; // 2MB
  static const int connectTimeout = 15000; // 15s
  static const int receiveTimeout = 30000; // 30s
}
