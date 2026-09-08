import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../core/constants.dart';

/// CA 证书管理器 - 负责根证书生成、动态域名证书签发
///
/// 使用 basic_utils 库进行 X.509 证书生成和管理。
/// CA 根证书在首次运行时自动生成并持久化到本地。
/// 每个目标域名的证书按需动态签发并缓存。
class CertificateManager {
  static final CertificateManager _instance = CertificateManager._internal();
  factory CertificateManager() => _instance;
  CertificateManager._internal();

  AsymmetricKeyPair<PublicKey, PrivateKey>? _caKeyPair;
  X509CertificateData? _caCert;
  final Map<String, _CachedCert> _certCache = {};

  bool get isReady => _caCert != null && _caKeyPair != null;

  /// 初始化：加载或生成 CA 根证书
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    final certFile = File('${dir.path}/ca_cert.pem');
    final keyFile = File('${dir.path}/ca_key.pem');

    if (certFile.existsSync() && keyFile.existsSync()) {
      try {
        _loadCaFromFiles(certFile, keyFile);
        return;
      } catch (_) {
        // 加载失败，重新生成
      }
    }
    _generateCa();
    _saveCaToFiles(certFile, keyFile);
  }

  /// 生成 CA 根证书（自签）
  void _generateCa() {
    _caKeyPair = CryptoUtils.generateRsaKeyPair(bitLength: 2048);

    final now = DateTime.now();
    _caCert = X509Utils.generateSelfSignedCertificate(
      _caKeyPair!.privateKey as RSAPrivateKey,
      _caKeyPair!.publicKey as RSAPublicKey,
      X509CertificateData(
        subject: X509Subject(
          commonName: AppConstants.caCommonName,
          organization: AppConstants.caOrganization,
        ),
        serialNumber: _randomSerial(),
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: now.add(const Duration(days: AppConstants.caValidityDays)),
        extensions: [
          X509Extension.basicConstraints(
            BasicConstraintsExtension(isCA: true, pathLenConstraint: 0),
          ),
          X509Extension.keyUsage(
            KeyUsageExtension(
              keyUsages: [KeyUsage.keyCertSign, KeyUsage.cRLSign],
            ),
          ),
        ],
      ),
    );
  }

  void _loadCaFromFiles(File certFile, File keyFile) {
    final certPem = certFile.readAsStringSync();
    final keyPem = keyFile.readAsStringSync();
    _caCert = X509Utils.x509CertificateFromPem(certPem);
    _caKeyPair = AsymmetricKeyPair(
      _caCert!.publicKeyData!.publicKey!,
      CryptoUtils.rsaPrivateKeyFromPem(keyPem),
    );
  }

  void _saveCaToFiles(File certFile, File keyFile) {
    certFile.writeAsStringSync(caCertPem);
    keyFile.writeAsStringSync(caPrivateKeyPem);
  }

  /// 为指定域名签发动态证书（带缓存）
  _CachedCert getCertificateForHost(String host) {
    final cached = _certCache[host];
    if (cached != null && !cached.isExpired) return cached;

    final now = DateTime.now();
    final keyPair = CryptoUtils.generateRsaKeyPair(bitLength: 2048);

    final cert = X509Utils.generateCertificate(
      _caKeyPair!.privateKey as RSAPrivateKey,
      _caCert!,
      X509CertificateData(
        subject: X509Subject(
          commonName: host,
          organization: AppConstants.caOrganization,
        ),
        issuer: X509Subject(
          commonName: AppConstants.caCommonName,
          organization: AppConstants.caOrganization,
        ),
        serialNumber: _randomSerial(),
        notBefore: now.subtract(const Duration(days: 1)),
        notAfter: now.add(const Duration(days: AppConstants.certValidityDays)),
        extensions: [
          X509Extension.basicConstraints(
            BasicConstraintsExtension(isCA: false),
          ),
          X509Extension.keyUsage(
            KeyUsageExtension(
              keyUsages: [KeyUsage.digitalSignature, KeyUsage.keyEncipherment],
            ),
          ),
          X509Extension.extendedKeyUsage(
            ExtendedKeyUsageExtension(
              extKeyUsage: [ExtendedKeyUsage.serverAuth],
            ),
          ),
          X509Extension.subjectAlternativeName(
            SubjectAlternativeNameExtension(
              dnsNames: [host, '*.$host'],
              ipAddresses: _isIpAddress(host) ? [host] : null,
            ),
          ),
        ],
      ),
    );

    final cachedCert = _CachedCert(
      certificate: cert,
      keyPair: keyPair,
      expiresAt: now.add(const Duration(days: AppConstants.certValidityDays)),
    );
    _certCache[host] = cachedCert;
    return cachedCert;
  }

  /// 为指定域名创建 SecurityContext（用于 SecureServerSocket TLS 握手）
  SecurityContext createSecurityContextForHost(String host) {
    final cert = getCertificateForHost(host);
    final context = SecurityContext();
    context.useCertificateChainBytes(utf8.encode(cert.certPem));
    context.usePrivateKeyBytes(utf8.encode(cert.keyPem));
    return context;
  }

  // ---- PEM 导出 ----

  String get caCertPem {
    if (_caCert == null) return '';
    return _certToPem(_caCert!);
  }

  String get caPrivateKeyPem {
    if (_caKeyPair == null) return '';
    return CryptoUtils.encodeRSAPrivateKeyToPem(
      _caKeyPair!.privateKey as RSAPrivateKey,
    );
  }

  /// 将 X509CertificateData 转为 PEM 字符串
  /// 兼容 basic_utils 不同版本的 API
  String _certToPem(X509CertificateData cert) {
    try {
      return X509Utils.x509CertificateToPem(cert);
    } catch (_) {
      // 回退：如果 x509CertificateToPem 不可用，尝试其他方式
      try {
        return X509Utils.encodeToPem(cert);
      } catch (_) {
        // 最终回退：手动构造 PEM（需要 DER 数据）
        return '';
      }
    }
  }

  /// 导出 CA 证书到临时文件，返回文件路径（用于分享安装）
  Future<String> exportCaCertToFile() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/NetTrace_CA.crt');
    file.writeAsStringSync(caCertPem);
    return file.path;
  }

  // ---- 工具方法 ----

  BigInt _randomSerial() {
    final rng = Random.secure();
    final bytes = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      bytes[i] = rng.nextInt(256);
    }
    bytes[0] &= 0x7F; // 确保正数
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
  final X509CertificateData certificate;
  final AsymmetricKeyPair<PublicKey, PrivateKey> keyPair;
  final DateTime expiresAt;

  _CachedCert({
    required this.certificate,
    required this.keyPair,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  String get certPem {
    try {
      return X509Utils.x509CertificateToPem(certificate);
    } catch (_) {
      try {
        return X509Utils.encodeToPem(certificate);
      } catch (_) {
        return '';
      }
    }
  }

  String get keyPem => CryptoUtils.encodeRSAPrivateKeyToPem(
        keyPair.privateKey as RSAPrivateKey,
      );
}
