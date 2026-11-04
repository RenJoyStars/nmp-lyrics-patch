# Neural Mix Pro · 中文歌词补丁

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-11%2B%20%C2%B7%20universal-green)
![Type](https://img.shields.io/badge/type-dylib%20injection-orange)
![No binary](https://img.shields.io/badge/binaries-none%20(source%20only)-lightgrey)

> Algoriddim Neural Mix Pro 的 macOS 增强补丁（注入式 dylib）
> 做三件事：**界面汉化** ＋ **独立歌词窗（课堂投影用）** ＋ **标题栏一键呼出按钮**

> ⚠️ **本仓库只放源码**，不包含 Neural Mix Pro 本体，也不含打包好的安装包。
> 使用前提：你自己的机器上已安装 Neural Mix Pro；补丁只修改本机上这个 App 的界面与行为。
> `backup/`（原版备份，188MB）与 `dist/`（安装包，136MB）都在 `.gitignore` 里，不会出现在仓库中。
>
> 本项目与 Algoriddim 无关，未获其授权或认可；Neural Mix Pro 的著作权归 Algoriddim 所有。

## 快速开始

```sh
# 1) 先备份一份原版，构建脚本依赖它做还原
cp -R "/Applications/Neural Mix Pro.app" backup/"Neural Mix Pro-原版.app"

# 2) 编译 + 注入 + 重签（会改动 /Applications 里的 App）
zsh build.sh

# 3) 想验证又不想动 /Applications，用 staging 副本
zsh build-staging.sh

# 4) 还原
zsh restore.sh
```

## 用法

- 平时怎么开就怎么开：双击 `/Applications/Neural Mix Pro.app`
- 点 NMP 标题栏右侧**最左边那个气泡图标**（和 NMP 原有三个按钮同一排、同尺寸），
  或菜单栏 **歌词 → 显示 / 隐藏歌词窗口**（⌘L）
- 歌词窗是**独立窗口**：可拖动、可拉伸、可最小化，能直接拖到副屏/投影上
- **没有设置条**：只有歌词本身 + 右下角一个字号倍率滑条（0.6×–2.0×，会记住）
- **字号跟着窗口自动缩放**
  （`min(高×0.093, 宽×0.060)`，16–170pt），窗口拉大字号就变大同理
- 播放歌曲后自动同步：当前句大字、已唱的词亮白、卡拉 OK 式光带逐字扫过，
  上下句渐小渐隐，整列平滑滚动

## 歌词来源（全自动，不支持手动拖入）

1. 进程内文件钩子捕获 NMP 刚打开的音频文件
2. 找不到就用 **Spotlight（mdfind）** 按曲名索引查找，毫秒级（不再枚举 iCloud 目录）
3. 兜底：只扫 `~/Downloads` 与本地 Music 目录（限时 2s、限 4000 条）

## 支持的歌词格式

| 来源 | 标签/格式 | 效果 |
|---|---|---|
| 网易云音乐 | ID3 USLT，词级 `<02:50.610>真` | 逐字扫光 |
| QQ 音乐 / 酷狗 | ID3 USLT 标准 LRC `[00:32.444]词` | 整句扫光 |
| 酷我音乐 | USLT LRC（`[kuwo:xxx]` 头自动跳过） | 整句扫光 |
| 咪咕等 | USLT / SYLT / TXXX(LYRICS/歌词) | 同上 |
| 少数平台 | `[hh:mm:ss]` 三段式时间戳 | 整句扫光 |
| 外部 `.lrc` | 以上全部 + `[offset:]` | 同上 |

解析器处理了这些坑：
- **ID3v2.4 的 syncsafe 帧长度**（按普通整数读会整段错位 → 找不到歌词）
- **unsynchronisation 标志**（FF 00 还原）
- ID3v2.2 的 3 字符帧（`ULT`）、v2.3/2.4 的 `USLT` / `SYLT` / `TXXX`
- 编码：UTF-16(BOM/BE/LE) → UTF-8 → GB18030/GBK，剥 BOM

**排版与性能**：
- 逐词时间戳里的空格属于**前一个词**（`"Beyond "` + `"the"`），解析时只裁整行首尾，
  不再逐词 trim —— 否则英文全会粘成一串
- 扫光（卡拉 OK 式）：`NSLayoutManager` 取「**小数**字符位置」→ 每个行段各自裁剪，
  行内裁剪点连续移动，所以一个字能被填到一半；长句折成多行时逐行推进。
  旧做法是整块矩形裁剪 + 整字取整：两行会同时亮，而且单字词在它被唱的整段时间里
  一个字都不亮（看着像"亮的总是前一个字、最后一个字从不亮"）
- 词内进度最多按 1.2 秒拉满 —— 一句的最后一个字常隔着间奏，不设上限就会拖很久才亮
- 每帧只绘制屏幕内的几行，行高按 (行号, 距离档位) 缓存；无阴影、渐变对象缓存；
  60fps 渲染循环只在「位置/词/进度真的变了」时重绘。实测 **2.38 ms/帧**（51 行歌词，60fps 预算 16.7ms）

**踩过的坑（未定义行为）**：`ParseClock` 曾漏掉结尾的 `return total;`，编译器只给个警告，
运行时返回值是寄存器里的残留值 —— 所有行时间因此变成 0，二分查找永远命中最后一句，
表现就是「歌词卡在最后一句」。改这个函数时务必确认 `return` 在。

实测样本：iCloud「2024 艺术节校园歌手大赛歌曲库」**222 首，219 首成功**。
剩下 3 首文件里**本来就没有歌词帧**（其中 1 首连 ID3 标签都没有），不是解析问题。

**不支持**：酷狗 KRC / QQ QRC 加密侧车文件。

## 汉化范围

- `Resources/zh-Hans.lproj/Localizable.strings`：164 条 UI 文案（系统自动加载）
- **菜单栏主标题保持英文（已确认做不到，不再尝试）**：主菜单来自 `NMMainMenu.nib`，
  里面是裸英文（File/Edit/View…），不走 `.strings`；编译后的 nib 是 NIBArchive，
  `ibtool` 拒绝打开，做不出中文 nib。
  运行时改写也**实证无效**：改 `title`、改 `attributedTitle`、`setMainMenu:nil` 重挂、
  甚至深拷贝整棵菜单树换成新对象（指针都变了），菜单栏仍然绘制启动时的快照。
  唯一剩下的路是直接编辑二进制 nib 的字符串表，风险高、收益低 —— 放弃。
  **只放弃顶部那 7 个标题**，下拉里的条目是可以改的（见下条）。
- **下拉菜单**：nib 里一部分条目走本地化 key（已在 `.strings` 里翻好），
  另一部分是硬编码英文（`Open` / `Export Track` / `Undo` …，没有 key 可翻）。
  后者在运行时按「下拉菜单条目」改写标题（`localizeDropdowns`），
  **不碰顶部主标题**。实测 AX 读到的是中文，分轨名也翻了（鼓 / 和声 / 人声 / 贝斯）。
- **没有「歌词」菜单**（按要求删除），呼出歌词窗用标题栏气泡按钮或 **⌘L**
- 术语按音乐语境：`Cue/Start → 打点`、`Set → 设定打点`、`Pitch → 音高`、`Tempo → 速度`

## 工程结构

```
NMP-歌词补丁/
├── src/main.m              动态库源码（注入 NMP 进程）
├── l10n/Localizable.strings 中文文案（UTF-8，构建时转 UTF-16）
├── Tools/inject.py         Mach-O 注入器（两个 slice 各加一条 LC_LOAD_DYLIB）
├── Tools/package.sh        打成 pkg（内含整个 App，勿公开分发）
├── build.sh                正式安装：编译 → 放进 /Applications → 注入 → 重签
├── build-staging.sh        staging 副本（不动 /Applications，用于验证）
├── restore.sh              还原：用 backup/ 里的原版覆盖回来
├── backup/                 原版 App（188MB）— 本地目录，已 gitignore
└── dist/                   打好的 pkg（136MB）— 本地目录，已 gitignore
```

## 打包成 pkg（仅限自己的设备）

```sh
zsh Tools/package.sh
```

产出 `dist/Neural Mix Pro 歌词版 1.0.pkg`（约 136MB），里面是**整个 App**，装到另一台机器时不用另装原版。

> ⚠️ 这个 pkg 里含 Neural Mix Pro 的完整程序本体，**不要公开分发、不要上传到网盘或仓库**。
> 本仓库只放补丁源码，是有意为之。

- payload：`ditto --noextattr --noqtn` 拷贝已打补丁的 App → 不带本机隔离属性
- preinstall：先 `pkill` 退出正在运行的 NMP，避免替换时文件被占用
- postinstall：`xattr -cr` 清隔离 + `lsregister -f` 重新登记，装完直接双击就能开
- 安装界面自带 `readme.txt`（安装说明 / Gatekeeper 提示 / 卸载方法）

未签名（ad-hoc），对方首次打开 pkg 需要右键 → 打开，说明里写了。

## 还原

```sh
zsh restore.sh
```

## 许可与免责

本仓库的**补丁源码**（注入库 `src/main.m`、注入器 `Tools/inject.py`、构建脚本、本地化文案）
以 [MIT 协议](LICENSE) 开源，可自由使用与修改。

- **不包含 Neural Mix Pro**：仓库里没有任何 Algoriddim 的程序本体、资源或密钥。
- **需要自备授权**：请在你已合法获得 Neural Mix Pro 的机器上使用本补丁。
- **与 Algoriddim 无关**：本项目非官方，未获 Algoriddim 授权或认可；「Neural Mix Pro」
  及其商标、著作权归 Algoriddim 所有。
- **自担风险**：补丁会修改 `/Applications` 里的 App 并重新签名，可能影响该 App 的
  更新、公证与稳定性；`restore.sh` 可还原，但请自行做好备份。

如果你只想用成品，`Tools/package.sh` 打出来的 pkg 里含**整个 App**，
那是给你自己的设备用的，请不要公开分发。
