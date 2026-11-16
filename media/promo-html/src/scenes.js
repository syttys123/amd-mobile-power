// Scene timing and ordering. The recorder reads this through window.__SCENES__.
window.__SCENES__ = [
  {
    id: "hook",
    duration: 4.5,
    narration: "同一台笔记本，插电和用电池的时候，性能和续航差别往往很大。",
  },
  {
    id: "problem",
    duration: 5.5,
    narration: "例如插电时选四十五瓦，日常使用选二十五瓦，想省电时选十瓦。预设可以编辑，实际效果取决于机型和固件。",
  },
  {
    id: "ui-demo",
    duration: 11.0,
    narration: "点击预设，回读确认。目标、当前功耗与实际生效上限分开显示，遇到固件限制会明确提示。",
  },
  {
    id: "auto-policy",
    duration: 6.0,
    narration: "嫌手动切换麻烦，可以打开自动策略：插上电源自动切到高性能，拔掉电源自动切到省电。",
  },
  {
    id: "safety",
    duration: 5.5,
    narration: "首次启动默认只读。要启用修改，点右上角的锁，阅读并勾选须知，再确认启用写入。",
  },
  {
    id: "compat",
    duration: 5.0,
    narration: "目前已在一台 Ryzen 7 8845HS 笔记本实测。其他 AMD 机型请先查看识别结果，并导出诊断协助验证。",
  },
  {
    id: "closing",
    duration: 5.0,
    narration: "项目完全开源免费，欢迎去 GitHub 下载试用，也欢迎告诉我们你的机型。",
  },
];
