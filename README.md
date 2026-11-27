# PM2.5 视觉采集记录仪

Flutter 本地实验室采集工具。Android 使用 CameraX 后摄；Windows 使用 Media Foundation UVC。两端均需安装与设备匹配的离线数字 REC 模型。原生适配器裁剪和推理，仅向 Flutter 返回采样时间、逐 ROI 结果和可选的失败 ROI 小图，不传输视频整帧。

**交付状态：工程实现待真机验收。** Android 已随包提供官方 PaddleOCR REC 权重；仓库不包含正式真值集或已通过验收的设备档位。未登记的设备组合不会在正式构建中开放采集。没有演示采集入口；已保存的旧演示批次仍可回放和导出，并保持演示标记。

## 开发与真机验证

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=PM25_HARDWARE_VALIDATION=true
flutter build windows --release --dart-define=PM25_HARDWARE_VALIDATION=true
```

`PM25_HARDWARE_VALIDATION=true` 仅用于现场测量未验档位，禁用于正式构建；该设置不跳过模型、真实帧、相机锁定/固定模式和存储检查。验证批次及界面明确标记。正式构建省略该 define，仅允许已验收的精确 ROI 数量 / 周期组合。2 秒与 5 秒须显式选择，不自动降档。ADB 安装后，断网打开应用，通过「建立测试 → 连接真实相机 → 框选 ROI → 相机调优（Android）→ 开始采集」进行验证。

## 正式模型资产

- **Android：** APK 自带 PaddlePaddle 官方 [en_PP-OCRv5_mobile_rec ONNX 导出](https://huggingface.co/PaddlePaddle/en_PP-OCRv5_mobile_rec_onnx/tree/3fafbc3b5dcf93dd72add9f48368be8a3a2cd33b)，固定提交 `3fafbc3b5dcf93dd72add9f48368be8a3a2cd33b`（Apache-2.0）。构建和加载分别检查 ONNX、CTC 字典、原始配置的 SHA-256。模型仅识别、不检测：输入 `1×3×48×320` BGR，等比缩放、右侧填充；按字典解码 438 类 CTC 概率，只接受完整十进制数字。无需联网或手动复制模型。发布构建只开放已实测登记的组合；当前验收包可在 AF/AE 确认锁定后直接开始真实采集。
- **Android 方向：** 从 CameraX 同一分析视口定向渲染预览，纹理不再接收相机隐式传感器旋转。Dart 仅应用屏幕旋转差量；ROI 手势、识别、快照与对焦/测光点均按同一视口换算。旧模板需在新预览核对、必要时重画。验收通过后才填 `accepted-profiles.json`：`fingerprint`、`cameraId`、`modelSha256`、`runtimeVersion`、`width`、`height`、`periodMs`、`roiCount`。
- **Windows（本轮未变更）：** 现有 Windows 适配器仍使用 `1×1×H×W` 灰度和 `1×T×12` CTC logits，`rec.dict` 内容为 `0123456789.`；不可直接用新版 Android 权重替换。
- **Windows：** 设置 `PM25_ORT_ROOT` 指向目标 x64 ONNX Runtime SDK，`PM25_WINDOWS_ASSETS` 指向含 `rec.onnx`、`rec.dict`、`rec.conf`、`uvc.conf` 的离线资产目录；在干净的 Windows 构建目录编译。`rec.conf` 首行是 `width height mean scale version sha256`。`uvc.conf` 首行是 `"UVC符号链接" width height fps分子 fps分母 {原生媒体子类型GUID} modelSha256 runtimeVersion "计算机名"`，带引号的字段使用 C++ `std::quoted` 转义（反斜杠写两遍）。链接来自 Media Foundation 的 `MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK`。后续每行是已经通过验收的 `periodMs roiCount`，测量包可留空。安装时应用把档位与实际连接设备、原生模式、模型和运行库匹配。固定模式不代表 AF/AE 锁定；实际曝光和对焦工位配置须在现场单独核查。

Windows CMake 将资产及运行库复制进发布目录。安装器定义位于 `scripts/windows-installer.iss`：使用 Inno Setup 6 的 `ISCC.exe` 编译，传入 `/DBundleDir=<正式构建 Release 目录>`、`/DAppVersion=<版本>`、`/DVcRedist=<离线微软 x64 VC++ 运行库安装文件>`。不要打包带 `PM25_HARDWARE_VALIDATION` 的验证构建。发布包仍需签名；在目标干净系统验证安装、断网运行及卸载，不同用户的本地批次数据不能随卸载误删。

## 数据与验收

- 单批次保存 1–8 个 ROI，按单调时钟固定节拍；超时只记丢拍，不写入有效值。相机断流、锁定失效、存储不足或 Android 切后台会安全停止。
- 原始值与人工修正值分存。启用失败快照后，只在失败事件中保存 96×32 的 ROI 灰度 PGM（失败日志 CSV 中的 `snapshotPgmBase64`）；默认关闭。
- 升级保留已有批次、记录和旧模板。旧模板方向未知时，须在真实预览检查并重新保存；旧模板超过 8 个框时不得导入采集。
- 现场步骤、指标及证据项见 [设备验收清单](docs/device-acceptance.md)。
