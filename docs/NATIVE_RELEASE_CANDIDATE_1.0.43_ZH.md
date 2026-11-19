# AMD Mobile Power 1.0.43 原生候选审查说明

状态：`STABLE_LOCAL_DEPLOYED_PENDING_PUBLICATION`

本文是当前 `1.0.43` 的发布审查入口，不是公开 Release 或上传授权。
更完整的门禁记录见 [NATIVE_RC_STATUS.md](NATIVE_RC_STATUS.md)，逐项状态见
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。

## 包与部署身份

- 源码提交：`bbe5e1421387bba21c67bfa51accf824b214f22a`
- ZIP：`artifacts/native-packages/amd-mobile-power-v1.0.43-win-x64-native-preview.zip`
- 大小：803,432 bytes
- SHA256：`663f49eba5a0506bcacc2830104f48f5f13943372b51f65a84deb137c2c3f6f4`
- GUI：`84bfa2673a6a8d3a9c40ca40110ca2ca815b0d191638f98d5784f1f1408fe933`
- worker：`ffec2afc798ba39026857cd1cc287dcdbb2a268e5b53314756b35bef83a8cf0d`
- probe：`3e9460477921741a5f959bb86b38c05a0a5bf3b7cd1f71bfbfe5d71841b511ef`
- 稳定本地目录：`C:\RyzenAdj`
- 上一稳定版回滚：`C:\RyzenAdj.before-20261120-052000-v1.0.42-927a1bb`
- 托管 Windows CI：run `44620445052`（head `d88b356`，包含本包源码提交）

## 本版重点

1. 简洁模式导出诊断后不再出现悬空的“诊断已导出：”。单行状态栏会去掉
   行尾分隔符，完整路径仍保留在高级模式。
2. 发布门禁在独占硬件阶段停止并禁用三个 `AmdMobilePower` 计划任务，结束
   后在 `finally` 中恢复，避免五分钟巡检重启托盘、与隔离 worker 争抢
   RyzenAdj 所有者互斥量。
3. 其余默认只读、勾选须知后解锁、写入回读、固件钳制提示、可编辑预设、
   电池/外接策略、仅电池、托盘、诊断导出和便携安装流程保持不变。

## 已验证边界

- Rust GUI 单元测试 38 项、probe 7 项、C++ 策略/清理/安全测试、格式和 Clippy。
- 清洁构建、逐字节可复现、隔离安装/卸载、shell 集成、公开材料脱敏。
- worker 卡死替换、当前值无变化策略、DPI/短工作区/最大化夹具。
- 一台 MECHREVO WUJIE15 PRO / Ryzen 7 8845HS 的受控实机证据。
- 托管 Windows CI run `44620445052` 对应推送头并通过。

其他 AMD 世代仍是保守实验配置。第二台物理设备、真实系统 DPI 切换和
干净 Windows 的 WinRing0 基线尚未完成，不能据此宣称全型号兼容。

## 当前本机策略

- 07:00–23:00：电池 25 W，外接 45 W。
- 23:00–07:00：电池和外接均 10 W。
- 充电宝通常被 Windows 识别为外接电源，程序不能可靠区分充电宝与墙插。

这些是运行状态，不是安装包的全局硬编码默认值。媒体录制使用隔离模拟数据，
没有改动稳定托盘或硬件策略。

## 宣传审查物料

- 视频：`artifacts/media/promo-1.0.43-review/amd-mobile-power-1.0.43-review-silent.mp4`
- 规格：55.0 秒，1920×1080，30 fps，1650 帧，H.264，无音轨。
- SHA256：`d795f85054531b7a8bf69e6bd693de8da6a681d168d0b9c49842f0ce4d75f181`
- 封面：`artifacts/media/promo-1.0.43-review/bilibili-cover-1.0.43-2026-11-20.png`
- 联系表：`artifacts/media/promo-1.0.43-review/native-promo-1.0.43-contact-sheet-2026-11-20.png`
- 文案：[NATIVE_LAUNCH_COPY_1.0.43_ZH.md](NATIVE_LAUNCH_COPY_1.0.43_ZH.md)
- 媒体证据：`evidence/media/native-promo-1.0.43-review-2026-11-20.json`

视频展示确认解锁、25/45/10 W 即时预设、10→12 W 编辑、双线/仅电池策略、
固件限制和诊断导出，兼容场景的状态栏已显示完整的“诊断已导出”。它不声称
录到了真实拔插电，也不把模拟回读当成新的实机兼容证据。独立代理视觉审核
因上游额度不足未能完成，主流程自动化检查通过不等于项目所有者审片通过。

## 仍需人工确认

- [ ] 项目所有者审核视频节奏、字幕、功能口径、封面和发布文案。
- [ ] 明确批准 GitHub Release。
- [ ] 明确批准并使用已登录账号上传 B 站。
- [ ] 有条件时补齐第二台 AMD 设备、真实 DPI 会话和干净 Windows 驱动基线。

未经以上授权，不创建公开 Release、不上传视频、不改动远端发布状态。
