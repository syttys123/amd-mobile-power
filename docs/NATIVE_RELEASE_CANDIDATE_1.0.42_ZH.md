# AMD Mobile Power 1.0.42 原生候选审查说明

状态：`STABLE_LOCAL_DEPLOYED_PENDING_PUBLICATION`

本文是当前 `1.0.42` 的发布审查入口，不是公开 Release 或上传授权。
更完整的门禁记录见 [NATIVE_RC_STATUS.md](NATIVE_RC_STATUS.md)，逐项状态见
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。

## 包与部署身份

- 源码提交：`927a1bbf74e78b061eafb6088e807f4fc5ff365b`
- ZIP：`artifacts/native-packages/amd-mobile-power-v1.0.42-win-x64-native-preview.zip`
- 大小：795,340 bytes
- SHA256：`35384501e2cf4b5808ba8796d212fb4b7394d49455153e817fefed1c11b44998`
- GUI：`612a883e89bb33cb2ef538cb86a833f3073c8f6144a54ecd2efe1bc35a1d0baf`
- worker：`ffec2afc798ba39026857cd1cc287dcdbb2a268e5b53314756b35bef83a8cf0d`
- probe：`00369735f7d3623592ad4806973a115161744e42c304ca3cbd52d322300ec353`
- 稳定本地目录：`C:\RyzenAdj`
- 上一稳定版回滚：`C:\RyzenAdj.before-20261118-054742205-v1.0.41-6bf8144`

## 本版重点

1. 自动策略分别记录观察、尝试和成功应用的供电线路；手动目标不再冒充
   自动策略目标。
2. 维护脚本要求新鲜的成功尝试和匹配线路，拒绝把旧观察结果当成新写入。
3. 晋升流程绑定 ZIP/源码身份并核对全部载荷校验和，失败时恢复旧树并留下
   审计证据；支持盘符直属安装目录。
4. 保留默认只读、勾选须知后解锁、写入回读、固件钳制提示、可编辑预设、
   电池/外接策略、仅电池、托盘、诊断导出和便携安装流程。

## 已验证边界

- Rust GUI 74 项、probe 7 项、C++ 策略/清理/安全测试、格式和 Clippy。
- 清洁构建、逐字节可复现、隔离安装/卸载、shell 集成、公开材料脱敏。
- worker 卡死替换、当前值无变化策略、DPI/短工作区/最大化夹具。
- 一台 MECHREVO WUJIE15 PRO / Ryzen 7 8845HS 的受控实机证据。
- 托管 Windows CI run `44181123711` 对应当前源码提交并通过。

其他 AMD 世代仍是保守实验配置。第二台物理设备、真实系统 DPI 切换和
干净 Windows 的 WinRing0 基线尚未完成，不能据此宣称全型号兼容。

## 当前本机策略

- 07:00–23:00：电池 25 W，外接 45 W。
- 23:00–07:00：电池和外接均 15 W。
- 充电宝通常被 Windows 识别为外接电源，程序不能可靠区分充电宝与墙插。

这些是运行状态，不是安装包的全局硬编码默认值。媒体录制使用隔离模拟数据，
没有改动稳定托盘或硬件策略。

## 宣传审查物料

- 视频：`artifacts/media/promo-1.0.42-review-final2/amd-mobile-power-1.0.42-review-silent.mp4`
- 规格：55.0 秒，1920×1080，30 fps，1650 帧，H.264，无音轨。
- SHA256：`52aeee33e4e308a2d4b9e107e5a526c54402f7d61b44c1dda811670bb50759dc`
- 封面：`assets/bilibili-cover-1.0.42-2026-11-18.png`
- 联系表：`assets/native-promo-1.0.42-contact-sheet-2026-11-18.png`
- 文案：[NATIVE_LAUNCH_COPY_1.0.42_ZH.md](NATIVE_LAUNCH_COPY_1.0.42_ZH.md)
- 媒体证据：`evidence/media/native-promo-1.0.42-review-2026-11-18.json`

视频展示确认解锁、25/45/10 W 即时预设、10→12 W 编辑、双线/仅电池策略、
固件限制和诊断导出。它不声称录到了真实拔插电，也不把模拟回读当成新的
实机兼容证据。独立代理视觉审核因上游额度不足未能完成，主流程自动化检查
通过不等于项目所有者审片通过。

## 仍需人工确认

- [ ] 项目所有者审核视频节奏、字幕、功能口径、封面和发布文案。
- [ ] 明确批准 GitHub Release。
- [ ] 明确批准并使用已登录账号上传 B 站。
- [ ] 有条件时补齐第二台 AMD 设备、真实 DPI 会话和干净 Windows 驱动基线。

未经以上授权，不创建公开 Release、不上传视频、不改动远端发布状态。
