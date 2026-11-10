# SimpleShot

一个简约的 macOS 截图工具：区域 / 窗口 / 全屏截图 + 截图后标注 + 提取文字 + 翻译 + 划词翻译 + 输入翻译 + 录屏，完成后直接复制到剪贴板（不存文件）。

- 原生 Swift + AppKit，常驻菜单栏，不占 Dock
- 默认快捷键 `⌥A`，可在设置中修改，并自动检测冲突
- 按原始像素（Retina）分辨率输出

## 系统要求

- macOS 14 (Sonoma) 或更新
- Xcode 命令行工具（不需要完整 Xcode）：`xcode-select --install`

## 直接下载（推荐）

每次推送到 `main` 都会由 GitHub Actions 自动编译（同时支持 Apple Silicon 和 Intel）：

1. 到 [Releases 最新版本](https://github.com/david-yang-pixel/SimpleShot/releases/latest) 下载 `SimpleShot-<版本>.dmg`，双击打开，把 SimpleShot 拖到「应用程序」文件夹；
2. 首次打开：由于没有 Apple 开发者签名，系统会提示“无法验证开发者”。点「完成」，然后到
   **系统设置 › 隐私与安全性**，在页面下方点「仍要打开」。
   （或在终端执行 `xattr -dr com.apple.quarantine /Applications/SimpleShot.app` 后再打开）

## 从源码构建

```bash
git clone https://github.com/david-yang-pixel/SimpleShot.git
cd SimpleShot
./scripts/build.sh --install     # 构建并安装到 /Applications，随后自动启动
```

只构建不安装：`./scripts/build.sh`，产物在 `build/SimpleShot.app`。

### 首次运行：屏幕录制权限

第一次截图时系统会要求授权：**系统设置 › 隐私与安全性 › 屏幕与系统录音**，打开 SimpleShot，
然后**退出并重新打开** SimpleShot。

> 默认使用临时签名（ad-hoc），重新构建后签名会变化，系统可能要求重新授权。
> 如想避免：在「钥匙串访问 › 证书助理 › 创建证书」中创建一个类型为「代码签名」的自签名证书
> （例如命名为 `SimpleShot Dev`），之后用 `SIGN_IDENTITY="SimpleShot Dev" ./scripts/build.sh --install` 构建。

## 使用

| 操作 | 说明 |
| --- | --- |
| `⌥A` | 开始截图（可在设置中修改） |
| `⌥Z` | 打开 / 关闭输入翻译窗口（可在设置中修改） |
| 悬停 + 单击 | 截取鼠标下的窗口（菜单栏、Dock 也可） |
| 在桌面上单击 | 截取整个屏幕 |
| 拖动 | 框选区域；选好后可拖动、拖边角调整，方向键微调（⇧ 每次 10 点） |
| 回车 / 双击选区 / ✓ | 复制到剪贴板 |
| `⌘Z` | 撤销上一个标注 |
| `Esc` | 取消截图 |
| 右键 | 重新选择（已在选择阶段则取消） |

标注工具：矩形、椭圆、箭头、画笔、文字、马赛克；3 档粗细，6 种颜色。

**提取文字**：选好区域后点工具条上的「提取文字」，用系统自带的 Vision 框架离线识别（简体中文 + 英文），
结果显示在弹窗中，可以修改、选中部分 `⌘C` 复制，或点「复制全部」（`⌘↩`）。

**翻译**：点工具条上的「翻译」，先离线识别文字，再用系统自带的翻译引擎翻译（需要 macOS 15+）：
外文自动翻成简体中文，中文翻成英文。弹窗上半部分是原文（可修改后「重新翻译」），下半部分是译文，
「复制译文」快捷键 `⌘↩`。某种语言首次使用时系统会提示下载语言包，之后可离线使用。

**用自己的 AI 模型翻译**：设置 › 翻译引擎 选「AI 大模型」，可用「快速填写」选择 DeepSeek、通义千问、Kimi、智谱 GLM、
OpenAI、Ollama（本机）或 Claude，再填入 API Key，点「测试」确认可用。支持任意 **OpenAI 兼容接口**（自定义地址与模型名）
和 **Anthropic Claude** 接口。API Key 保存在 macOS 钥匙串中；翻译时只发送识别出的文字，不上传截图。

**划词翻译**：在任意应用里用鼠标划选（或双击选词）一段**外文**，旁边会出现一个翻译小图标，点一下即在浮窗中显示译文
（选中中文不会出现图标）。使用当前设置的翻译引擎；按 Esc 或点击浮窗外部关闭。需要授予「辅助功能」权限，
可在设置 › 划词翻译 中关闭。读取选中文字优先用辅助功能接口，个别不支持的应用会模拟 `⌘C` 读取并恢复原剪贴板。

**输入翻译**：按 `⌥Z`（可在设置中修改）在屏幕右上角弹出输入翻译窗口，输入或粘贴文字后按回车翻译（`⇧回车` 换行），
中文自动翻成英文、外文翻成中文；`⌘↩` 复制译文；点窗口外任意位置、按 Esc 或再按一次快捷键即可关闭。窗口会保留上次的内容。

**录屏**（需要 macOS 15+）：按 `⌥A` 选好区域或窗口后，点工具条上的「录屏」，选择是否录「系统声音」「麦克风」，
点「开始录制」（或回车）。录制区域外有红色虚线框，选区右下角有悬浮控制条显示计时；点控制条上的「结束录制」、菜单栏的停止按钮，或再按 `⌥A` 结束。
录好的 MP4 **直接放进剪贴板**（不弹任何提示），可直接粘贴到微信等应用发送。
录屏文件只写在系统临时目录，剪贴板内容被替换后自动删除，不会保存到你的文件夹。
录制前可选择录制对象：
- **固定区域**：录屏幕上这块区域，切换到其他窗口也会继续录，区域里显示什么就录什么；
- **该窗口**：只录选中的窗口，切换到其他窗口、窗口被遮挡或移动都能录到（最小化时除外）。
单击选中窗口时默认「该窗口」，拖动框选时默认「固定区域」。

## 快捷键突然失灵？

如果某个应用开启了 macOS 的「安全输入」（通常是密码输入框处于激活状态，例如浏览器登录页），
系统会屏蔽**所有应用**的全局快捷键（SimpleShot、微信截图等都会失灵）。
此时 SimpleShot 的菜单栏图标会变成 ⚠️，菜单里会显示是哪个应用占用了安全输入，点击可查看解决办法。

## 快捷键冲突检测

在设置里录入新快捷键时会依次检查：

1. 必须包含 `⌘` / `⌥` / `⌃` 中的至少一个；
2. 不能是 `⌘ + 单键` 等应用常用快捷键（复制、保存……）；
3. 不能与「系统设置 › 键盘 › 键盘快捷键」中已启用的系统快捷键重复；
4. 注册时若该组合已被其他应用（如微信、QQ、Raycast 等）注册为全局快捷键，会注册失败并提示。

> 说明：某个应用**自己菜单里**的快捷键（只在该应用处于前台时生效）无法被检测到，
> 但全局快捷键优先级更高，按下时仍会触发截图。

## 图标

`Resources/AppIcon.svg` 是图标源文件，`AppIcon.png`（1024×1024）由它导出；构建时用 `actool` 编译成资源目录 `Assets.car`（macOS 26+ 需要），并生成兼容旧系统的 `.icns`。

## 项目结构

```
Sources/SimpleShot/
  SimpleShotApp.swift          入口
  AppDelegate.swift            菜单栏图标与菜单
  HotKeyManager.swift          全局快捷键注册 + 冲突检测
  Shortcut.swift               快捷键模型与显示
  Settings.swift               偏好设置（快捷键 / 开机启动 / 自动更新）
  SettingsWindowController.swift  设置窗口 + 快捷键录制按钮
  ScreenCapturer.swift         ScreenCaptureKit 截屏 + 窗口位置
  CaptureController.swift      截图流程、全屏遮罩窗口
  SelectionView.swift          选区、放大镜、标注交互、导出
  ToolbarView.swift            标注工具条
  Annotation.swift             标注模型与绘制
  ImageExporter.swift          复制到剪贴板
  SecureInputMonitor.swift     检测“安全输入”导致的快捷键失灵
  TextRecognizer.swift         文字识别 + 识别结果窗口
  Translator.swift             翻译（系统 Translation 框架）+ 翻译结果窗口
  AITranslator.swift           AI 大模型翻译（OpenAI 兼容 / Claude）+ 钥匙串存储
  SelectionTranslator.swift    划词翻译：读取选中文字、翻译图标与浮窗
  InputTranslator.swift        输入翻译窗口（快捷键呼出）
  ScreenRecorder.swift         录屏（ScreenCaptureKit）、悬浮控制条、临时文件清理
  Helpers.swift                权限提示、Toast
```

## 版本号

- 版本号写在根目录的 `VERSION` 文件（如 `1.0.0`），构建号自动取 git 提交次数；
- 在菜单栏图标 › 关于 SimpleShot，或设置窗口底部可以看到当前版本；
- 发布新版本：修改 `VERSION`，在 `CHANGELOG.md` 写上该版本的更新内容，推送到 `main`，
  GitHub Actions 会自动创建对应的 `v<版本>` Release（更新内容会显示在应用内的更新提示里）。

## 应用内更新

- 菜单栏图标 › 检查更新…，或设置窗口中的「立即检查」；默认每天自动检查一次（可在设置中关闭）；
- 发现新版本后点「立即更新」：自动下载、校验签名、替换「应用程序」中的 SimpleShot 并重新打开；
- 安装包必须与当前版本由同一证书签名才会安装，防止被替换。

### 签名证书

CI 使用一个固定的自签名证书签名（存放在仓库的 Actions Secrets：`MACOS_CERT_P12`、`MACOS_CERT_PASSWORD`），
因此更新后签名不变，系统不会要求重新授予“屏幕录制”权限。未配置这两个 Secret 时，CI 会使用临时签名且不发布 Release。
