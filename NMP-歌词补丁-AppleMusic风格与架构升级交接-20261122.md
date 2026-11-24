# Neural Mix Pro 中文歌词补丁 · Apple Music 风格与底层升级交接文档（2026-11-22）

## 1. 背景与路径

- **项目路径**：`/Users/joyren/WorkBuddy/Random APP/NMP-歌词补丁/`
- **核心源码**：`src/main.m`
- **构建产物**：`build/libNMPLyrics.dylib`（Universal `arm64 + x86_64`）、`build/staging/Neural Mix Pro.app`

---

## 2. 底层隐患修复（5 项）

| 位置 | 原问题 | 修复方式 |
| :--- | :--- | :--- |
| `libNMPLyricsEntry` | `r1/r2/r3` 为栈上局部变量，指针挂给全局 `g_rebindings` 形成悬空指针 UB | 改为 `static struct rebinding_entry` 持久存储 |
| `resolveLyricsForTitle:` / `parseFileAtPath:` / `parseLyrics:` | `_matching` 锁吞掉快速切歌；后台线程直接写 `_lrcOffset` 与主线程竞争，且 `_pendingOffset` 恒为 0 | 新增递增 `_resolveGeneration` 令牌丢弃过期结果；解析函数改为局部变量返回 `lines`、`lrcOffset`、`artwork` |
| `NMPStageView` 物理弹簧与布局性能 | 写死 `dt = 1/60`（120Hz 屏倍速）；每帧为所有可见行重建 `NSLayoutManager`；左对齐缩放锚点偏移 `16pt` 致左缘参差 | 改用 `CACurrentMediaTime()` 真实 `dt`（钳位 `[1/120, 1/20]`）；活跃行缓存 `NSLayoutManager`，非活跃行改用 `drawWithRect:` 快路径；左对齐锚点对齐 `x0` |
| `buildWindow` / `layoutStage` 悬浮胶囊 | 写死 `560px` 宽在窄窗裁切；`NSTrackingActiveInActiveApp` 副屏不激活无法呼出且静止不自动隐藏 | 升级为 `NSVisualEffectView` 毛玻璃胶囊，`width < 650` 自动切双排紧凑排版；改 `NSTrackingActiveAlways` + 静止 `2.2s` 自动淡出（光标停在胶囊上时保活） |
| `NMPStageView` 交互 | 仅支持点击跳句，不能滚轮浏览，无悬停反馈 | 新增 `scrollWheel:` 自由浏览（停滚 `2.5s` 自动弹簧回位）+ 悬停行半透明圆角底框与 `pointingHandCursor` |

---

## 3. Apple Music 风格视觉升级（5 项）

1. **封面主色提取 + 动态流光背景**：
   - 在 `extractLyricsTextFromFile:outArtwork:` 中一次 ID3 读取同时解析 `APIC`（v2.3/v2.4）与 `PIC`（v2.2）内嵌封面，非 ID3 格式（M4A/FLAC/AAC）通过 `AVURLAsset` `AVMetadataCommonKeyArtwork` 兜底提取。
   - `NMPExtractPaletteFromImage()` 将封面下采样至 `16×16` 四象限采样主色，提饱和并压亮度（`v ∈ [0.20, 0.50]`），确保白色歌词高对比度；切歌时 `1.15s` 平滑变色。
   - 悬浮胶囊新增「流光」开关（持久化键 `cn.renqiaoyi.lyrics.ambientBg`，默认开启），教室强光投影时可一键切回纯黑高对比度底色。
2. **无边界沉浸标题栏 + 顶部微曲目信息**：
   - 启用 `NSWindowStyleMaskFullSizeContentView`、`titlebarAppearsTransparent = YES`、`titleVisibility = NSWindowTitleHidden`，流光直通红绿灯下方；顶部左上角绘制 `32×32` 圆角小封面 + 歌名/艺人（顶部 `46pt` 保留窗口拖动）。
3. **柔化羽化扫光 + 轻光晕 + 焦点微浮起**：
   - 替换硬直 `NSRectClip`：在 `drawKaraoke:` 中对正在扫光的单行开启透明层 + `kCGBlendModeDestinationIn` 水平渐变遮罩（前沿 `~22pt` 柔滑羽化），仅对当前亮行叠加轻柔白光晕（`blur = fs * 0.14`）及 `-2.5pt` 微浮起。
4. **渐进景深 + 微波浪跟随**：
   - 按行距做 4 档缩放与透明度递减（`0/1/2/3+`），切行时下方相邻行带微小滞后波浪位移（`sin(π·easeT) * dist * 4.2pt`）。
5. **毛玻璃 HUD 胶囊 + 直接输入 px 字号**：
   - 采用 `NSVisualEffectMaterialHUDWindow` + `NSVisualEffectBlendingModeWithinWindow`，字号控件改为直接输入 `px` 数值框（`16–260 px`，回车或失焦生效，键 `cn.renqiaoyi.lyrics.fontSizePx`，编辑中暂停 HUD 自动隐藏），支持字号 px、字重、排版、流光、置顶五项调节。
6. **高光零错位 + 统一视觉行距 + 非线性逐行弹簧与动态模糊（二轮精修）**：
   - **高光零错位**：`drawActiveLine:` 让未唱暗底层与羽化高光层共用同一个缓存的 `NSLayoutManager` 和完全一致的原点（`tc.lineFragmentPadding = 0`），彻底消除原 `drawWithRect:` 与 `NSLayoutManager` 混用导致的上下/左右重影错位。
   - **等距排版与间奏三点对称**：`textHeightAtIndex:` 改用 `NSLayoutManager usedRectForTextContainer:` 精确量高，按缩放后真实视觉高度 `visH = textH * lineScale` 配合统一净间距 `visualGap = max(14, fs * 0.56)` 排布；间奏三点严格置于「当前句底边」与「下一句顶边」中点，单行、双行与间奏间距完全一致。
   - **Apple Music 非线性拖尾滑动 + 景深/动态高斯模糊**：每行拥有独立弹簧状态（`_linePosY / _lineVelY / _lineDelay`），切句按行距阶梯延迟（正常 46ms、跨行跳转 24ms）产生拖尾波浪滚动，点击某行跳转不再 `forceSettle` 瞬移而是平滑滑过去；非当前行按行距 + 滑动速度（`vel > 220` 加一档动态模糊）走 CoreImage `CIGaussianBlur` GPU 渲染并按行纹理缓存，悬停或滚轮浏览时自动清焦。

---

## 4. 验证与安装说明

- Universal 二进制编译通过：`build/libNMPLyrics.dylib`（`arm64` + `x86_64`，零错误零警告）。
- 完整注入签名包已构建至 `build/staging/Neural Mix Pro.app`。
- 因沙盒策略限制直接写入 `/Applications/Neural Mix Pro.app`，在终端运行 `cd "/Users/joyren/WorkBuddy/Random APP/NMP-歌词补丁" && zsh build.sh` 即可一键替换正式版。
