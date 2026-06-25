# 构建与分发指南

## 环境依赖

- **macOS** 14.0+，Apple Silicon 或 Intel
- **Xcode** 16.0+，含 Command Line Tools
- **Go** 1.22+（MITM 代理）
- **hdiutil** / **ditto**（macOS 自带，打包用）

## 项目结构

```
├── AntigravityTun/          # C++ dylib（Xcode 项目）
│   └── build/Release/       # 构建产物
├── launcher/                # Swift 桌面 App（Xcode + SwiftPM）
│   └── Resources/           # 版本号、配置模板
├── tools/mitm_proxy/        # Go MITM 代理
├── scripts/
│   └── build_universal.sh   # 一键全量构建脚本
└── build_output/            # 打包产物
```

## 一键构建

```bash
cd AntigravityProxyLauncher
bash scripts/build_universal.sh
```

脚本按顺序执行：
1. 构建 `libAntigravityTun.dylib`（arm64 + x86_64 → lipo 合并）
2. 构建 Go MITM 代理（arm64 + amd64 → lipo 合并）
3. 构建 Swift App（arm64）
4. 构建 Swift App（x86_64）
5. 合并 App 二进制 + 嵌入 dylib 和 Go 代理 → Universal `.app`
6. 打包 DMG + ZIP

产物：
```
build_output/
├── AntigravityProxyLauncher.app/       # Universal
├── AntigravityProxyLauncher_<ver>_macos_x86_64_arm64.dmg
└── AntigravityProxyLauncher_<ver>_macos_x86_64_arm64.zip
```

## 版本号

版本号在 `launcher/Resources/version.txt`，构建脚本自动读取并写入包名。

## 签名

构建脚本使用 `CODE_SIGN_IDENTITY="-"`（ad-hoc 签名）。如需正式签名：

1. 修改脚本中的 `CODE_SIGN_IDENTITY` 为你的开发者证书 ID
2. 或构建后手动签名：
   ```bash
   codesign --force --deep --sign "Developer ID Application: Your Name" \
     AntigravityProxyLauncher.app
   ```

## 单独构建

### 仅 dylib

```bash
cd AntigravityTun
xcodebuild -project AntigravityTun.xcodeproj -scheme AntigravityTun \
  -configuration Release -arch arm64 CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

### 仅 Go 代理

```bash
cd tools/mitm_proxy
go build -o mitm_proxy .
```

### 仅 Swift App（SwiftPM）

```bash
cd launcher
swift build
```

## 调试运行

```bash
cd launcher
swift build && open .build/debug/AntigravityProxyLauncher
```
