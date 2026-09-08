import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants.dart';
import '../models/capture_record.dart';

/// 抓包记录本地存储管理
class CaptureStore {
  static final CaptureStore _instance = CaptureStore._internal();
  factory CaptureStore() => _instance;
  CaptureStore._internal();

  Box? _recordsBox;
  Box? _settingsBox;
  Box? _favoritesBox;
  Box? _blacklistBox;
  Box? _whitelistBox;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    await Hive.initFlutter();

    _recordsBox = await Hive.openBox(AppConstants.boxRecords);
    _settingsBox = await Hive.openBox(AppConstants.boxSettings);
    _favoritesBox = await Hive.openBox(AppConstants.boxFavorites);
    _blacklistBox = await Hive.openBox(AppConstants.boxBlacklist);
    _whitelistBox = await Hive.openBox(AppConstants.boxWhitelist);

    _initialized = true;
  }

  // ---- 抓包记录 ----

  Future<void> addRecord(CaptureRecord record) async {
    await _recordsBox?.put(record.id, jsonEncode(record.toMap()));
  }

  List<CaptureRecord> getAllRecords() {
    if (_recordsBox == null) return [];
    final records = <CaptureRecord>[];
    for (final key in _recordsBox!.keys) {
      try {
        final json = _recordsBox!.get(key) as String;
        records.add(CaptureRecord.fromMap(jsonDecode(json)));
      } catch (_) {}
    }
    records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return records;
  }

  CaptureRecord? getRecord(String id) {
    try {
      final json = _recordsBox?.get(id) as String?;
      if (json == null) return null;
      return CaptureRecord.fromMap(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteRecord(String id) async {
    await _recordsBox?.delete(id);
  }

  Future<void> clearAllRecords() async {
    await _recordsBox?.clear();
  }

  int get recordCount => _recordsBox?.length ?? 0;

  // ---- 收藏 ----

  Future<void> toggleFavorite(String id) async {
    if (isFavorite(id)) {
      await _favoritesBox?.delete(id);
    } else {
      await _favoritesBox?.put(id, true);
    }
  }

  bool isFavorite(String id) {
    return _favoritesBox?.get(id) == true;
  }

  List<CaptureRecord> getFavorites() {
    return getAllRecords().where((r) => isFavorite(r.id)).toList();
  }

  // ---- 黑名单 ----

  Set<String> getBlacklist() {
    if (_blacklistBox == null) return {};
    return _blacklistBox!.keys.cast<String>().toSet();
  }

  Future<void> addBlacklist(String domain) async {
    await _blacklistBox?.put(domain, true);
  }

  Future<void> removeBlacklist(String domain) async {
    await _blacklistBox?.delete(domain);
  }

  Future<void> clearBlacklist() async {
    await _blacklistBox?.clear();
  }

  // ---- 白名单 ----

  Set<String> getWhitelist() {
    if (_whitelistBox == null) return {};
    return _whitelistBox!.keys.cast<String>().toSet();
  }

  Future<void> addWhitelist(String domain) async {
    await _whitelistBox?.put(domain, true);
  }

  Future<void> removeWhitelist(String domain) async {
    await _whitelistBox?.delete(domain);
  }

  Future<void> clearWhitelist() async {
    await _whitelistBox?.clear();
  }

  // ---- 设置 ----

  T? getSetting<T>(String key, [T? defaultValue]) {
    return _settingsBox?.get(key, defaultValue: defaultValue) as T?;
  }

  Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox?.put(key, value);
  }

  bool get useWhitelist => getSetting<bool>('useWhitelist', false) ?? false;
  set useWhitelist(bool value) => setSetting('useWhitelist', value);

  bool get darkMode => getSetting<bool>('darkMode', false) ?? false;
  set darkMode(bool value) => setSetting('darkMode', value);

  bool get autoClearOnStart => getSetting<bool>('autoClearOnStart', false) ?? false;
  set autoClearOnStart(bool value) => setSetting('autoClearOnStart', value);
}
