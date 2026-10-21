# DualCam 双摄相机

iPhone 双摄原生相机（Swift / SwiftUI，基于 `AVCaptureMultiCamSession`，iOS 17+）。两个摄像头同时取景，实时合成为画中画或上下分屏，界面参照系统相机。

> 状态：代码通过 GitHub Actions 云端编译，**尚未在真机上完整测试**。多摄支持因机型而异（需要 iPhone XS / XR 及以上），部分镜头组合、60 帧、最高分辨率在不同机型上可能自动退回较低规格。

## 功能

**界面（仿 iPhone 相机）**

- 顶部：闪光灯 / 实况 / 夜景（弱光增亮），选中为黄色
- 预览：3:4 取景，三分参考线；底部焦段条 `.5  1×  2  5`；左上角小胶囊点一下循环切换保存方式
- 底部：缩略图（点开「照片」）· 视频 / 照片切换 · 换主副画面；快门左侧是布局（画中画 ↔ 上下分屏），右侧是更多设置

**焦段 0.5 / 1 / 2 / 5**

每一档自动选「倍率不超过它」里最长的后置镜头，不够的部分用数码变焦补：

| 档位 | 有对应镜头时 | 没有时 |
| --- | --- | --- |
| 0.5 | 超广角 | 不显示这一档 |
| 1 | 广角 | — |
| 2 | 长焦（本身就是 2×）| 广角 2× 数码变焦 |
| 5 | 长焦（5× 机型直接用）| 3× 长焦 ×1.67，或广角 5× 数码变焦 |

同一颗镜头内切换只改变焦；换镜头会重建会话，画面会短暂停顿。录像中只能在同一颗镜头内切换。捏合变焦只在当前镜头范围内连续变化。

**原图直出 / 合成画面 / 两者都存**

- 原图直出（默认）：每颗镜头各存一份，**不合成、不加滤镜、不镜像、不裁切**
- 合成画面：只存预览里看到的样子（画中画 / 分屏 + 滤镜）
- 两者都存

照片、视频都按这个规则保存。注意：双摄同时工作时，系统只开放「多摄支持」的格式，原图分辨率是这些格式的最大值（通常最高到 4K 视频级别），**不是单摄的 48MP / ProRAW**。

**实况照片**

每张照片配一段约 1.6 秒的短视频，写入系统「照片」后就是实况照片（长按播放）。原图模式下两颗镜头各一张实况，合成模式下存一张合成实况。限制：目前是「按下快门后」录 1.6 秒，没有快门前的预录。

**视频**：HEVC，带声音；可同时录合成视频和每颗镜头的原始视频；录像中可随时切布局、拖小窗、换滤镜。

**其他**：小窗拖动 / 缩放 / 形状 / 边框，12 个实时滤镜，主副镜头分别设置曝光 / ISO / 快门 / 白平衡 / 对焦，点按对焦，定时器，画幅 3:4 / 9:16 / 1:1，分辨率 720p / 1080p / 最高，30 / 60 帧，视频防抖。

## 云端编译与签名

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成，不用 Mac。每次推送到 `main`（或在 Actions 页点 **Run workflow**），GitHub 的 macOS 服务器会编译，把 IPA 发布到 **Releases**。

### 方式 A：未签名 IPA + Sideloadly（免费 Apple ID，默认）

不配置任何密钥时产出未签名 IPA：

1. 在 Releases 下载 `DualCam.ipa`
2. 电脑装 [Sideloadly](https://sideloadly.io)，iPhone 连电脑并点「信任」
3. 把 IPA 拖进 Sideloadly，填 Apple ID，点 Start（它会用你的 Apple ID 完成签名）
4. 手机：设置 → 通用 → VPN 与设备管理 → 信任证书；设置 → 隐私与安全性 → 开发者模式 → 打开并重启

免费 Apple ID 签名的 App 每 7 天过期，重新装一次即可。

### 方式 B：在云端直接签名（付费开发者账号）

需要付费的 Apple Developer 账号。在仓库 **Settings → Secrets and variables → Actions** 添加：

| Secret | 内容 |
| --- | --- |
| `IOS_CERT_P12_BASE64` | 开发 / 发布证书导出的 `.p12`，转成 base64 |
| `IOS_CERT_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `IOS_PROVISION_PROFILE_BASE64` | `.mobileprovision` 描述文件，转成 base64 |

base64 转换：macOS 用 `base64 -i 文件 | pbcopy`；Windows 用 `certutil -encode 文件 out.txt`，去掉首尾的 BEGIN / END 行后整段粘贴。

配好后 workflow 会自动检测并改成签名构建：Team ID、Bundle ID（取自描述文件；通配符描述文件用 `com.dualcam.app`）和签名方式（开发 / Ad Hoc）都从描述文件里读取，产出的 IPA 可直接安装到描述文件里登记过的设备。

## 本地构建

```bash
brew install xcodegen
xcodegen generate
open DualCam.xcodeproj
```

在 Xcode 里选自己的 Team，把 `com.dualcam.app` 改成唯一的 Bundle ID，连接支持多摄的 iPhone 运行，允许相机、麦克风、照片权限。

## 目录

- `DualCam/Camera/`：相机会话（`CameraManager`）、画面合成（`Compositor`）、视频 / 实况写入（`VideoRecorder`）、滤镜、数据模型
- `DualCam/UI/`：取景界面、工具面板、预览层
- `project.yml`：XcodeGen 工程描述
- `.github/workflows/build-ipa.yml`：云端编译、签名、发布
