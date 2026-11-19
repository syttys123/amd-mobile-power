// Frame-exact storyboard. Every GUI clip is an isolated 1.0.43 fixture.
window.__SCENES__ = [
  { id: "hook", duration: 3.5, narration: "同一台 AMD 轻薄本，插电要性能，电池想省一点。" },
  { id: "safety", duration: 8.5, narration: "默认只读。先阅读并勾选须知，再确认解锁；随时可以重新锁定。", clip: "consent" },
  { id: "ui-demo", duration: 11.5, narration: "点一下预设就会应用并核对。示例依次切换 25 W、45 W 和 10 W。", clip: "simple" },
  { id: "presets", duration: 7.0, narration: "三档都能改。这里把 10 W 改成 12 W，保存后再应用。", clip: "presets", clipOffset: 0.7, clipEnd: 7.8 },
  { id: "auto-policy", duration: 9.0, narration: "自动策略可设电池 25 W、外接 45 W；也可勾选仅电池，让外接不写入。", clip: "policy", clipOffset: 0.5, clipEnd: 9.6 },
  { id: "firmware", duration: 4.5, narration: "请求 12 W，固件可能只给 10 W。界面分开显示目标与实际回读。" },
  { id: "compat", duration: 7.0, narration: "诊断可一键导出，不包含路径、账号或进程信息。目前仅一台 8845HS 完整实测。", clip: "diagnostics" },
  { id: "closing", duration: 4.0, narration: "开源免费，便携运行。其他机型请先看识别结果，再从小数值试用。" },
];
