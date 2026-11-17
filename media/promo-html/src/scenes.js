// Scene timing and ordering. The recorder reads this through window.__SCENES__.
window.__SCENES__ = [
  {
    id: "hook",
    duration: 4.0,
    narration: "同一台轻薄本，插电想快，电池想省。",
  },
  {
    id: "safety",
    duration: 5.0,
    narration: "默认只读，不解锁就不会动硬件。要修改，先勾选须知再确认。",
  },
  {
    id: "ui-demo",
    duration: 10.5,
    narration: "点一下预设，立即应用并自动核对。瓦数可以按机型修改。",
  },
  {
    id: "firmware",
    duration: 4.5,
    narration: "固件可能压低上限。界面显示实际值，以回读为准。",
  },
  {
    id: "auto-policy",
    duration: 6.0,
    narration: "解锁后设好电池和插电瓦数，插拔自动切换。也可以只管电池。",
  },
  {
    id: "compat",
    duration: 5.0,
    narration: "仅一台 8845HS 实测。其他机型先看识别结果，再导出诊断。",
  },
  {
    id: "closing",
    duration: 4.5,
    narration: "项目开源免费，正式发布后欢迎下载试用。",
  },
];
