# NetTrace - iOS 轻量本地抓包调试工具

[![Build IPA](https://github.com/yourname/nettrace/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/yourname/nettrace/actions)

> 纯本地运行的 iOS HTTP/HTTPS 抓包工具，面向开发者自测与接口分析。
> 无后台上传、无全局代理翻墙、无网络转发，完全合规。

## 功能特性

- 本地 HTTP/HTTPS 代理抓包（127.0.0.1:8888）
- HTTPS MITM 解密（本地 CA 证书，仅自用）
- 请求/响应详情可视化（Headers、Query、Body、JSON 格式化）
- 多维度筛选（域名、方法、状态码、关键词）
- 黑白名单域名过滤
- 一键导出标准 HAR 文件（可导入 Charles / 浏览器 DevTools）
- 请求收藏、清空、复制
- 深色 / 浅色主题
- 纯本地存储，零网络上传

## 系统要求

- iOS 15.0+
- Flutter 3.19+ / Dart 3.3+
- 部署方式：自签 IPA / TrollStore

## 快速开始

### 1. 安装依赖

```bash
flutter pub get
```

### 2. 运行

```bash
flutter run
```

### 3. 打包 IPA

```bash
flutter build ios --release --no-codesign
```

或使用 GitHub Actions 自动构建（见 `.github/workflows/build-ipa.yml`）。

## 使用方法

1. 打开 NetTrace，点击「启动代理」
2. 在 iOS 设置 → WiFi → 配置代理 → 手动，服务器填 `127.0.0.1`，端口 `8888`
3. 首次使用 HTTPS 抓包：在设置页点击「安装 CA 证书」，按提示安装描述文件并在「设置 → 通用 → 关于本机 → 证书信任设置」中开启信任
4. 返回 NetTrace 即可看到实时抓包列表

## 项目结构

```
lib/
├── main.dart                 # 入口
├── app.dart                  # 应用根组件 & 主题
├── core/
│   ├── constants.dart        # 常量定义
│   └── theme.dart            # 主题配置
├── models/
│   ├── capture_record.dart   # 抓包记录模型
│   ├── http_request.dart     # 请求模型
│   └── http_response.dart    # 响应模型
├── proxy/
│   ├── proxy_server.dart     # 本地代理服务核心
│   ├── http_interceptor.dart # HTTP 请求拦截解析
│   ├── https_mitm.dart       # HTTPS MITM 解密
│   └── certificate_manager.dart # CA 证书管理
├── storage/
│   └── capture_store.dart    # 本地存储管理
├── screens/
│   ├── home_screen.dart      # 主页（抓包列表）
│   ├── detail_screen.dart    # 详情页
│   ├── settings_screen.dart  # 设置页
│   └── filter_screen.dart    # 筛选页
├── widgets/
│   ├── request_tile.dart     # 请求列表项
│   ├── json_viewer.dart      # JSON 格式化查看器
│   └── status_badge.dart     # 状态码徽章
└── utils/
    ├── har_exporter.dart     # HAR 导出工具
    └── format_utils.dart     # 格式化工具
```

## 技术架构

```
┌─────────────────────────────────────────┐
│              UI Layer (Flutter)          │
│  Home / Detail / Settings / Filter       │
├─────────────────────────────────────────┤
│           Storage Layer (Hive)           │
│  抓包记录持久化 / 收藏 / 筛选配置          │
├─────────────────────────────────────────┤
│          Proxy Core (Dart:io)            │
│  ┌─────────────┐  ┌──────────────────┐  │
│  │ HTTP 拦截器  │  │ HTTPS MITM 解密  │  │
│  └─────────────┘  └──────────────────┘  │
│  ┌────────────────────────────────────┐  │
│  │    本地代理服务 127.0.0.1:8888     │  │
│  └────────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

## 合规声明

- 本工具仅用于开发者本地调试与接口分析
- 不实现全局 VPN 拦截、不实现网络转发代理上网
- 不提供公共节点、不做翻墙工具
- 所有抓包数据仅存储在本地设备，不上传任何服务器
- 请遵守当地法律法规，仅抓包自己拥有或已授权的应用

## License

MIT
