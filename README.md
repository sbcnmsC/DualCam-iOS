# DualCam 双摄相机

iPhone 单摄 / 双摄原生相机（Swift / SwiftUI，基于 `AVCaptureMultiCamSession`，iOS 18+）。支持单摄、画中画和上下 / 左右分屏，双摄模式下两路同时取景并实时合成。

> 状态：代码通过 GitHub Actions 云端编译，**尚未在真机上完整测试**。多摄支持因机型而异（需要 iPhone XS / XR 及以上），部分镜头组合、60 帧、最高分辨率在不同机型上可能自动退回较低规格。

## 功能

**界面（仿 iPhone 相机）**

- 顶部：闪光灯 / 实况 / 夜景（弱光增亮），选中为黄色
- 预览：3:4 取景，三分参考线；底部焦段条 `.5  1×  2  5`；左上角小胶囊点一下循环切换保存方式
- 底部：缩略图（点开「照片」）· 视频 / 照片切换 · 换主副画面；快门左侧布局按钮循环切换（画中画 → 分屏 → 单摄），右侧是更多设置

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

- 原图直出：关闭实况照片后，通过临时单摄 `AVCaptureSession` 选择传感器支持的最大静态照片格式，并由 `AVCapturePhotoOutput` 保存原片；双摄布局分别拍摄两路，单摄布局只拍摄当前选中的镜头。原片**不合成、不加滤镜、不镜像、不裁切**。每次拍摄会短暂停止取景，再自动恢复。
- 合成画面（默认）：只存预览里看到的样子（画中画 / 分屏 + 滤镜）
- 两者都存

照片、视频都按这个规则保存。静态原片使用真实照片输出数据，而不是把视频帧放大；照片尺寸由当前镜头支持的最大单摄静态格式决定，具体上限因设备、镜头和系统而异，不保证所有机型都能输出 48MP / ProRAW。合成照片以主镜头静态原片为底图，副画面使用双摄实时视频帧，因此副画面的细节仍受视频采集规格限制。

**实况照片**

开启实况照片时，为保证静态图与动态片段匹配，两路原片仍使用双摄兼容的视频帧分辨率；关闭实况照片后，原图模式会为每个镜头分别切换到单摄高清静态拍摄会话。切换会带来短暂预览中断，完成后自动恢复双摄。该通道的最大尺寸由当前设备格式决定，不承诺所有机型均可输出 48MP 或 ProRAW。

每张照片配一段约 1.6 秒的短视频，写入系统「照片」后就是实况照片（长按播放）。原图模式下两颗镜头各一张实况，合成模式下存一张合成实况。限制：目前是「按下快门后」录 1.6 秒，没有快门前的预录。

**实况动态取自哪颗镜头**

合成图的实况，静态图始终是合成图，长按播放的 1.6 秒可以选三种来源：合成画面（默认）、主摄、副摄（小窗）。开启实况后，顶栏会多出一颗按钮循环切换，设置面板里也有同样的选项。选「副摄」就能在系统相册里长按合成照片，看到小窗那颗镜头的画面；这是一段视频，分辨率是双摄视频规格，不是高清静态照片。

单镜头的动态片段会按预览同样的方式处理（前置镜像、滤镜），并裁成静态图的画幅，避免系统相册播放时变形。「两者都存」时，两张原片的实况仍各自取自自己的镜头，只有合成图那张按这个选项走；「原图直出」没有合成图，这个选项不生效。

**3D 实况（LiDAR + ARKit Mesh + 真正的 3D Gaussian Splatting）**

- 进入 3D 实况会暂停普通相机会话，由 ARKit / RealityKit 使用 LiDAR。ARKit 开启 \`.meshWithClassification\` 场景重建和水平 / 垂直平面检测，扫描画面显示实时场景网格。
- 扫描页统计 ARKit 网格面片的分类样本：地面、墙面、天花板、桌面、座椅、门、窗。它是 ARKit 的空间表面分类，不等同于通用目标检测或任意物体识别。
- 采集最多 96 个有效关键帧。只有相机追踪状态正常时才保存，位姿变化阈值约 3.5 cm / 5°；LiDAR 过滤低置信度像素，并在深度突变处剔除边缘飞点。深度点融合为初始 Gaussian 时，椭球切向由局部深度邻域估计，不再统一沿相机朝向。
- 每次扫描以 JPEG 质量 0.92 保存 RGB 关键帧、Float32 深度、相机内参和 camera-to-world 位姿，并生成 Nerfstudio 兼容的 \`transforms.json\`。提高关键帧压缩质量，保留多视角光度优化所需的纹理细节；这是训练阶段的输入，不是仅供展示的 PLY。
- 采集完成后可在设备端启动 \`msplat\` Metal 训练，支持 1K / 2K / 4K 步数；默认半分辨率，包含多视角光度优化、Gaussian densification、球谐颜色拟合。训练过程周期性生成预览，监控可用内存；可安全停止并导出当前结果。
- 训练启用 `keepCrs`，导出的 Gaussian PLY / SPZ 恢复到原始 ARKit 世界坐标；因此 MetalSplatter 预览使用的 `session.json` 场景包围盒和训练产物坐标一致，避免训练完成后场景偏移或缩放错误。训练结果优先以优化后的 Gaussian PLY 预览，也可导出压缩 SPZ；LiDAR 初始化 PLY 仍可单独分享，用于诊断采集覆盖和数据质量。
- **设备要求**：需要支持 ARKit Scene Depth / Scene Reconstruction 的 LiDAR 设备。msplat 训练引擎最低要求 iOS 18；因此此功能分支的 App 最低系统版本调整为 iOS 18。训练时会暂停 ARKit 相机以降低 GPU 争用；当可用内存低于保护阈值或设备温度达到 serious 热状态时，会阻止训练启动或停止迭代，并尝试导出已有结果。
- 第三方依赖固定版本：\`MetalSplatter\`（MIT）和 \`msplat-ios\`（Apache 2.0）；许可证副本分别保存在 \`ThirdPartyLicenses/\`。
**视频**：HEVC，带声音；可同时录合成视频和每颗镜头的原始视频；录像中可随时切布局、拖小窗、换滤镜。

**其他**：小窗拖动 / 缩放 / 形状 / 边框，14 个实时滤镜（新增海边、人文风格），主副镜头分别设置曝光 / ISO / 快门 / 白平衡 / 对焦，点按对焦，顶部定时器图标（关 / 3 秒 / 10 秒），画幅 9:16 / 3:4 / 1:1 / 16:9 / 21:9 / 全屏自由，分辨率 720p / 1080p / 最高，30 / 60 帧，视频防抖。

## 云端编译与签名

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成，不用 Mac。推送到 workflow 已配置的功能分支（包括 `feature/single-dual-gaussian-3dlive-2026-11-24`），或在 Actions 页点 **Run workflow**，GitHub 的 macOS 服务器会编译并上传 IPA 构建产物；仅 `main` 分支会发布 Release。

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

先生成 iOS 要求的 1024×1024 PNG 图标（矢量母版保留在 `scripts/DualCam-AppIcon.svg`）：

```bash
brew install cmake xcodegen librsvg
mkdir -p Vendor
git clone https://github.com/frs0n/msplat-ios.git Vendor/msplat-ios
git -C Vendor/msplat-ios checkout e8611098583059b82e0b7d35259fb4e9c42df248
# Xcode 16 on macos-15 supports Metal 3.2; the shader path does not require Metal 4-only APIs.
sed -i '' 's/set(MSPLAT_METAL_LANGUAGE_STANDARD "metal4.0" CACHE STRING/set(MSPLAT_METAL_LANGUAGE_STANDARD "metal3.2" CACHE STRING/' Vendor/msplat-ios/CMakeLists.txt
BUILD_JOBS=4 IOS_DEPLOYMENT_TARGET=18.0 bash Vendor/msplat-ios/scripts/build-xcframework.sh
./scripts/generate-app-icon.sh
xcodegen generate
open DualCam.xcodeproj
```

在 Xcode 里选自己的 Team，把 `com.dualcam.app` 改成唯一的 Bundle ID，连接支持多摄的 iPhone 运行，允许相机、麦克风、照片权限。

## 目录

- `DualCam/Camera/`：相机会话（`CameraManager`）、画面合成（`Compositor`）、视频 / 实况写入（`VideoRecorder`）、滤镜、数据模型
- `DualCam/UI/`：取景界面、工具面板、预览层
- `DualCam/Spatial/`：ARKit LiDAR / 分类网格采集、Nerfstudio 数据导出、msplat 端侧训练、Gaussian PLY / SPZ 与 Metal 场景查看器
- `ThirdPartyLicenses/`：MetalSplatter（MIT）与 msplat（Apache 2.0）许可证
- `project.yml`：XcodeGen 工程描述
- `scripts/DualCam-AppIcon.svg`：应用图标矢量母版；构建前生成至 `DualCam/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- `.github/workflows/build-ipa.yml`：云端编译、签名、发布
