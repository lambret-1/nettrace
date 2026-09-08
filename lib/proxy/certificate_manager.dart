import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../core/constants.dart';

/// CA 证书管理器 - 手动构造 X.509 证书 ASN.1 DER
///
/// 不依赖 pointycastle 的 ASN1 构造函数（各版本 API 差异大），
/// 全部手动 DER 编码，仅依赖稳定的加密原语：
/// - RSAKeyGenerator 密钥生成
/// - Signer('SHA-256/RSA') 签名
/// - ASN1Parser 解析（仅用于加载已有私钥）
class CertificateManager {
  static final CertificateManager _instance = CertificateManager._internal();
  factory CertificateManager() => _instance;
  CertificateManager._internal();

  RSAPrivateKey? _caPrivateKey;
  RSAPublicKey? _caPublicKey;
  String? _caCertPem;
  final Map<String, _CachedCert> _certCache = {};

  bool get isReady => _caPrivateKey != null && _caCertPem != null;

  // ---- OID 常量 ----
  static const String _oidSha256WithRsa = '1.2.840.113549.1.1.11';
  static const String _oidRsaEncryption = '1.2.840.113549.1.1.1';
  static const String _oidCommonName = '2.5.4.3';
  static const String _oidOrganization = '2.5.4.10';
  static const String _oidBasicConstraints = '2.5.29.19';
  static const String _oidKeyUsage = '2.5.29.15';
  static const String _oidExtendedKeyUsage = '2.5.29.37';
  static const String _oidSubjectAltName = '2.5.29.17';
  static const String _oidServerAuth = '1.3.6.1.5.5.7.3.1';

  // ---- ASN.1 标签常量 ----
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
    final keyFile = File('${dir.path}/ca_key.pem');

    if (certFile.existsSync() && keyFile.existsSync()) {
      try {
        _caCertPem = certFile.readAsStringSync();
        _caPrivateKey = _parsePrivateKeyPem(keyFile.readAsStringSync());
        _caPublicKey = _caPrivateKey!.publicKey as RSAPublicKey;
        return;
      } catch (_) {}
    }
    _generateCa();
    certFile.writeAsStringSync(caCertPem);
    keyFile.writeAsStringSync(caPrivateKeyPem);
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
      keyPem: _encodePrivateKeyPem(privateKey),
      expiresAt: DateTime.now().add(const Duration(days: AppConstants.certValidityDays)),
    );
    _certCache[host] = cachedCert;
    return cachedCert;
  }

  /// 为指定域名创建 SecurityContext
  SecurityContext createSecurityContextForHost(String host) {
    final cert = getCertificateForHost(host);
    final context = SecurityContext();
    context.useCertificateChainBytes(utf8.encode(cert.certPem));
    context.usePrivateKeyBytes(utf8.encode(cert.keyPem));
    return context;
  }

  String get caCertPem => _caCertPem ?? '';

  String get caPrivateKeyPem {
    if (_caPrivateKey == null) return '';
    return _encodePrivateKeyPem(_caPrivateKey!);
  }

  Future<String> exportCaCertToFile() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/NetTrace_CA.crt');
    file.writeAsStringSync(caCertPem);
    return file.path;
  }

  // =====================================================================
  // X.509 证书构造（手动 DER 编码）
  // =====================================================================

  /// 构造 TBSCertificate
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
    final elements = <Uint8List>[];

    // version [0] EXPLICIT INTEGER (v3 = 2)
    elements.add(_asn1ExplicitTag(0, _asn1Integer(BigInt.from(2))));

    // serialNumber
    elements.add(_asn1Integer(serialNumber));

    // signature AlgorithmIdentifier
    elements.add(_buildAlgorithmIdentifier(_oidSha256WithRsa));

    // issuer Name
    elements.add(_buildName(issuerCn, issuerOrg));

    // validity
    elements.add(_asn1Sequence([
      _asn1UtcTime(notBefore),
      _asn1UtcTime(notAfter),
    ]));

    // subject Name
    elements.add(_buildName(subjectCn, subjectOrg));

    // subjectPublicKeyInfo
    elements.add(_buildSubjectPublicKeyInfo(publicKey));

    // extensions [3] EXPLICIT
    final extensions = _buildExtensions(
      isCa: isCa,
      dnsNames: dnsNames,
      ipAddresses: ipAddresses,
    );
    elements.add(_asn1ExplicitTag(3, extensions));

    return _asn1Sequence(elements);
  }

  /// 构造完整 Certificate
  Uint8List _buildCertificate(Uint8List tbsDer, Uint8List signature) {
    return _asn1Sequence([
      tbsDer,
      _buildAlgorithmIdentifier(_oidSha256WithRsa),
      _asn1BitString(signature),
    ]);
  }

  /// 构造 AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters NULL }
  Uint8List _buildAlgorithmIdentifier(String oid) {
    return _asn1Sequence([
      _asn1Oid(oid),
      _asn1Null(),
    ]);
  }

  /// 构造 Name (DistinguishedName)
  /// Name ::= SEQUENCE OF RelativeDistinguishedName
  /// RelativeDistinguishedName ::= SET OF AttributeTypeAndValue
  Uint8List _buildName(String commonName, String organization) {
    return _asn1Sequence([
      // organizationName
      _asn1Set([
        _asn1Sequence([
          _asn1Oid(_oidOrganization),
          _asn1Utf8String(organization),
        ]),
      ]),
      // commonName
      _asn1Set([
        _asn1Sequence([
          _asn1Oid(_oidCommonName),
          _asn1Utf8String(commonName),
        ]),
      ]),
    ]);
  }

  /// 构造 SubjectPublicKeyInfo
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

  /// 构造 Extensions ::= SEQUENCE OF Extension
  Uint8List _buildExtensions({
    required bool isCa,
    List<String>? dnsNames,
    List<String>? ipAddresses,
  }) {
    final extensions = <Uint8List>[];

    // basicConstraints (critical) ::= SEQUENCE { cA BOOLEAN }
    final bcContent = _asn1Sequence([_asn1Boolean(isCa)]);
    extensions.add(_buildExtension(
      _oidBasicConstraints,
      critical: true,
      value: bcContent,
    ));

    // keyUsage (critical) ::= BIT STRING
    // CA: keyCertSign(5) | cRLSign(6) → 0x06
    // 非CA: digitalSignature(0) | keyEncipherment(2) → 0xA0
    final keyUsageByte = isCa ? 0x06 : 0xA0;
    extensions.add(_buildExtension(
      _oidKeyUsage,
      critical: true,
      value: _asn1BitString(Uint8List.fromList([keyUsageByte])),
    ));

    // extendedKeyUsage (非CA) ::= SEQUENCE OF OID
    if (!isCa) {
      final ekuContent = _asn1Sequence([_asn1Oid(_oidServerAuth)]);
      extensions.add(_buildExtension(
        _oidExtendedKeyUsage,
        critical: false,
        value: ekuContent,
      ));
    }

    // subjectAltName (非CA) ::= SEQUENCE OF GeneralName
    if (!isCa && (dnsNames != null || ipAddresses != null)) {
      extensions.add(_buildExtension(
        _oidSubjectAltName,
        critical: false,
        value: _buildSubjectAltName(dnsNames, ipAddresses),
      ));
    }

    return _asn1Sequence(extensions);
  }

  /// 构造单个 Extension
  /// Extension ::= SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
  Uint8List _buildExtension(String oid, {required bool critical, required Uint8List value}) {
    final elements = <Uint8List>[_asn1Oid(oid)];
    if (critical) elements.add(_asn1Boolean(true));
    elements.add(_asn1OctetString(value));
    return _asn1Sequence(elements);
  }

  /// 构造 SubjectAltName ::= SEQUENCE OF GeneralName
  /// GeneralName ::= CHOICE { dNSName [2] IMPLICIT IA5String, iPAddress [7] IMPLICIT OCTET STRING }
  Uint8List _buildSubjectAltName(List<String>? dnsNames, List<String>? ipAddresses) {
    final names = <Uint8List>[];

    if (dnsNames != null) {
      for (final name in dnsNames) {
        // [2] IMPLICIT IA5String → tag 0x82 (context-specific, primitive, tag=2)
        names.add(_asn1ImplicitTag(2, _asn1Ia5String(name)));
      }
    }

    if (ipAddresses != null) {
      for (final ip in ipAddresses) {
        final parts = ip.split('.').map((p) => int.parse(p)).toList();
        final ipBytes = Uint8List.fromList(parts);
        // [7] IMPLICIT OCTET STRING → tag 0x87
        names.add(_asn1ImplicitTag(7, _asn1OctetString(ipBytes)));
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
    return signer.generateSignature(data).bytes;
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

  Uint8List _pemToDer(String pem, String label) {
    final lines = pem.split('\n');
    final base64Lines = lines
        .where((l) => !l.startsWith('-----') && l.trim().isNotEmpty)
        .join();
    return base64.decode(base64Lines);
  }

  String _encodePrivateKeyPem(RSAPrivateKey privateKey) {
    return _derToPem(_encodePkcs8PrivateKey(privateKey), 'PRIVATE KEY');
  }

  /// PKCS#8 PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
  Uint8List _encodePkcs8PrivateKey(RSAPrivateKey privateKey) {
    return _asn1Sequence([
      _asn1Integer(BigInt.zero),
      _buildAlgorithmIdentifier(_oidRsaEncryption),
      _asn1OctetString(_encodeRsaPrivateKeyPkcs1(privateKey)),
    ]);
  }

  /// PKCS#1 RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dP1, dQ1, coeff }
  Uint8List _encodeRsaPrivateKeyPkcs1(RSAPrivateKey privateKey) {
    return _asn1Sequence([
      _asn1Integer(BigInt.zero),
      _asn1Integer(privateKey.modulus!),
      _asn1Integer(privateKey.publicExponent!),
      _asn1Integer(privateKey.privateExponent!),
      _asn1Integer(privateKey.p!),
      _asn1Integer(privateKey.q!),
      _asn1Integer(privateKey.dP1!),
      _asn1Integer(privateKey.dQ1!),
      _asn1Integer(privateKey.coefficient!),
    ]);
  }

  /// 解析 PEM 格式私钥 (PKCS#8)
  RSAPrivateKey _parsePrivateKeyPem(String pem) {
    final der = _pemToDer(pem, 'PRIVATE KEY');
    final parser = ASN1Parser(der);
    final seq = parser.nextObject() as ASN1Sequence;
    final elements = seq.elements!;

    // elements[2] = privateKey OCTET STRING
    final privateKeyOctet = elements[2] as ASN1OctetString;
    final rsaDer = privateKeyOctet.octets!;

    return _parseRsaPrivateKeyPkcs1(rsaDer);
  }

  /// 解析 RSAPrivateKey (PKCS#1)
  RSAPrivateKey _parseRsaPrivateKeyPkcs1(Uint8List der) {
    final parser = ASN1Parser(der);
    final seq = parser.nextObject() as ASN1Sequence;
    final elements = seq.elements!;

    final n = (elements[1] as ASN1Integer).integer!;
    final e = (elements[2] as ASN1Integer).integer!;
    final d = (elements[3] as ASN1Integer).integer!;
    final p = (elements[4] as ASN1Integer).integer!;
    final q = (elements[5] as ASN1Integer).integer!;
    final dP1 = (elements[6] as ASN1Integer).integer!;
    final dQ1 = (elements[7] as ASN1Integer).integer!;
    final coeff = (elements[8] as ASN1Integer).integer!;

    final privateKey = RSAPrivateKey(n, d, p, q);
    privateKey.dP1 = dP1;
    privateKey.dQ1 = dQ1;
    privateKey.coefficient = coeff;
    privateKey.publicExponent = e;
    return privateKey;
  }

  // =====================================================================
  // 手动 ASN.1 DER 编码辅助函数
  // =====================================================================

  /// 通用 DER 编码: tag + length + value
  Uint8List _derEncode(int tag, Uint8List value) {
    final lengthBytes = _derLength(value.length);
    final result = Uint8List(1 + lengthBytes.length + value.length);
    result[0] = tag;
    result.setRange(1, 1 + lengthBytes.length, lengthBytes);
    result.setRange(1 + lengthBytes.length, result.length, value);
    return result;
  }

  /// DER 长度编码
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

  /// SEQUENCE ::= SEQUENCE OF (tag 0x30)
  Uint8List _asn1Sequence(List<Uint8List> elements) {
    final value = _concat(elements);
    return _derEncode(_tagSequence, value);
  }

  /// SET ::= SET OF (tag 0x31)
  Uint8List _asn1Set(List<Uint8List> elements) {
    final value = _concat(elements);
    return _derEncode(_tagSet, value);
  }

  /// INTEGER (tag 0x02) - 处理前导零
  Uint8List _asn1Integer(BigInt value) {
    var bytes = _bigIntToBytes(value);
    if (bytes.isEmpty) bytes = Uint8List.fromList([0]);
    // 最高位为1时需要前导零（表示正数）
    if ((bytes[0] & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    return _derEncode(_tagInteger, bytes);
  }

  /// BIT STRING (tag 0x03) - 第一个内容字节是 unused bits
  Uint8List _asn1BitString(Uint8List data) {
    final value = Uint8List.fromList([0, ...data]); // unused bits = 0
    return _derEncode(_tagBitString, value);
  }

  /// OCTET STRING (tag 0x04)
  Uint8List _asn1OctetString(Uint8List data) {
    return _derEncode(_tagOctetString, data);
  }

  /// UTF8String (tag 0x0C)
  Uint8List _asn1Utf8String(String value) {
    return _derEncode(_tagUtf8String, utf8.encode(value));
  }

  /// IA5String (tag 0x16)
  Uint8List _asn1Ia5String(String value) {
    return _derEncode(_tagIa5String, ascii.encode(value));
  }

  /// UTCTime (tag 0x17) - 格式 YYMMDDHHMMSSZ
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

  /// BOOLEAN (tag 0x01)
  Uint8List _asn1Boolean(bool value) {
    return _derEncode(_tagBoolean, Uint8List.fromList([value ? 0xFF : 0x00]));
  }

  /// NULL (tag 0x05)
  Uint8List _asn1Null() {
    return _derEncode(_tagNull, Uint8List(0));
  }

  /// OBJECT IDENTIFIER (tag 0x06)
  Uint8List _asn1Oid(String oid) {
    return _derEncode(_tagOid, _encodeOidValue(oid));
  }

  /// [n] EXPLICIT tagged (tag 0xA0 | n)
  Uint8List _asn1ExplicitTag(int tag, Uint8List value) {
    return _derEncode(0xA0 | tag, value);
  }

  /// [n] IMPLICIT tagged primitive (tag 0x80 | n)
  /// 注意：IMPLICIT 不包含原始 tag，直接用新 tag 包装 value
  Uint8List _asn1ImplicitTag(int tag, Uint8List originalValue) {
    // originalValue 包含原始 tag+length+value，需要提取纯 value
    // 对于简单类型（IA5String, OCTET STRING），跳过 tag 和 length
    var offset = 1; // skip tag
    final lenByte = originalValue[1];
    if (lenByte >= 128) {
      offset += 1 + (lenByte & 0x7F);
    } else {
      offset += 1;
    }
    final pureValue = originalValue.sublist(offset);
    return _derEncode(0x80 | tag, pureValue);
  }

  /// OID 值编码（不含 tag/length）
  Uint8List _encodeOidValue(String oid) {
    final parts = oid.split('.').map(int.parse).toList();
    final bytes = <int>[];
    // 前两个值合并: 40 * first + second
    bytes.add(40 * parts[0] + parts[1]);
    // 后续值用 base-128 编码
    for (var i = 2; i < parts.length; i++) {
      bytes.addAll(_encodeBase128(parts[i]));
    }
    return Uint8List.fromList(bytes);
  }

  /// Base-128 编码（用于 OID）
  List<int> _encodeBase128(int value) {
    if (value == 0) return [0];
    final bytes = <int>[];
    var val = value;
    while (val > 0) {
      bytes.insert(0, val & 0x7F);
      val >>= 7;
    }
    // 除最后一个字节外，设置高位
    for (var i = 0; i < bytes.length - 1; i++) {
      bytes[i] |= 0x80;
    }
    return bytes;
  }

  /// BigInt 转大端字节数组（无符号）
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

  /// 拼接多个字节数组
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

  // =====================================================================
  // 工具方法
  // =====================================================================

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

  bool _isIpAddress(String host) {
    return InternetAddress.tryParse(host) != null;
  }
}

/// 缓存的动态证书
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
