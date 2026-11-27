# PM2.5 视觉采集记录仪 · A1.2 PoC

Flutter 工程，目标平台 Android / Windows。当前是**业务闭环 + 原生验证原型，不是可验收的 V1.0 安装包**。真实采集入口保持禁用；演示必须手动进入，页面和导出文件名均标记演示，不使用真实摄像头或模型。

## 运行

使用 Flutter **3.41.9 / Dart 3.11.5**，Android 构建需 Android SDK 和 JDK 17；Windows 原生构建需 Visual Studio 的「使用 C++ 的桌面开发」和 Windows SDK。

```powershell
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter run -d windows
# 或连接 Android 真机后：
flutter devices
flutter run -d <device-id>
```

打开应用后：**新建批次 → 进入离线演示 → 使用演示 ROI（也可拖画）→ 开始演示 → 暂停/继续或停止 → 回放 / 复核 / 导出**。默认 1 秒；2/5 秒可在设置中显式选择并用于演示，真实端不得在没有设备验收记录的情况下放行。

## 实现范围

- 批次与 ROI 管理：任意数量的归一化矩形（采集仍受实测设备档位约束），设备编号去重，支持拖动、四角缩放、删改、模板保存和复用。
- 按单调时钟安排节拍，单飞执行，处理截止时间为采样周期的 80%；逾期推理结果不写入，错过的节拍不补采。失败 ROI 留空而不影响其他 ROI。
- Drift / SQLite：单轮事务、计划/实际时间、批次状态恢复、人工修改和原始值分离、级联删除、日志。
- 实时和历史曲线，有界降采样，历史表格筛选和分页、修正和备注；系统保存对话框导出 Excel 兼容的 UTF-8 BOM CSV 及失败日志。关闭应用再启动，未正常结束的批次关闭并保留已写入数据。
- Android CameraX 纹理预览、保留最新帧策略、采样用 Y 平面 PoC；可选 ONNX 模型验证选中 ROI，不入库。Windows Media Foundation 纹理预览 PoC（选择首个可用摄像头，尝试 720p，RGB32）和可选 ONNX 单 ROI 探针。未将完整视频帧通过 MethodChannel 送入 Dart。上传未实现、离线运行。

## Android REC 模型试装（非正式采集）

从项目训练产物提供 `android/app/src/main/assets/rec.onnx` 和 `android/app/src/main/assets/rec.json`，重新构建并安装。模型需要单输入 float32 `1×1×H×W`，单输出 float32 `1×T×12` 的 **CTC logits**；类别依次是 blank、`0–9`、`.`。预处理为 CameraX 裁剪后亮度通道、按旋转映射 ROI、最近邻拉伸，像素值计算是 `(Y/255 - mean)/scale`。配置例（尺寸仅示例，按模型填写）：

```json
{"width": 160, "height": 48, "mean": 0.5, "scale": 0.5}
```

打开相机后画框并点击「测试选中 ROI（不入库）」。没有提供训练模型和标注样本；不应直接替换为不符合输入/输出的 PP-OCR 模型。探针分数是被保留字符的平均 softmax 分数，不是经校准的准确率。

## Windows REC 模型试装（非正式采集）

准备与目标架构一致的 ONNX Runtime Windows CPU SDK。设置 `PM25_ORT_ROOT` 指向含 `include`、`lib` 的目录，在干净的 CMake 构建目录中执行 `flutter build windows`。将同一契约的 `rec.onnx` 和 `rec.conf` 放在生成的 `pm25_capture.exe` 同一目录；`rec.conf` 为四个空白分隔的值 `宽 高 mean scale`，例如 `160 48 0.5 0.5`。Windows 使用 RGB32 转换后的全范围亮度，不能直接假定与 CameraX Y 数据分布一致，两端须分别校准。配置正确后，同样通过「测试选中 ROI（不入库）」验证。没有设置 `PM25_ORT_ROOT` 时构建只包含 Windows 相机预览，不包含 REC 运行时。

## 交付门槛（未完成）

- Android 真机预览方向/裁剪映射、ROI AF/AE 的实际锁定确认、权限及前后台；Windows UVC 摄像头型号/模式选择、断连/休眠、REC 运行库打包及推理实测。
- 目标平台及低配设备的支持清单、各配置真实采集前校验和启用、失败快照、相机调优参数、正式包与 SQLite 运行库验证。
- 用带真值的样本校准模型和置信度；实测 1/3/5 ROI 各阶段和端到端 P95、丢拍、精度、内存、双端连续 4 小时。未测试的组合不得标为支持，不启用静默降级。


### Android v0.2.0 取景与旧模板

新版 Android 以设备原生方向（display rotation 0）的 CameraX ViewPort 保存 ROI，竖横屏旋转只改变显示坐标；分析帧和预览使用同一 ViewPort。0.1.0 旧模板未记录创建方向和裁剪参数，请在真机上核对实际对齐情况，必要时重画并另存。

## v0.3.0 浅色界面与打包

- `lib/lab_style.dart` 统一浅色背景与白色卡片。钴蓝 `#2454D6` 用于主操作和图表首个系列，淡紫用于辅助信息，琥珀用于演示标记和告警，错误与正常状态分别用红、绿，并保留文字说明。
- 排版使用平台系统字体及本地语言回退：34 主标题、21 区块标题、14 正文、12 辅助文字，读数和图表刻度优先使用等宽数字。未打包 Apple 字体或图标资源。
- 监控及回放使用指标卡、趋势图 / 记录表分段入口；CSV、失败日志与日志查询集中到「更多」。曲线保留真实采样折线，不插值，点按读数可复核。采集门槛、数据格式与采集节拍不变。
- 返回首页时重新加载批次列表；预览用例覆盖首页 → ROI → 返回首页 → 历史回放及曲线 / 表格切换。

```powershell
flutter analyze
flutter test
# 设置 JAVA_HOME 与 ANDROID_SDK_ROOT 后执行（Build Tools 35.0.0，可通过参数覆盖）
.\scripts\package-android.ps1
```

打包脚本读取 `pubspec.yaml` 版本，构建 release APK，验证签名和版本元数据后才发布到 `artifacts`，并打印 SHA-256。默认使用工程现有的测试签名，仅用于侧载测试。受限网络环境可显式指定本机的 `-GradleInitScript` 使用已缓存仓库；`-SkipLintVitalRelease` 仅用于显式跳过缓存构建中的 Gradle lint，不替代 `flutter analyze` 和测试。

Windows 导出效果图（模拟取景、合成读数）：将 `PM25_FLUTTER` 设置为 Flutter SDK 路径，然后运行 `flutter test --dart-define=EXPORT_PM25_PREVIEWS=true`；图片保存到 `artifacts`。效果图使用本机中文字体，APK 内使用系统字体。
# ocr-view
