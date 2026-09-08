import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../core/constants.dart';

/// CA 证书安装状态
///
/// iOS 沙盒限制：APP 无法直接读取系统证书库判断信任状态，
/// 因此「已安装并信任」需要用户手动确认。
enum CaStatus {
  /// 未生成：APP 本地还没有 CA 证书文件
  none,

  /// 已生成：APP 本地已生成 CA 证书文件，但尚未安装到 iOS 系统
  generated,

  /// 已安装未信任：描述文件已安装，但未开启「证书信任设置」开关
  installedNotTrust,

  /// 完全信任：系统已安装并开启完全信任，可以解密 HTTPS
  fullyTrusted,
}

/// CA 证书管理器 - 手动构造 X.509 证书 ASN.1 DER
///
/// pointycastle 4.0，私钥用 JSON 持久化（避免 ASN1 解析器版本差异），
/// CRT 参数手动计算，签名用 RSASignature.bytes。
class CertificateManager {
  static final CertificateManager _instance = CertificateManager._internal();
  factory CertificateManager() => _instance;
  CertificateManager._internal();

  RSAPrivateKey? _caPrivateKey;
  RSAPublicKey? _caPublicKey;
  String? _caCertPem;
  final Map<String, _CachedCert> _certCache = {};

  bool get isReady => _caPrivateKey != null && _caCertPem != null;

  // ---- CA 状态管理 ----

  /// 获取 CA 证书安装状态（从本地状态文件读取）
  Future<CaStatus> getCaStatus() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final statusFile = File('${dir.path}/ca_status.json');
      if (!statusFile.existsSync()) {
        // 状态文件不存在，检查证书文件是否存在
        final exists = await isCaFileExists();
        return exists ? CaStatus.generated : CaStatus.none;
      }
      final index = int.parse(statusFile.readAsStringSync().trim());
      if (index < 0 || index >= CaStatus.values.length) {
        return CaStatus.none;
      }
      return CaStatus.values[index];
    } catch (_) {
      return CaStatus.none;
    }
  }

  /// 设置 CA 证书安装状态
  Future<void> setCaStatus(CaStatus status) async {
    final dir = await getApplicationDocumentsDirectory();
    final statusFile = File('${dir.path}/ca_status.json');
    statusFile.writeAsStringSync(status.index.toString());
  }

  /// 检查本地 CA 证书文件是否已生成
  Future<bool> isCaFileExists() async {
    final dir = await getApplicationDocumentsDirectory();
    final certFile = File('${dir.path}/ca_cert.pem');
    final keyFile = File('${dir.path}/ca_key.json');
    return certFile.existsSync() && keyFile.existsSync();
  }

  /// 重置 CA 证书：删除本地证书、私钥和状态文件
  Future<void> resetCA() async {
    final dir = await getApplicationDocumentsDirectory();
    final certFile = File('${dir.path}/ca_cert.pem');
    final keyFile = File('${dir.path}/ca_key.json');
    final statusFile = File('${dir.path}/ca_status.json');
    if (certFile.existsSync()) certFile.deleteSync();
    if (keyFile.existsSync()) keyFile.deleteSync();
    if (statusFile.existsSync()) statusFile.deleteSync();
    _caPrivateKey = null;
    _caPublicKey = null;
    _caCertPem = null;
    _certCache.clear();
  }

  // OID 常量
  static const String _oidSha256WithRsa = '1.2.840.113549.1.1.11';
  static const String _oidRsaEncryption = '1.2.840.113549.1.1.1';
  static const String _oidCommonName = '2.5.4.3';
  static const String _oidOrganization = '2.5.4.10';
  static const String _oidBasicConstraints = '2.5.29.19';
  static const String _oidKeyUsage = '2.5.29.15';
  static const String _oidExtendedKeyUsage = '2.5.29.37';
  static const String _oidSubjectAltName = '2.5.29.17';
  static const String _oidServerAuth = '1.3.6.1.5.5.7.3.1';

  // ASN.1 标签
  static const int _tagBoolean = 0x01;
  static const int _tagInteger = 0x02;
  static const int _tagBitString = 0x03;
  static const int _tagOctetString = 0x04;
  static const int _tagNull = 0x05;
  static const int _tagOid = 0x06;
  static const int _tagUtf8String = 0x0C;
  static const int _tagIa5String = 0x16;
  static const int _tagUtcTime = 0x17;
  static const int _tagSequence = 0x30;
  static const int _tagSet = 0x31;

  /// 初始化：加载或生成 CA 根证书
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final certFile = File('${dir.path}/ca_cert.pem');
    final keyFile = File('${dir.path}/ca_key.json');

    if (certFile.existsSync() && keyFile.existsSync()) {
      try {
        _caCertPem = certFile.readAsStringSync();
        final keyJson = jsonDecode(keyFile.readAsStringSync()) as Map<String, dynamic>;
        _caPrivateKey = _privateKeyFromJson(keyJson);
        _caPublicKey = RSAPublicKey(
          BigInt.parse(keyJson['n'] as String),
          BigInt.parse(keyJson['e'] as String),
        );
        return;
      } catch (_) {}
    }
    _generateCa();
    certFile.writeAsStringSync(caCertPem);
    keyFile.writeAsStringSync(jsonEncode(_privateKeyToJson(_caPrivateKey!, _caPublicKey!)));
  }

  /// 生成自签 CA 根证书
  void _generateCa() {
    final keyPair = _generateRsaKeyPair();
    _caPrivateKey = keyPair.privateKey as RSAPrivateKey;
    _caPublicKey = keyPair.publicKey as RSAPublicKey;

    final now = DateTime.now().toUtc();
    final tbsDer = _buildTbsCertificate(
      serialNumber: _randomSerial(),
      issuerCn: AppConstants.caCommonName,
      issuerOrg: AppConstants.caOrganization,
      subjectCn: AppConstants.caCommonName,
      subjectOrg: AppConstants.caOrganization,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: AppConstants.caValidityDays)),
      publicKey: _caPublicKey!,
      isCa: true,
    );

    final signature = _signSha256WithRsa(tbsDer, _caPrivateKey!);
    final certDer = _buildCertificate(tbsDer, signature);
    _caCertPem = _derToPem(certDer, 'CERTIFICATE');
  }

  /// 为指定域名签发动态证书（带缓存）
  _CachedCert getCertificateForHost(String host) {
    final cached = _certCache[host];
    if (cached != null && !cached.isExpired) return cached;

    final keyPair = _generateRsaKeyPair();
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;

    final now = DateTime.now().toUtc();
    final tbsDer = _buildTbsCertificate(
      serialNumber: _randomSerial(),
      issuerCn: AppConstants.caCommonName,
      issuerOrg: AppConstants.caOrganization,
      subjectCn: host,
      subjectOrg: AppConstants.caOrganization,
      notBefore: now.subtract(const Duration(days: 1)),
      notAfter: now.add(const Duration(days: AppConstants.certValidityDays)),
      publicKey: publicKey,
      isCa: false,
      dnsNames: [host, '*.$host'],
      ipAddresses: _isIpAddress(host) ? [host] : null,
    );

    final signature = _signSha256WithRsa(tbsDer, _caPrivateKey!);
    final certDer = _buildCertificate(tbsDer, signature);

    final cachedCert = _CachedCert(
      certPem: _derToPem(certDer, 'CERTIFICATE'),
      keyPem: _encodePrivateKeyPem(privateKey, publicKey),
      expiresAt: DateTime.now().add(const Duration(days: AppConstants.certValidityDays)),
    );
    _certCache[host] = cachedCert;
    return cachedCert;
  }

  SecurityContext createSecurityContextForHost(String host) {
    final cert = getCertificateForHost(host);
    final context = SecurityContext();
    context.useCertificateChainBytes(utf8.encode(cert.certPem));
    context.usePrivateKeyBytes(utf8.encode(cert.keyPem));
    return context;
  }

  String get caCertPem => _caCertPem ?? '';

  String get caPrivateKeyPem {
    if (_caPrivateKey == null || _caPublicKey == null) return '';
    return _encodePrivateKeyPem(_caPrivateKey!, _caPublicKey!);
  }

  Future<String> exportCaCertToFile() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/NetTrace_CA.crt');
    file.writeAsStringSync(caCertPem);
    return file.path;
  }

  /// 导出 CA 证书为 iOS .mobileconfig 配置描述文件
  ///
  /// .mobileconfig 会被 iOS 直接识别为配置文件，引导用户安装，
  /// 比 .crt 需要手动去"文件"APP 点击的体验好很多。
  Future<String> exportCaMobileConfig() async {
    // PEM 转 DER（去掉头尾，base64 解码）
    final pemLines = caCertPem
        .split('\n')
        .where((line) => !line.startsWith('-----'))
        .join();
    final derBytes = base64.decode(pemLines);
    final derBase64 = base64.encode(derBytes);

    // 生成随机 UUID
    final uuid1 = _generateUuid();
    final uuid2 = _generateUuid();

    final mobileConfig = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>PayloadContent</key>
\t<array>
\t\t<dict>
\t\t\t<key>PayloadCertificateFileName</key>
\t\t\t<string>NetTraceCA.cer</string>
\t\t\t<key>PayloadContent</key>
\t\t\t<data>
$derBase64
\t\t\t</data>
\t\t\t<key>PayloadDescription</key>
\t\t\t<string>NetTrace CA 根证书，用于 HTTPS 抓包解密</string>
\t\t\t<key>PayloadDisplayName</key>
\t\t\t<string>NetTrace CA</string>
\t\t\t<key>PayloadIdentifier</key>
\t\t\t<string>com.nettrace.ca.cert</string>
\t\t\t<key>PayloadType</key>
\t\t\t<string>com.apple.security.root</string>
\t\t\t<key>PayloadUUID</key>
\t\t\t<string>$uuid1</string>
\t\t\t<key>PayloadVersion</key>
\t\t\t<integer>1</integer>
\t\t</dict>
\t</array>
\t<key>PayloadDescription</key>
\t<string>NetTrace CA 根证书安装描述文件，安装后需在"证书信任设置"中开启完全信任</string>
\t<key>PayloadDisplayName</key>
\t<string>NetTrace CA 证书</string>
\t<key>PayloadIdentifier</key>
\t<string>com.nettrace.ca.profile</string>
\t<key>PayloadRemovalDisallowed</key>
\t<false/>
\t<key>PayloadType</key>
\t<string>Configuration</string>
\t<key>PayloadUUID</key>
\t<string>$uuid2</string>
\t<key>PayloadVersion</key>
\t<integer>1</integer>
</dict>
</plist>''';

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/NetTrace_CA.mobileconfig');
    file.writeAsStringSync(mobileConfig);
    return file.path;
  }

  /// 生成随机 UUID（格式：xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx）
  String _generateUuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}-'
        '${hex(bytes[4])}${hex(bytes[5])}-'
        '${hex(bytes[6])}${hex(bytes[7])}-'
        '${hex(bytes[8])}${hex(bytes[9])}-'
        '${hex(bytes[10])}${hex(bytes[11])}${hex(bytes[12])}${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
  }

  // =====================================================================
  // 私钥 JSON 序列化（避免 ASN1 解析器版本差异）
  // =====================================================================

  Map<String, String> _privateKeyToJson(RSAPrivateKey priv, RSAPublicKey pub) {
    return {
      'n': priv.modulus!.toString(),
      'e': pub.exponent!.toString(),
      'd': priv.privateExponent!.toString(),
      'p': priv.p!.toString(),
      'q': priv.q!.toString(),
    };
  }

  RSAPrivateKey _privateKeyFromJson(Map<String, dynamic> json) {
    return RSAPrivateKey(
      BigInt.parse(json['n'] as String),
      BigInt.parse(json['d'] as String),
      BigInt.parse(json['p'] as String),
      BigInt.parse(json['q'] as String),
    );
  }

  // =====================================================================
  // X.509 证书构造（手动 DER 编码）
  // =====================================================================

  Uint8List _buildTbsCertificate({
    required BigInt serialNumber,
    required String issuerCn,
    required String issuerOrg,
    required String subjectCn,
    required String subjectOrg,
    required DateTime notBefore,
    required DateTime notAfter,
    required RSAPublicKey publicKey,
    required bool isCa,
    List<String>? dnsNames,
    List<String>? ipAddresses,
  }) {
    final elements = <Uint8List>[
      _asn1ExplicitTag(0, _asn1Integer(BigInt.from(2))), // version v3
      _asn1Integer(serialNumber),
      _buildAlgorithmIdentifier(_oidSha256WithRsa),
      _buildName(issuerCn, issuerOrg),
      _asn1Sequence([_asn1UtcTime(notBefore), _asn1UtcTime(notAfter)]),
      _buildName(subjectCn, subjectOrg),
      _buildSubjectPublicKeyInfo(publicKey),
    ];

    final extensions = _buildExtensions(
      isCa: isCa,
      dnsNames: dnsNames,
      ipAddresses: ipAddresses,
    );
    elements.add(_asn1ExplicitTag(3, extensions));

    return _asn1Sequence(elements);
  }

  Uint8List _buildCertificate(Uint8List tbsDer, Uint8List signature) {
    return _asn1Sequence([
      tbsDer,
      _buildAlgorithmIdentifier(_oidSha256WithRsa),
      _asn1BitString(signature),
    ]);
  }

  Uint8List _buildAlgorithmIdentifier(String oid) {
    return _asn1Sequence([_asn1Oid(oid), _asn1Null()]);
  }

  Uint8List _buildName(String commonName, String organization) {
    return _asn1Sequence([
      _asn1Set([
        _asn1Sequence([_asn1Oid(_oidOrganization), _asn1Utf8String(organization)]),
      ]),
      _asn1Set([
        _asn1Sequence([_asn1Oid(_oidCommonName), _asn1Utf8String(commonName)]),
      ]),
    ]);
  }

  Uint8List _buildSubjectPublicKeyInfo(RSAPublicKey publicKey) {
    final rsaPublicKeyDer = _asn1Sequence([
      _asn1Integer(publicKey.modulus!),
      _asn1Integer(publicKey.exponent!),
    ]);
    return _asn1Sequence([
      _buildAlgorithmIdentifier(_oidRsaEncryption),
      _asn1BitString(rsaPublicKeyDer),
    ]);
  }

  Uint8List _buildExtensions({
    required bool isCa,
    List<String>? dnsNames,
    List<String>? ipAddresses,
  }) {
    final extensions = <Uint8List>[];

    // basicConstraints (critical)
    extensions.add(_buildExtension(
      _oidBasicConstraints,
      critical: true,
      value: _asn1Sequence([_asn1Boolean(isCa)]),
    ));

    // keyUsage (critical): CA=0x06(keyCertSign|cRLSign), 非CA=0xA0(digitalSignature|keyEncipherment)
    final keyUsageByte = isCa ? 0x06 : 0xA0;
    extensions.add(_buildExtension(
      _oidKeyUsage,
      critical: true,
      value: _asn1BitString(Uint8List.fromList([keyUsageByte])),
    ));

    if (!isCa) {
      // extendedKeyUsage
      extensions.add(_buildExtension(
        _oidExtendedKeyUsage,
        critical: false,
        value: _asn1Sequence([_asn1Oid(_oidServerAuth)]),
      ));

      // subjectAltName
      if (dnsNames != null || ipAddresses != null) {
        extensions.add(_buildExtension(
          _oidSubjectAltName,
          critical: false,
          value: _buildSubjectAltName(dnsNames, ipAddresses),
        ));
      }
    }

    return _asn1Sequence(extensions);
  }

  Uint8List _buildExtension(String oid, {required bool critical, required Uint8List value}) {
    final elements = <Uint8List>[_asn1Oid(oid)];
    if (critical) elements.add(_asn1Boolean(true));
    elements.add(_asn1OctetString(value));
    return _asn1Sequence(elements);
  }

  Uint8List _buildSubjectAltName(List<String>? dnsNames, List<String>? ipAddresses) {
    final names = <Uint8List>[];
    if (dnsNames != null) {
      for (final name in dnsNames) {
        names.add(_asn1ImplicitTag(2, _tagIa5String, ascii.encode(name)));
      }
    }
    if (ipAddresses != null) {
      for (final ip in ipAddresses) {
        final parts = ip.split('.').map((p) => int.parse(p)).toList();
        names.add(_asn1ImplicitTag(7, _tagOctetString, Uint8List.fromList(parts)));
      }
    }
    return _asn1Sequence(names);
  }

  // =====================================================================
  // 加密操作
  // =====================================================================

  AsymmetricKeyPair<PublicKey, PrivateKey> _generateRsaKeyPair() {
    final keyGen = RSAKeyGenerator();
    keyGen.init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
      _secureRandom(),
    ));
    return keyGen.generateKeyPair();
  }

  Uint8List _signSha256WithRsa(Uint8List data, RSAPrivateKey privateKey) {
    final signer = Signer('SHA-256/RSA');
    signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final sig = signer.generateSignature(data);
    // pointycastle 4.0: RSASignature 有 bytes getter
    return (sig as RSASignature).bytes;
  }

  SecureRandom _secureRandom() {
    final secureRandom = FortunaRandom();
    final seedSource = Random.secure();
    final seeds = <int>[];
    for (var i = 0; i < 32; i++) {
      seeds.add(seedSource.nextInt(255));
    }
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  // =====================================================================
  // PEM / DER 编解码
  // =====================================================================

  String _derToPem(Uint8List der, String label) {
    final base64Str = base64.encode(der);
    final lines = <String>[];
    for (var i = 0; i < base64Str.length; i += 64) {
      lines.add(base64Str.substring(
        i,
        (i + 64 > base64Str.length) ? base64Str.length : i + 64,
      ));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----';
  }

  /// 编码私钥为 PEM (PKCS#8)，需要公钥的 e
  String _encodePrivateKeyPem(RSAPrivateKey privateKey, RSAPublicKey publicKey) {
    return _derToPem(_encodePkcs8PrivateKey(privateKey, publicKey), 'PRIVATE KEY');
  }

  /// PKCS#8 PrivateKeyInfo
  Uint8List _encodePkcs8PrivateKey(RSAPrivateKey priv, RSAPublicKey pub) {
    return _asn1Sequence([
      _asn1Integer(BigInt.zero),
      _buildAlgorithmIdentifier(_oidRsaEncryption),
      _asn1OctetString(_encodeRsaPrivateKeyPkcs1(priv, pub)),
    ]);
  }

  /// PKCS#1 RSAPrivateKey，CRT 参数手动计算
  Uint8List _encodeRsaPrivateKeyPkcs1(RSAPrivateKey priv, RSAPublicKey pub) {
    final n = priv.modulus!;
    final d = priv.privateExponent!;
    final p = priv.p!;
    final q = priv.q!;
    final e = pub.exponent!;
    // 手动计算 CRT 参数
    final dP1 = d % (p - BigInt.one);
    final dQ1 = d % (q - BigInt.one);
    final coeff = q.modInverse(p);

    return _asn1Sequence([
      _asn1Integer(BigInt.zero),
      _asn1Integer(n),
      _asn1Integer(e),
      _asn1Integer(d),
      _asn1Integer(p),
      _asn1Integer(q),
      _asn1Integer(dP1),
      _asn1Integer(dQ1),
      _asn1Integer(coeff),
    ]);
  }

  // =====================================================================
  // 手动 ASN.1 DER 编码辅助函数
  // =====================================================================

  Uint8List _derEncode(int tag, Uint8List value) {
    final lengthBytes = _derLength(value.length);
    final result = Uint8List(1 + lengthBytes.length + value.length);
    result[0] = tag;
    result.setRange(1, 1 + lengthBytes.length, lengthBytes);
    result.setRange(1 + lengthBytes.length, result.length, value);
    return result;
  }

  List<int> _derLength(int length) {
    if (length < 128) return [length];
    final bytes = <int>[];
    var len = length;
    while (len > 0) {
      bytes.insert(0, len & 0xFF);
      len >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  Uint8List _asn1Sequence(List<Uint8List> elements) =>
      _derEncode(_tagSequence, _concat(elements));

  Uint8List _asn1Set(List<Uint8List> elements) =>
      _derEncode(_tagSet, _concat(elements));

  Uint8List _asn1Integer(BigInt value) {
    var bytes = _bigIntToBytes(value);
    if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
    if ((bytes[0] & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    return _derEncode(_tagInteger, bytes);
  }

  Uint8List _asn1BitString(Uint8List data) =>
      _derEncode(_tagBitString, Uint8List.fromList([0, ...data]));

  Uint8List _asn1OctetString(Uint8List data) =>
      _derEncode(_tagOctetString, data);

  Uint8List _asn1Utf8String(String value) =>
      _derEncode(_tagUtf8String, utf8.encode(value));

  Uint8List _asn1UtcTime(DateTime time) {
    final utc = time.toUtc();
    final str =
        '${utc.year.toString().substring(2)}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}'
        'Z';
    return _derEncode(_tagUtcTime, ascii.encode(str));
  }

  Uint8List _asn1Boolean(bool value) =>
      _derEncode(_tagBoolean, Uint8List.fromList([value ? 0xFF : 0x00]));

  Uint8List _asn1Null() => _derEncode(_tagNull, Uint8List(0));

  Uint8List _asn1Oid(String oid) => _derEncode(_tagOid, _encodeOidValue(oid));

  /// [n] EXPLICIT tagged (constructed, tag 0xA0 | n)
  Uint8List _asn1ExplicitTag(int tag, Uint8List value) =>
      _derEncode(0xA0 | tag, value);

  /// [n] IMPLICIT tagged primitive (tag 0x80 | n)，直接用纯 value
  Uint8List _asn1ImplicitTag(int tag, int originalTag, Uint8List pureValue) =>
      _derEncode(0x80 | tag, pureValue);

  Uint8List _encodeOidValue(String oid) {
    final parts = oid.split('.').map(int.parse).toList();
    final bytes = <int>[40 * parts[0] + parts[1]];
    for (var i = 2; i < parts.length; i++) {
      bytes.addAll(_encodeBase128(parts[i]));
    }
    return Uint8List.fromList(bytes);
  }

  List<int> _encodeBase128(int value) {
    if (value == 0) return [0];
    final bytes = <int>[];
    var val = value;
    while (val > 0) {
      bytes.insert(0, val & 0x7F);
      val >>= 7;
    }
    for (var i = 0; i < bytes.length - 1; i++) {
      bytes[i] |= 0x80;
    }
    return bytes;
  }

  Uint8List _bigIntToBytes(BigInt value) {
    if (value == BigInt.zero) return Uint8List.fromList([0]);
    final bytes = <int>[];
    var val = value;
    while (val > BigInt.zero) {
      bytes.insert(0, (val & BigInt.from(0xFF)).toInt());
      val >>= 8;
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List _concat(List<Uint8List> parts) {
    final total = parts.fold<int>(0, (sum, p) => sum + p.length);
    final result = Uint8List(total);
    var offset = 0;
    for (final part in parts) {
      result.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return result;
  }

  BigInt _randomSerial() {
    final rng = Random.secure();
    final bytes = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      bytes[i] = rng.nextInt(256);
    }
    bytes[0] &= 0x7F;
    return BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
  }

  bool _isIpAddress(String host) => InternetAddress.tryParse(host) != null;
}

class _CachedCert {
  final String certPem;
  final String keyPem;
  final DateTime expiresAt;

  _CachedCert({
    required this.certPem,
    required this.keyPem,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
