// AMD Mobile Power review-film engine. The recorder owns time; rendering is
// deterministic and every embedded GUI frame comes from a checked manifest.
const SCENES = window.__SCENES__ || [];
const FONT = "'Microsoft YaHei UI','Segoe UI',sans-serif";
const C = {
  canvas: "#0b1216", surface: "#111b20", text: "#f1f7f4",
  muted: "#a6b8b0", faint: "#71847c", accent: "#45d6a8", line: "#2b3c42",
};
let cursor = 0;
const timeline = SCENES.map(scene => {
  const start = cursor;
  cursor += scene.duration;
  return { ...scene, start, end: cursor };
});
const TOTAL = cursor;
const clamp = value => Math.max(0, Math.min(1, value));
const ease = value => 1 - Math.pow(1 - clamp(value), 3);

function node(tag, style = {}, children = []) {
  const item = document.createElement(tag);
  Object.assign(item.style, style);
  item.append(...children);
  return item;
}

function text(value, style = {}) {
  const item = node("div", { fontFamily: FONT, ...style });
  item.textContent = value;
  return item;
}

function sceneAt(seconds) {
  return timeline.find(scene => seconds >= scene.start && seconds < scene.end) ||
    timeline[timeline.length - 1];
}

function background() {
  return node("div", {
    position: "absolute", inset: "0", overflow: "hidden",
    background: `linear-gradient(145deg,${C.canvas} 0%,#0e191d 58%,#0b1815 100%)`,
  });
}

function heading(eyebrow, title, body, width = 650) {
  const wrap = node("div", {
    width: `${width}px`, flexShrink: "0", display: "flex",
    flexDirection: "column", justifyContent: "center",
  });
  wrap.append(
    text(eyebrow, {
      color: C.accent, fontSize: "24px", fontWeight: "700",
      letterSpacing: "3px", marginBottom: "24px",
    }),
    text(title, {
      color: C.text, fontSize: "76px", fontWeight: "800",
      lineHeight: "1.24", whiteSpace: "pre-line", marginBottom: "28px",
    }),
    text(body, {
      color: C.muted, fontSize: "28px", lineHeight: "1.6",
      whiteSpace: "pre-line",
    }),
  );
  return wrap;
}

function badge(label) {
  return text(label, {
    color: C.accent, fontSize: "17px", fontWeight: "700",
    padding: "7px 12px", border: `1px solid ${C.accent}`,
    borderRadius: "6px", background: "rgba(69,214,168,0.08)",
    whiteSpace: "nowrap",
  });
}

function imageFrame(id, source, width, height, label, detail) {
  const wrap = node("div", {
    width: `${width}px`, flexShrink: "0", display: "flex",
    flexDirection: "column", gap: "14px",
  });
  const head = node("div", {
    height: "44px", display: "flex", alignItems: "center",
    justifyContent: "space-between", gap: "16px",
  }, [
    text(label, { color: C.text, fontSize: "21px", fontWeight: "700" }),
    badge(detail),
  ]);
  const frame = node("div", {
    width: `${width}px`, height: `${height}px`, position: "relative",
    overflow: "hidden", borderRadius: "8px", background: C.surface,
    border: `1px solid ${C.line}`, boxShadow: "0 22px 54px rgba(0,0,0,0.38)",
  });
  const image = node("img", {
    width: "100%", height: "100%", objectFit: "contain", display: "block",
  });
  image.id = id;
  image.src = source || "";
  image.dataset.role = "gui-frame";
  frame.append(image);
  wrap.append(head, frame);
  return { wrap, frame, image };
}

function displayedImageRect(frame, image) {
  const box = frame.getBoundingClientRect();
  const naturalWidth = image.naturalWidth || box.width;
  const naturalHeight = image.naturalHeight || box.height;
  const scale = Math.min(box.width / naturalWidth, box.height / naturalHeight);
  const width = naturalWidth * scale;
  const height = naturalHeight * scale;
  return { x: (box.width - width) / 2, y: (box.height - height) / 2, width, height };
}

function drawPointer(frame, image, events, localTime, lead = 0.35) {
  if (!events || !events.length) return;
  const rect = displayedImageRect(frame, image);
  const clicks = events.map(event => ({
    t: event.VisualAt + lead, x: event.ClickX, y: event.ClickY,
  }));
  let index = -1;
  for (let i = 0; i < clicks.length; i++) {
    if (localTime >= clicks[i].t - 0.7) index = i;
  }
  let point = { x: 0.82, y: 0.82 };
  if (index >= 0) {
    const to = clicks[index];
    const from = index === 0 ? point : clicks[index - 1];
    const progress = ease((localTime - (to.t - 0.7)) / 0.7);
    point = {
      x: from.x + (to.x - from.x) * progress,
      y: from.y + (to.y - from.y) * progress,
    };
  }
  const pointer = node("div", {
    position: "absolute", left: "0", top: "0", width: "30px", height: "34px",
    zIndex: "4", pointerEvents: "none",
    filter: "drop-shadow(0 2px 3px rgba(0,0,0,0.55))",
    transform: `translate(${rect.x + point.x * rect.width}px,${rect.y + point.y * rect.height}px)`,
  });
  pointer.innerHTML = '<svg width="30" height="34" viewBox="0 0 20 23"><path d="M2 2 L2 18 L6.5 14.2 L9.2 20.6 L12.4 19.1 L9.8 13 L16 12.4 Z" fill="#fff" stroke="#0b1216" stroke-width="1.4" stroke-linejoin="round"/></svg>';
  frame.append(pointer);
  for (const click of clicks) {
    const age = localTime - click.t;
    if (age < 0 || age > 0.38) continue;
    const phase = age / 0.38;
    frame.append(node("div", {
      position: "absolute", left: "0", top: "0", width: "48px", height: "48px",
      borderRadius: "50%", border: `2px solid ${C.accent}`,
      opacity: String((1 - phase) * 0.8), zIndex: "3", pointerEvents: "none",
      transform: `translate(${rect.x + click.x * rect.width - 24}px,${rect.y + click.y * rect.height - 24}px) scale(${0.45 + ease(phase)})`,
    }));
  }
}

function caption(scene, localTime, root) {
  if (!scene.narration) return;
  const opacity = Math.min(
    clamp((localTime - 0.18) / 0.22),
    clamp((scene.duration - localTime - 0.18) / 0.22),
  );
  if (opacity <= 0) return;
  root.append(node("div", {
    position: "absolute", left: "0", right: "0", bottom: "0", zIndex: "8",
    minHeight: "112px", padding: "28px 110px 30px",
    display: "flex", justifyContent: "center", alignItems: "center",
    background: "linear-gradient(180deg,rgba(8,14,17,0),rgba(8,14,17,.92) 38%,#080e11)",
    opacity: String(opacity),
  }, [text(scene.narration, {
    color: C.text, fontSize: "30px", fontWeight: "500", lineHeight: "1.5",
    textAlign: "center", maxWidth: "1660px",
  })]));
}

const renderers = {};

renderers.hook = (scene, t, root) => {
  const wrap = background();
  Object.assign(wrap.style, {
    display: "flex", alignItems: "center", padding: "0 120px 90px", gap: "80px",
  });
  const left = heading("AMD MOBILE POWER", "插电要性能\n电池要续航",
    "一个原生 Windows 功耗面板\n看清实时功耗，也看清实际上限", 1080);
  left.children[1].style.fontSize = "108px";
  const icon = node("img", { width: "260px", height: "260px" });
  icon.src = "../../assets/amd-mobile-power-256.png";
  const iconBox = node("div", {
    flex: "1", display: "flex", alignItems: "center", justifyContent: "center",
  }, [node("div", {
    width: "390px", height: "390px", borderRadius: "50%",
    border: `2px solid ${C.line}`, display: "flex",
    alignItems: "center", justifyContent: "center", background: C.surface,
  }, [icon])]);
  wrap.append(left, iconBox);
  root.append(wrap);
};

function clipScene(scene, t, root, options) {
  const wrap = background();
  Object.assign(wrap.style, {
    display: "flex", alignItems: "center", padding: "0 90px 112px",
    gap: options.gap || 64,
  });
  const left = heading(options.eyebrow, options.title, options.body,
    options.leftWidth || 620);
  const shot = imageFrame(options.id, options.poster, options.width, options.height,
    options.label || "1.0.42 界面演示", "模拟数据 · 未写硬件");
  wrap.append(left, shot.wrap);
  root.append(wrap);
  const config = window.__CLIPS__ && window.__CLIPS__[scene.clip];
  if (config) {
    drawPointer(shot.frame, shot.image, config.Events,
      t + (scene.clipOffset || 0), config.LeadSeconds || 0.35);
  }
}

renderers.safety = (scene, t, root) => clipScene(scene, t, root, {
  id: "consent-frame", poster: window.__POSTERS__?.consent,
  eyebrow: "写入之前", title: "默认只读\n确认后才改",
  body: "勾选须知后，确认按钮才会亮起。\n确认后由程序接管后台服务重启；\n不想改时，点锁形按钮即可恢复只读。",
  width: 790, height: 760, leftWidth: 760, gap: 70,
  label: "真实确认流程 · 隔离界面",
});

renderers["ui-demo"] = (scene, t, root) => clipScene(scene, t, root, {
  id: "simple-frame", poster: window.__POSTERS__?.simple,
  eyebrow: "快捷预设", title: "点一下就应用\n改完自动核对",
  body: "25 W：日常使用\n45 W：插电性能取向\n10 W：更低上限，偏重续航\n瓦数只是上限，不代表实时功耗恒定。",
  width: 1050, height: 630, leftWidth: 570,
});

renderers.presets = (scene, t, root) => clipScene(scene, t, root, {
  id: "presets-frame", poster: window.__POSTERS__?.presets,
  eyebrow: "预设可编辑", title: "不是固定三档\n按你的习惯改",
  body: "示例：10 W → 12 W\n保存后，快捷按钮同步更新。\n随后点击 12 W，目标与回读一起变化。",
  width: 930, height: 810, leftWidth: 680,
});

renderers["auto-policy"] = (scene, t, root) => clipScene(scene, t, root, {
  id: "policy-frame", poster: window.__POSTERS__?.policy,
  eyebrow: "自动电源策略", title: "电池和外接\n分别设上限",
  body: "示例：电池 25 W / 外接 45 W。\n勾选“仅电池”后，外接线路不写入。\n充电宝通常也会被识别为外接电源。",
  width: 930, height: 810, leftWidth: 680,
});

renderers.firmware = (scene, t, root) => {
  const wrap = background();
  Object.assign(wrap.style, {
    display: "flex", alignItems: "center", padding: "0 90px 112px", gap: "70px",
  });
  const left = heading("固件限制", "没完全生效\n界面会直说",
    "目标 12 W\nSTAPM 实际上限 10 W\nFast / Slow 实际上限 12 W\n最终看回读，不把请求值当结果。", 700);
  const shot = imageFrame("firmware-frame", "assets/firmware-clamp-1.0.42-client.png",
    1000, 600, "固件限制示例", "模拟数据 · STAPM 受限");
  wrap.append(left, shot.wrap);
  root.append(wrap);
};

renderers.compat = (scene, t, root) => clipScene(scene, t, root, {
  id: "diagnostics-frame", poster: window.__POSTERS__?.diagnostics,
  eyebrow: "兼容性与诊断", title: "先识别机型\n再决定是否试写",
  body: "目前只有一台 8845HS 完整实测。\n其他 AMD 型号仍是待验证配置。\n诊断可导出，且不上传、不含本地路径。",
  width: 1050, height: 630, leftWidth: 570,
});

renderers.closing = (scene, t, root) => {
  const wrap = background();
  Object.assign(wrap.style, {
    display: "flex", flexDirection: "column", alignItems: "center",
    justifyContent: "center", padding: "0 140px 100px", textAlign: "center",
  });
  wrap.append(
    text("开源 · 免费 · 便携运行", {
      color: C.accent, fontSize: "25px", fontWeight: "700", marginBottom: "28px",
    }),
    text("AMD Mobile Power", {
      color: C.text, fontSize: "96px", fontWeight: "800", marginBottom: "28px",
    }),
    text("github.com/syttys123/amd-mobile-power", {
      color: C.accent, fontSize: "32px", fontWeight: "600", marginBottom: "28px",
    }),
    text("审查版 · 无声字幕 · 尚未公开发布", {
      color: C.faint, fontSize: "20px",
    }),
  );
  root.append(wrap);
};

function renderAt(seconds) {
  const root = document.getElementById("root");
  const scene = sceneAt(seconds);
  const local = seconds - scene.start;
  const index = timeline.indexOf(scene);
  root.replaceChildren();
  const base = node("div", { position: "absolute", inset: "0" });
  root.append(base);
  renderers[scene.id](scene, local, base);

  // Crossfade over an opaque previous scene. Both layers are never
  // transparent together, so boundaries cannot dip to black.
  const crossfade = 0.24;
  if (index > 0 && local < crossfade) {
    const previous = timeline[index - 1];
    const under = node("div", { position: "absolute", inset: "0", zIndex: "1" });
    renderers[previous.id](previous, previous.duration, under);
    base.style.zIndex = "2";
    base.style.opacity = String(clamp(local / crossfade));
    root.insertBefore(under, base);
  }
  caption(scene, local, root);
}

window.__totalDuration = () => TOTAL;
window.__seek = renderAt;
window.__timeline = timeline;
renderAt(0);
