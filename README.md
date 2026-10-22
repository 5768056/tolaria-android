# Tolaria Android Client (unofficial)

> **非官方项目。** 与 [refactoringhq/tolaria](https://github.com/refactoringhq/tolaria)
> 的作者没有隶属关系，也未获其背书。代码是独立实现，图标是原创绘制（见
> [图标与商标](#图标与商标)）。
>
> 想在新窗口 / 新机器上接着做这个项目？先看 **[`docs/HANDOFF.md`](docs/HANDOFF.md)**（工具链精确路径、
> 三条构建命令、模拟器操作备忘、已知坑清单、下一步待办）。本文件是**技术档案**：
> 每个版本改了什么、为什么这么改。

把开源知识库 **Tolaria**（[refactoringhq/tolaria](https://github.com/refactoringhq/tolaria)）
的**磁盘格式**带到 Android：读写同样的「纯 Markdown + YAML frontmatter + `[[双向链接]]`」
文件，并用 Git 做同步。

> **定位**：这不是把 Tolaria 的 React/Rust 源码编译到 Android，而是用 Flutter 实现一个
> **格式兼容客户端**。Tolaria 采用 AGPL-3.0，本项目**不含一行它的代码**，只互操作它开放的
> 磁盘格式（Markdown 文件 + Git 仓库）——格式与协议不属于版权保护对象，因此本项目按
> [MIT](LICENSE) 发布，不触发 AGPL 传染。若你日后拷贝了 Tolaria 的代码，合并后的作品需整体
> 遵循 AGPL-3.0。

**当前状态（已验证，非「纸上代码」）— v0.1.22**

## 图标与商标

**图标是原创的。** 圆角页面 + 三行文本、紫粉渐变，由 `.tools/make_icons_v2.py` 生成
自适应（`ic_launcher_foreground` + 纯白背景）与 legacy（白板 + 圆角）两套，几何规则沿用
旧脚本——页面占容器的 66%、自适应层按 72dp 安全圆反算——所以启动器上的视觉大小不变。

**为什么换**：v0.1.5 到 v0.1.22 的图标是直接从 Tolaria 桌面版仓库取的
`src-tauri/icons/512x512.png`（蓝色水滴 + 白板）。代码互操作不触发 AGPL——文件格式与
协议不属于版权保护对象——但**美术资产是另一回事**，它是受版权保护的表达，同时 logo 还受
原项目的 trademark policy 约束。自己装在手机上用没问题，分发就不一样了。既然这个仓库
可能公开，就换掉了。

**本项目与 Tolaria 官方无关**：不是 fork，不含它一行代码，未经其作者审阅或背书。名字里的
"Tolaria" 只在描述兼容对象。若原作者对命名或图标有异议，会改名 / 换标。

本项目代码按 [MIT](LICENSE) 发布。

## 跑起来

```bash
git clone <this-repo> && cd <repo>
flutter pub get
flutter test                      # 179 例，全绿约 11 秒
flutter build apk --release       # 首次约 90 秒，产物 ~73MB
```

需要 Flutter 3.47 / Dart 3.13 与 JDK 17。`android/local.properties` 不在仓库里（每台机器
的 SDK 路径不同），`flutter` 会自己生成。

如果本机把 Flutter SDK 解压在别处、想绕开 `flutter.bat` 的 bootstrap，用仓库里的包装脚本：

```bash
./scripts/fl.sh test          # 直接调 dart.exe + flutter_tools.snapshot
./scripts/fl.sh build apk --release
```

`scripts/` 里还有测试期用的东西：`mock_ai.py`（假 AI 端点，脚本化 `tool_calls`，不需要
真 Key）、`make_test_vault.py`（造一个几十篇笔记的测试库）、`git_http.py`（本地 http 远端）、
`make_icons.py`、`png_resize.py`、`ad.sh`（adb 截图 / 按 content-desc 点按）。

| 检查项 | 结果 |
|---|---|
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 179/179 通过（git2dart 建仓/提交/删除/.gitignore + 真 clone + ANR 回归 + AI 流式协议 + 上下文拼装 + frontmatter 原地编辑 + 归档/分类落盘 + 分类列表 + Agent 工具层（含 list_notes 按分类过滤 + read_note 错路径回推候选）+ Agent 循环（含 429/5xx 重试 + 限流慢速模式 + SSE 噪音清洗）+ **末轮流式（分片 tool_calls 重组 / 噪音在发送前拦截 / 网关忽略 stream 时降级 / 一个字一张气泡）** + 多轮续接（follow-up 带历史 / 换笔记用 user 轮重述 / 历史按轮裁剪不孤儿工具结果）+ 会话持久化（清空冷启动 / 失败轮不入档） + Agent 时间线 + 工具卡片/确认弹窗 + AI 界面（含「输入区无附件入口」）+ 拉取快路径 9 + parseBocha 4 + GBK/续跑 + setup 草稿 3 + clone 落点探针 + 超限工具协议完整性 + 系统提示分类规则 + 系统提示 SOP 引导 + 撤销提示自动消失 3） |
| `flutter build apk --release` | ✅ 见工作日志（v0.1.22） |
| 模拟器（Android 12 / API 32, x86_64） | ✅ 安装启动、建空库、写笔记、杀进程重启配置仍在；撤销提示约 4 秒自动消失；AI 输入区为纯文本框 |
| 模拟器 · 克隆链路 | ✅ 真机点击「克隆现有知识库」→ 进度浮层 → 300 篇笔记全部落地，无 ANR；无凭据访问受保护仓库时 **1 秒内**弹出中文「认证失败」提示 |
| 模拟器 · 侧边栏 | ✅ 读真实 vault 的 `views/*.yml` + `type:`，41 篇库解析出视图 8 项、类型 7 项 |
| 模拟器 · 归档 / 分类 | ✅ 长按 → 归档 → 归档计数 6→7 且行尾出现归档标记；撤销后回落。长按 → 移动到分类 → 自媒体 5→6、全部内容笔记 12→13，改回后计数全部还原 |
| 模拟器 · **Agent 改库** | ✅ 一句话 → `list_notes` 卡片（耗时/结果可展开）→ `append_note` 弹出「追加内容：欢迎使用-tolaria.md」确认框 → 允许后正文真的被追加，返回列表 mtime 变了、打开笔记能看到新那一行；拒绝则文件一个字节不变 |
| 模拟器 · **Agent 联网** | ✅ 真实 DeepSeek + 博查 key 跑 `web_search` 绿 ✓；多级续跑（撞 12 步上限 → 「继续」接上）；GBK 老页面 `fetch_url` 不崩 |
| 模拟器 · **首次克隆草稿** | ✅ 填表 → 强杀重启 → 表单预填（令牌空）→ 克隆成功进主界面 |
| 应用图标 | ✅ **原创绘制**（圆角页面 + 三行文本，紫粉渐变），由 `.tools/make_icons_v2.py` 生成自适应 + legacy 两套。v0.1.5–v0.1.22 用的是桌面版 logo，当前工作树已替换（尚未发版），见[图标与商标](#图标与商标) |

> 克隆是用本地搭的 smart-HTTP 仓库验证的（Basic 鉴权 + 200 KB/s 限速，模拟慢网），
> 覆盖了 libgit2 的真实网络传输路径，而不是本机目录直拷。见文末「v0.1.2 修了什么」。

验证环境：Windows 11 · Flutter 3.47.7 (stable) · Dart 3.13.5 · AGP 9.1.0 · Gradle 9.3.1
· JDK 17 · Android SDK 36 + Build-Tools 36 + NDK 26.3 + CMake 3.22.1。

---

## 功能（v1：浏览 + 编辑 + Git 同步）

- 从远端 **clone** 现有 Tolaria vault（Git 仓库），或 **新建空知识库**并设置 remote
- 笔记列表、按标题/路径搜索、新建、删除
- Markdown 阅读与编辑（编辑/预览切换），`[[wikilink]]` 点击跳转
- 侧边栏：收件箱 / 全部笔记 / 归档 / 视图（读 `views/*.yml`）/ 类型
- 长按笔记：重命名、**移动到分类**、**归档**、复制路径、删除（归档与分类均可撤销）
- 阅读页 `⋮` 菜单：分类 / 归档 / 复制路径 / 删除；正文上方显示分类与归档徽标
- Git **提交 + 推送**（等价 `git add -A && git commit && git push`）、**拉取**（fetch + FF/merge）
- HTTPS 用户名 / 密码 / Token 认证
- AI 助手两档：**Agent**（能列出/搜索/读取/新建/修改笔记，每次改动前先问你，没有 shell）
  与 **问答**（只把内容发过去拿回答，任何服务商都能用）

---

## 快速开始

```bash
cd tolaria_android

# 一条命令走完 pub get -> analyze -> test -> release APK
FLUTTER=../.tools/fl.sh tool/build_apk.sh     # 用工作区里的 SDK
# FLUTTER=flutter tool/build_apk.sh           # 用 PATH 里的 flutter
```

手动分步：

```bash
flutter pub get
flutter analyze          # 应为 No issues found
flutter test             # 19 个用例应全绿
flutter run              # 连真机/模拟器
flutter build apk --release
```

`android/` 平台骨架、INTERNET 权限、`local.properties` 都已就位，**不需要再跑 `flutter create`**。

> 本机原本没有 Flutter（只有 Android SDK/JDK），已装好 3.47.7 在工作区
> `.tools/flutter`，并用 `.tools/fl.sh` 包装（直接跑 `dart.exe flutter_tools.snapshot`，
> 绕过 `flutter.bat` 那步会卡住的 `pub upgrade` 自举）。把 `.tools/flutter/bin` 加进 PATH 也可以，
> 但记得先 export 下面「国内网络」里的两个变量。

### 环境要求

- Flutter `>= 3.29.3`（实测 3.47.7），Dart `>= 3.7.2`
- Android SDK 34+、Build-Tools、NDK、**CMake 3.22.1**（`git2dart_binaries` 是 ffiPlugin，
  构建时需要 CMake）、JDK 17
- 设备 ABI：**arm64-v8a / armeabi-v7a / x86_64**（libgit2 预编译库覆盖这三种）

### 国内网络：两个镜像必须配

这台机器上踩到的坑都记在这里，换机器照做即可：

**1) pub 依赖**（`pub.dev` 的归档下载只有 ~17 KB/s，会卡住 `pub get`）

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```

**2) Gradle 依赖**（`repo.maven.apache.org` / `plugins-artifacts.gradle.org` 会返 502，
是硬失败而不是「换下一个仓库」）

工程里已把阿里云镜像放在 `android/build.gradle.kts` 与 `android/settings.gradle.kts` 的
仓库列表**最前面**（含 `subprojects { buildscript.repositories }`，因为
`git2dart_binaries` 自带 `buildscript { google(); mavenCentral() }`，会绕过根工程配置）。
不在国内时可删掉那几行 `maven("https://maven.aliyun.com/...")`。

Gradle 发行版（224 MB）也建议用镜像预置，否则 `services.gradle.org` 只有 ~10 KB/s：

```bash
D=~/.gradle/wrapper/dists/gradle-9.3.1-all/<hash>
curl -L -o "$D/gradle-9.3.1-all.zip" \
  https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip
```

> Gradle **不读** `http_proxy` 环境变量。走代理需在 `~/.gradle/gradle.properties` 里写
> `systemProp.https.proxyHost/Port`。

---

## release 构建：R8 必须关掉混淆

AGP 9 默认对 release 跑 R8。开着混淆时这个 App 会在启动时抛异常，实测两种：

```
NoSuchMethodError: no non-static method
  "...SharedPreferencesApiRegistrar;.getAll(...Lkotlin/coroutines/Continuation;)..."
ClassNotFoundException: kotlin/coroutines/intrinsics/CoroutineSingletons
```

原因是 R8 把 `kotlin.coroutines.Continuation` 重命名成 `v4`，Pigeon 生成的 `suspend` 方法
描述符跟着变，而运行期仍按原描述符查找；协程内部还有按类名引用的类。

`android/app/proguard-rules.pro` 用 `-dontobfuscate`（保留名字与描述符，仍做 shrink/优化）
解决。Dart 侧本来就是 AOT，混淆收益很小，不必为此冒险。
如果将来要开混淆，至少要 `-keep class kotlin.coroutines.** kotlinx.coroutines.** io.flutter.plugins.**`。

---

## 使用流程

1. 首次启动 → 填远程仓库地址；**分支可留空**（留空就用远程默认分支，克隆完会显示实际
   用到的分支）。私有仓库填「用户名 + 密码/Token」（Gitee/GitHub 的密码位置填**私人访问
   令牌**，不是登录密码）。
2. 点 **克隆现有知识库**（或 **新建空知识库**）。克隆在后台 isolate 里跑，界面不会卡死，
   有百分比进度和「取消」按钮。
3. 列表页：搜索、新建、点开阅读；**长按一条笔记**弹出菜单（重命名 / 复制路径 / 删除）；
   右上角 `↓` 拉取、`⟳` 提交并推送、齿轮进设置。
4. 编辑页：改标题/正文，`眼睛` 预览，`✓` 保存（写回磁盘 `.md`）。
5. 同步：`提交并推送` / `拉取`。作者名与邮箱来自设置页。

> 克隆采用「先写临时目录 `.tolaria_vault_incoming`，成功后再整体换上去」的方式。旧版本是
> 先删掉现有 vault 再克隆——一旦克隆失败（网络/凭据问题），本地笔记会全部消失。现在失败
> 只会丢掉这次克隆，已有知识库原封不动。

---

## 架构

```
lib/
├─ main.dart                 # 入口；移动端先 await PlatformSpecific.initialize()
├─ app.dart                  # 主题 + 首屏路由（无知识库→Setup，否则→List）
├─ models/
│  ├─ note.dart              # 笔记模型（frontmatter + body → .md）
│  └─ vault_config.dart      # 非敏感配置（路径/remote/分支/身份）
├─ services/
│  ├─ markdown_service.dart  # frontmatter 解析、标题推导、wikilink 预处理
│  ├─ vault_service.dart     # dart:io 读写 .md / wikilink 解析 / 重命名
│  ├─ git_service.dart       # Git 抽象接口 + 平台工厂
│  ├─ cli_git_service.dart   # 桌面：封装系统 git 可执行文件
│  ├─ git2dart_service.dart  # Android：把每个操作打包成 job，交给后台 isolate
│  ├─ git_worker.dart        # 后台 isolate 里的同步 libgit2 实现（真正的 git 逻辑）
│  ├─ git_job_runner.dart    # 派发 isolate、转发进度、支持取消/超时
│  └─ settings_service.dart  # SharedPreferences 持久化（不含密码）
├─ providers/vault_provider.dart  # Riverpod 全局状态
├─ screens/                  # setup / list / view / editor / settings
└─ widgets/note_markdown.dart     # Markdown 渲染 + wikilink 点击
```

**为什么 Git 有两套后端？** 桌面有系统 `git`，`CliGitService` 直接调命令行；Android 没有
`git` 可执行文件，必须用 `git2dart`（libgit2 的 Dart FFI 绑定，自带预编译 `.so`，MIT 协议）
在进程内完成 clone/commit/fetch/push/merge。

**为什么还要一层 isolate？** libgit2 全是**同步阻塞**调用。0.1.0 直接在 UI isolate 上调，
点「克隆现有知识库」后主线程被卡住，Android 5 秒就判 ANR（弹「Tolaria 没有响应」）。
现在每个操作都 `Isolate.spawn` 到一次性 isolate：`git_worker.dart` 里是同步实现，
`git_job_runner.dart` 负责派发、把 0-100 的传输进度回传、以及超时/取消时 `kill` 掉。
`test/clone_local_test.dart` 里有一条回归用例专门断言「克隆期间主 isolate 的定时器仍在跑」。

**提交语义**（`git_worker.dart`）：`index.clear()` + `index.addAll(['*'])`，等价
`git add -A`（新增/修改/删除全部收录，且尊重 `.gitignore`）；若新树与 HEAD 的树相同则直接
返回 `false`，**不会产生空提交**；空仓库的首次提交用 `parents: []` 建根提交。

---

## 已知限制 / 下一步

- **冲突合并**：`pull` 遇到分叉会在库内 merge；若同一文件同一行被两端改动，会把冲突写入
  工作区并抛错提示，**尚未提供冲突解决 UI**。单设备使用基本遇不到。
- **凭据安全**：密码/Token 只存内存，不落盘；要持久化请换 `flutter_secure_storage`。
- **导入本地文件夹**：v1 走「从 Git 远端 clone」；若要直接导入设备上已有文件夹，可加
  `saf`（Storage Access Framework），与 `vault_service` 的读写流程可复用。
- **块编辑器**：Tolaria 的 Notion 式块编辑器（BlockNote/ProseMirror）未复刻，v1 用标准
  Markdown 编辑 + 渲染。
- `flutter_markdown` 已被官方标记 discontinued（当前仍可编译）；后续可迁到
  `flutter_markdown_plus`。
- `git2dart_service.status()` 只反映**已跟踪**文件的变更（libgit2 默认 status 位），新增的
  未跟踪文件不会列出；提交本身不受影响。
- **Agent 模式的边界**：没有 `execute`（跑不了命令），不能碰知识库目录以外的文件。需要跑脚本、
  装依赖、改代码时它会直说"回电脑上做"。
- **Agent 能联网**：`fetch_url` 读给定网页，`web_search` 主动搜关键词（默认 Tavily，
  免 Key 走 DuckDuckGo 兜底；也可切博查 BoCha 国产平替，填博查 Key 走
  `api.bochaai.com`，国内直连延迟低）。两者都只是 HTTP 读，不写。
- **输出格式模板**：在「AI 助手设置」里填一段格式要求（如"用 Markdown 表格、分三点、带来源
  链接"），Agent 每次回答都会尽量遵守；留空则用默认风格（中文、短句、先给结论）。
- **Agent 只支持 OpenAI 兼容协议**：Anthropic / Gemini 的工具协议不同，选它们时界面会提示
  切回问答模式，而不是假装能用。
- **只有一条会话**：v0.1.21 起会话会落盘、重启后自动恢复，但只有当前这一条（顶部「清空对话」
  = 开新会话）。桌面版那种多会话列表 / 归档还没做。
- **长对话会裁剪**：历史按 24000 字符 + 最近 12 轮裁剪，更早的内容不再发给模型（笔记本身
  仍可用 `read_note` 读回）。免费档模型的上下文和限流决定了这是必须的取舍，不是可调项。
- **Agent 流式**：v0.1.22 起每一轮都走 SSE，最终回答逐字出现。代价是 `tool_calls` 必须
  按 `index` 重组（见 v0.1.22 一节）；万一某个服务商的分片格式另类，最坏情况是工具名识别不到，
  模型会收到「没有叫 xxx 的工具」并重试。

---

## 附录：桌面版 Tolaria 的「右键菜单」在哪

原生 Tolaria（Tauri/React 桌面版）确实有右键菜单，但**只在两个地方**：

| 位置 | 怎么操作 | 菜单项 |
|---|---|---|
| 中间的**笔记列表** | 对某一行**右键**（macOS 触控板双指轻点 / `Ctrl`+单击） | 在新窗口打开、收藏、标记已整理、**重命名**、打开邻域、在文件夹中显示、复制文件路径、复制笔记 Git URL、导出 PDF、归档、**删除** |
| 左侧**目录树** | 对文件夹右键 | 新建笔记 / 新建文件夹 / 重命名 / 删除等 |

如果你右键没反应，通常是因为：没点在这两个列表上（点在编辑器正文里只会出格式菜单），或者
笔记列表面板被隐藏了——按 `Ctrl+2`（macOS `Cmd+2`）显示「编辑器 + 笔记列表」。

另外桌面版是**键盘优先**的，很多操作根本不用右键（`Ctrl`/`Cmd`）：

| 快捷键 | 作用 |
|---|---|
| `Ctrl+K` | 命令面板（所有命令都能在这里搜到，右键菜单里的项基本都有） |
| `Ctrl+P` / `Ctrl+O` | 快速打开笔记 |
| `Ctrl+N` | 新建笔记 |
| `Ctrl+Shift+F` | 全库搜索 |
| `Ctrl+D` | 收藏当前笔记 |
| `Ctrl+Backspace` | 删除当前笔记 |

> 上面这些是原生桌面版的行为。**本 Android 客户端没有右键**，等价操作是**长按笔记行**，
> 目前提供「重命名 / 复制路径 / 删除」三项。

---

## 测试

```bash
flutter test
```

- `test/markdown_service_test.dart`：frontmatter 解析（BOM/CRLF/未闭合/非法 YAML）、
  标题推导、wikilink 编解码、`Note.toMarkdown()` 往返。
- `test/git2dart_service_test.dart`：在临时目录上跑**真实的 git2dart**（Windows 与 Android
  走同一套代码），覆盖 init、根提交、增删改、无变更时幂等、`.gitignore` 生效。
- `test/clone_local_test.dart`：从本地仓库真跑 clone，覆盖分支识别、分支不存在时回退到默认
  分支、非空目录拒绝克隆，以及**「克隆期间主 isolate 仍能跑定时器」**（ANR 回归用例）。

---

## v0.1.1 修了什么

### 1. 点「克隆现有知识库」卡死（ANR）—— 已修

**现象**：填完地址和凭据，点克隆，几分钟后弹「Tolaria 没有响应」。

**根因**：`git2dart` 是 libgit2 的 FFI 绑定，**所有调用都是同步阻塞的**。v0.1.0 直接
在 UI isolate 上 `Repository.clone()`，网络传输一旦超过 Android 的 5 秒阈值就判 ANR。
当时设的 `state.busy = true` 完全没用——主线程被占住，连加载中的帧都画不出来。

**改法**：每个 git 操作打包成 job，交给一次性后台 isolate 执行：

- `git_worker.dart` —— isolate 入口 + 全部同步实现，进度用回调上报
- `git_job_runner.dart` —— `Isolate.spawn`、回收进度/结果、超时（15 分钟）、可 `kill` 取消
- 如果某些 ROM 不允许二级 isolate `dlopen` 应用自带的 `.so`，会自动降级到主线程执行
  （界面会卡，但至少能克隆成功）

界面上补了：百分比进度条 + 「取消」按钮。

### 2. 克隆失败会删光本地笔记 —— 已修

v0.1.0 的 `_freshVaultDir()` 是**先 `deleteSync(recursive: true)` 删掉现有 vault，再克隆**。
网络或凭据一出问题，用户本地笔记直接没了，而且没有任何提示。

现在先克隆到 `.tolaria_vault_incoming`，成功后才把旧目录改名、新目录换上去；失败只是丢弃
本次克隆，原 vault 原封不动。

### 3. 分支被写死 `main` —— 已修

v0.1.0 的克隆写死 `checkoutBranch: 'main'` 并把 `main` 存进配置。如果仓库的默认分支是
`master`（很多老 Gitee 仓库都是），会出现两个问题：克隆直接失败；即使换了分支克隆成功，
`push` 也会执行 `HEAD:refs/heads/main`，在远端**新建一条孤儿分支**，而不是更新真正的分支。

现在：克隆返回**实际检出的分支**（读 HEAD），配置里存真实值；`sync` 前还会再读一次当前分支。
「分支」输入框也可以留空（= 用远程默认分支）。

### 4. 其它

- 克隆时指定的分支不存在 → 自动用默认分支重试一次，而不是丢一个 `reference not found`
- 401/403/404/SSL/DNS 等错误翻成中文可操作提示（最常见的是「密码位填了登录密码，应该填
  私人访问令牌」）
- 笔记列表长按 → 重命名 / 复制路径 / 删除（桌面右键菜单的移动端对应物）

---

## v0.1.2 修了什么

### 1. 进度条「卡在 6% 不动」—— 已修

**现象**（v0.1.1 模拟器实测发现）：点克隆后有进度浮层、也确实没卡死，但百分比显示到 6%
就再也不变，直到最后突然完成。用户很容易把这当成「又卡住了」——正是 v0.1.1 想解决的观感。

**根因**：`libgit2` 的 `transfer_progress` 报的是**对象计数**（`received_objects /
total_objects`），不是字节。一个 6.6 MB 的 pack 也就几百个对象，百分比只在「整个对象落地」
时才跳一格；中间几个 MB 的持续下载在界面上完全看不出来。原来的代码还只在百分比变化时才
上报（`if (percent == lastPercent) return;`），等于把唯一的信息源也掐了。

**改法**：

- 新增 `GitProgress`（`lib/services/git_progress.dart`）：`percent` + `receivedBytes` +
  对象数，跨 isolate 用 `toMap()` / `fromMap()` 传，不再用裸 `int`
- 上报阈值改成「百分比变了**或**新增 ≥ 96 KB」——字节在动就一定刷新界面
- 文案变成 `正在传输… 6%（已接收 1.2 MB）`，字节数一直涨，就不会误判成死机
- 浮层再加一行 `已等待 N 秒`（`Timer.periodic`，宿主 isolate 自己计时）。就算 libgit2
  一个字节都不报，用户也能看到界面是活的

### 2. 实测记录（模拟器 Android 12 / API 32）

用本地搭的 smart-HTTP git 服务（`git upload-pack --stateless-rpc`，Basic 鉴权 + 200 KB/s
限速）复现真实网络条件：

| 场景 | 结果 |
|---|---|
| 300 篇笔记 + 6 MB 二进制、带正确凭据 | ✅ 进度浮层出现 → 进度推进 → 克隆完成，列表刷新出 300 条 |
| 同一仓库、不填凭据 | ✅ 1 秒内失败，弹出「认证失败：用户名或密码/令牌不正确……」+ 令牌获取提示 |
| 克隆期间点「取消」 | ⏳ 待复测（第一轮验证到此步时模拟器被关闭） |
| 全程 | ✅ 无 ANR、无崩溃（`logcat` 无 `ANR in com.tolaria` / `FATAL EXCEPTION`） |

---

## v0.1.3 / v0.1.4 修了什么

### 1. 克隆中点「取消」→ App 直接消失 —— 已修（原生崩溃）

**现象**：克隆进行到一半点「取消」，整个 App 瞬间消失，没有 Dart 异常、没有错误弹窗，
`logcat` 里只有 native crash。

**根因**：`GitJobRunner.cancel()` 用的是 `Isolate.kill(priority: immediate)`。libgit2 在
自己的网络线程里跑，Dart 侧只是等它回调；isolate 被强杀后堆内存立刻回收，libgit2 下一次
`transfer_progress` 回调就落在已释放的内存上 → SIGSEGV → 进程消失。

**改法**：取消改成**协作式**，绝不 kill：

- `cancel()` 只置一个标志位，立刻释放界面（`busy = false`，浮层消失）
- libgit2 继续跑完它那一段（通常几秒），`run()` 拿到结果后**丢弃**并抛 `GitJobCancelled`
- 15 分钟超时同样不再 kill，改为「45 秒内拒绝新任务」（`_startDraining`），避免两个 clone
  同时落在同一目录

代价是取消后可能还有几秒的流量，换来的是 App 不会消失。

### 2. 点左上角标题打开侧边栏 —— 新增

桌面版靠左侧栏找笔记：收件箱 / 全部笔记 / 归档 / 视图 / 类型。手机上没有侧栏，所以点
AppBar 里的 **「Tolaria」标题**（或左上角 ☰）唤出抽屉，结构完全对应：

| 分区 | 数据来源 |
|---|---|
| 收件箱 | frontmatter 里**没有** `type:` 的笔记 |
| 全部笔记 | 所有 `.md` |
| 归档 | `archived: true`（兼容 `archive` / `_archived`） |
| 视图 | `<vault>/views/*.yml` —— Tolaria 自己的视图文件，`order` 排序、`filters.all[].field/op/value` 生效 |
| 类型 | 内容笔记的 `type:` 值；显示名/颜色/排序取自同名 `type: Type` 定义文件的 `_sidebar_label` / `_color` / `_order` |

支持的规则：`equals` `not_equals` `any_of` `none_of` `contains` `not_contains`
`is_empty` `is_not_empty`。未知规则**放行**而不是丢弃——宁可多显示，也不要因为读不懂某条
规则就把整篇笔记藏起来。

点任意一项，列表即时过滤，标题变成该视图名。选中的项在抽屉里高亮。

### 3. 类型定义笔记的 YAML 漏到正文 —— 已修

`note.md`、`Skill.md` 这类类型定义文件，frontmatter 里有一个 Markdown 模板：

```yaml
template: |
  ---
  type: Note
  ---
```

解析器原来用 `line.trim() == '---'` 找结束符，于是匹配到模板里**缩进两格**的那行，
frontmatter 被提前截断，阅读页正文里出现 `type: Note`、`_icon: note` 之类的 YAML。

现在要求结束符必须在**第 0 列**（同时仍兼容 CRLF）。

### 4. 补充

- 进度文案：`正在传输… 24%（已接收 420.0 KB）` + `已等待 4 秒`
- `flutter test` 增至 **33 个**（新增 `test/vault_index_test.dart`：视图 YAML 解析、
  四种筛选、类型统计；以及 frontmatter 里带 `---` 的回归用例）

### 实测（模拟器 Android 12 / API 32）

| 场景 | 结果 |
|---|---|
| 克隆 41 篇真实笔记（含 `views/*.yml`、`type: Type` 定义），中途点「取消」 | ✅ 浮层立即消失，进程存活（`pidof` 仍有值），无 native crash |
| 同一次克隆跑完 | ✅ 41 条笔记、侧边栏显示「视图 8 项 + 类型 7 项」，数字与桌面端一致 |
| 点「技术教程」视图 | ✅ 列表只剩 3 条，标题变为「技术教程」 |

---

## v0.1.5：桌面版图标 + AI 助手

### 1. 图标换成了桌面版那个水滴

图标不是重画的，是**直接从桌面版仓库取的**：
`refactoringhq/tolaria` → `src-tauri/icons/512x512.png`（512×512，透明底，白色圆角板 + 蓝色水滴 +
左下一道高光弧）。脚本 `.tools/make_icons.py` 由它生成两套资源：

| 用途 | 文件 | 说明 |
|---|---|---|
| Android 8+ 自适应图标 | `mipmap-anydpi-v26/ic_launcher.xml` + `mipmap-*/ic_launcher_foreground.png` | 背景纯白 `#FFFFFF`，前景只有水滴（透明底），另带 `<monochrome>` 供 Android 13 主题图标 |
| Android 7 及以下 | `mipmap-*/ic_launcher.png`（48/72/96/144/192） | 裁掉外圈阴影后整块缩放，保留桌面版那圈圆角白板 |

两个细节值得记一笔：

- **比例是量出来的，不是估的**。原图白板是 412px（占 512 的 80.5%），水滴高 272px，
  即水滴 = 白板的 66%。自适应图标的系统遮罩只保证中间 72dp（108dp 画布里），
  所以水滴高度按 `72 × 0.66 ≈ 47.5dp` 反算，而不是按 108dp 画布缩。
  这样圆角、圆形、方形三种遮罩下，水滴的视觉大小都和桌面端一致。
- **抠水滴用了泛洪**。`src-tauri/icons/512x512.png` 里水滴是画在白板上的，
  直接裁 bbox 会连白底一起带走。脚本从边界泛洪、把「白板 / 抗锯齿边缘 / 淡阴影」判为非水滴清掉，
  水滴内部那道白色高光因为被蓝色包住、泛洪到不了，得以完整保留。

> 商标提醒：Tolaria 的 logo 受其 trademark policy 约束。自己装在手机上用没问题；
> 若要把这个 APK 公开发布，建议换成自己的图标。
>
> **已处理**（当前工作树）：图标换成了原创的圆角页面 + 三行文本，脚本是
> `.tools/make_icons_v2.py`，旧的 `.tools/make_icons.py` 保留只为记录当时怎么抠的水滴。
> 细节见[图标与商标](#图标与商标)。

### 2. AI 助手：能做什么、为什么不能照搬桌面版

先把桌面版的 AI 拆开看，它其实是**两条完全不同的路**（`docs/ARCHITECTURE.md` 的 AI System 一节）：

| 桌面版 | 机制 | 安卓能否移植 |
|---|---|---|
| **Agent 模式** | 把本机的 Claude Code / Codex / Copilot / OpenCode / Pi / Antigravity / Kiro / Hermes 作为**子进程**拉起来，通过 MCP server 让 agent 读写 vault | ❌ 安卓没有 Node、没有这些 CLI，App 也起不了长驻子进程 |
| **直连模型**（Tolaria 叫 direct model target，Chat 模式） | 直接对 HTTP 端点发 `/chat/completions`，把当前笔记当上下文，**不给 shell** | ✅ 纯 HTTP + JSON |

所以这个版本实现的是**第二条**，也是唯一能在手机上跑通的那条。对应到界面上：

- 笔记阅读页右上角 ✨ → 带着**这篇笔记**进对话
- 笔记列表右下角小 ✨ → 不带笔记，只带知识库目录
- 支持三种协议：**OpenAI 兼容**（DeepSeek / 通义 / Kimi / 智谱 / 硅基流动 / OpenRouter /
  Ollama / LM Studio / 任何自建网关）、**Anthropic Messages**、**Gemini**
- 预设 11 个服务商，选完自动填好 Base URL 和默认模型，只需粘 Key
- 「检测连接」走 `GET /models`（不花 token），列出可用模型直接点选，省得手打模型名打错
- 流式输出，可中途「停止」；回答可**复制**或**一键存为笔记**

**能做的**：读当前笔记、读知识库目录（标题 + 路径 + 类型）、回答问题、把回答存成新笔记。
**做不到的**（也不打算做）：让它自己翻别的笔记全文、改已有笔记、执行命令。
桌面版能那样做是因为 agent 有 MCP 工具和文件系统权限；手机端没有这层能力，
所以把边界画在「读 + 建议 + 你确认后落盘」，而不是假装它有工具。

#### 上下文是怎么拼的

对应 `lib/services/ai_context.dart`，和桌面版的取舍不同：

- 当前笔记正文**直接给足**：超过 16000 字时**掐中间**（保留头 12000 + 尾 4000）。
  桌面版是掐尾巴，因为它告诉 agent「要全文就用 `get_note` 去读」——手机端没有这个工具，
  而笔记的结论通常在最后，掐尾会正好丢掉最该看的段落。
- 其余笔记**只给目录**（最多 200 条：路径 — 标题 · 类型），并在 system prompt 里明确写
  「目录没有正文，需要具体内容就让用户打开那篇」。宁可让模型说"我看不到"，
  也不要它根据标题编内容。
- 历史最多回放 20 条，错误气泡不进 prompt。

#### 配置与安全

`设置 → AI 助手 → 模型与 API Key`。Key 存在 `SharedPreferences`（应用私有目录，
别的 App 读不到），**不写进笔记、不进 git**。桌面版存在 `ai-provider-secrets.json`，
性质相同。手机上如果借用给他人，建议清空。

#### 怎么在没有 Key 的情况下验证

`.tools/mock_ai.py` 是一个本地假端点（OpenAI 兼容），会**逐字流式输出**，
并且**把收到的笔记标题念回来**——如果 App 忘了附上下文，回答会直接说"没有收到任何笔记"，
一眼就能看出来，比看一段看似合理的假答案可靠。跑法：

```bash
python .tools/mock_ai.py --port 8090 --delay 0.04
# 模拟器里 Base URL 填 http://10.0.2.2:8090/v1，Key 随便填
```

### 3. 测试与实测

`flutter test` 从 33 个增至 **56 个**，新增两个文件：

- `test/ai_service_test.dart`（11 个）：起真实 `HttpServer`，跑通 OpenAI SSE、Anthropic
  `content_block_delta`、Gemini parts、`[DONE]` 之后的内容被忽略、keep-alive 不打断、
  网关返回整段 JSON 时的回退、401/429 的中文翻译、`/models` 解析、连不上时的网络提示、
  以及「缺 Key 时不发请求」。
- `test/ai_context_test.dart`（12 个）：当前笔记与目录的拼装、长笔记掐中间保留结尾、
  关掉上下文后不泄漏笔记内容、错误气泡不进历史、历史上限 20、目录上限 200、本地端点免 Key。

> 写测试时踩到一个 Dart 坑：`HttpResponse.write()` 默认按 **latin1** 编码，
> 往测试服务端写中文会直接抛 `Invalid argument (string): Contains invalid characters`，
> 而 `response.encoding = utf8` 又因为 sink 已绑定而抛 `encoding is not mutable`。
> 正解是 `response.add(utf8.encode(...))` 直接写字节。

### 4. 模拟器实测（Android 12 / API 32）

| 场景 | 结果 |
|---|---|
| 桌面图标 | ✅ 白底蓝水滴，与桌面版一致（启动器圆角遮罩下也不走形） |
| 设置 → AI 助手 → 检测连接 | ✅ 拉回模型列表并可选，选中后自动填入 |
| 阅读页 ✨ → 发问 | ✅ 流式逐字输出；Markdown 标题/列表/代码块/表格/引用块渲染正常 |
| 上下文是否真的发出去 | ✅ 假模型回显：标题《短视频带货脚本 SOP》+ 41 篇知识库目录 + 原问题 |
| 存为笔记 | ✅ 生成「总结这篇笔记的要点.md」，列表顶部可见，底部提示条可读 |

#### 实测抓到的三个问题（都已修）

1. **请求体被网关卡成空** —— 最迷惑的一个。Dart 的 `HttpClient` 在长度未知时用
   `Transfer-Encoding: chunked` 发送 body，而当时那个手写测试服务端只读 `Content-Length`，
   于是解析出空对象。现象是：模型**照常回答**，但说"没有收到你的问题/笔记"——
   看起来像 app 没传上下文，实际是代理没解 chunked。
   现在请求前显式 `request.contentLength = payload.length`，绕开这类网关。
   （真实大厂 API 都能解 chunked，但自建网关/老代理不一定，成本一行，值得做。）

2. **「已存为笔记」的提示看不见** —— `composer` 原来放在 `body` 的 Column 末尾，
   SnackBar 从 Scaffold 底部浮起，正好被输入框盖住。用户点完按钮毫无反馈，
   会以为没生效然后连点。现在 composer 移到 `bottomNavigationBar` 槽位，
   SnackBar 自然显示在它上方。

3. **同一会话存出多条同名笔记** —— 标题原来取**回答的第一行**，
   于是几轮对话存下来的笔记全叫"这是一段模拟回答…"。
   现在标题取**产生这条回答的那个问题**，回答作为正文，
   落在笔记列表里才认得出来。

---

## v0.1.6：长按菜单补上「归档」和「分类」

侧边栏早就有「收件箱 / 全部笔记 / 归档 / 视图」四项，但点了没地方改 —— 归档和分类只能在
桌面端做。这一版把两件事接到长按菜单上，并且按桌面端的**字节格式**写。

### 1. 归档写什么：`_archived`

查了桌面版的 `src-tauri/src/frontmatter/keys.rs`，归档的规范键是 **`_archived`**
（读取时兼容 `archived` / `Archived`，写入时统一成 `_archived`）：

```rust
FrontmatterKeyRule {
    read_key: "_archived",
    write_key: "_archived",
    aliases: &["_archived", "Archived", "archived"],
    canonicalize_on_write: true,
},
```

所以手机端：归档写 `_archived: true`；**取消归档是把整个键删掉**，而不是写 `false` ——
恢复后的笔记和从没归档过的笔记长得一样，不会在 Git diff 里留一行垃圾。

### 2. 分类是什么：就是 `type:`

桌面版的「视图」本质是保存下来的过滤器，格式在 `demo-vault-v2/views/active-projects.yml`：

```yaml
name: Active Projects
filters:
  all:
    - field: type
      op: equals
      value: Project
```

也就是说**一个笔记属于哪个分类，只由它的 `type:` 决定**，视图只是把这个值翻译成侧边栏的一行。
于是「移动到分类」的动作就是改 `type:`，不需要动别的文件。

分类候选列表（`VaultIndex.categories`）只由**已经存在的值**组成：

- `type: Type` 的类型定义文件（`_sidebar_label` / `_color` 优先）
- 笔记里已经在用的 `type:` 值（没有定义文件也算，否则「账号资料」这类就没入口）
- 视图只在 ①它只有一条规则 ②规则是 `type equals X` ③X 确实有笔记在用 时，贡献**标签和颜色**

刻意**不**把「未归档/系统文件」这类 `none_of` / `is_empty` 视图列进候选：写 `type:` 根本
进不去，列出来只会让用户点了没反应。

### 3. 为什么不用 `Note.toMarkdown()` 整段重写

`Note.toMarkdown()` 会把整个 frontmatter 重新序列化：键顺序变、引号风格变、
`template: |` 这种 block scalar 被压成一行。翻一个归档标记就重排人家的类型定义文件，
是不可接受的。

所以新增 `FrontmatterEditor.upsert()`，只动目标行：定位 `key:` 行 → 换成新值或删掉
（连同它的缩进行：YAML 列表、嵌套映射、block scalar）→ 其余字节原样保留，含 BOM 和 CRLF。
实测把一条笔记从「Skill」改成「自媒体」再改回来，**文件内容与原来逐字节相同**，
Git 工作区没有产生 diff，只有 mtime 变了。

### 4. 界面

长按菜单（桌面版右键菜单的手机版）：

| 项 | 说明 |
|---|---|
| 重命名 | 副标题显示文件路径 |
| 移动到分类 | 副标题显示「当前：X」/「当前未分类（收件箱）」 |
| 归档 / 取消归档 | 标签和副标题随当前状态切换 |
| 复制文件路径 | 不变 |
| 删除 | 红色，保持在最下 |

- 分类面板：`不分类（回到收件箱）` + 每个分类（颜色点 + 篇数 + 当前项打勾）+ `新建分类…`。
  「新建分类」会写一个 `views/<名字>.yml`（桌面端同样认），顺手把这条笔记划进去；
  如果输入的名字只是已有分类的另一种写法（大小写/标签不同），复用它，不建重复视图。
- 归档和分类都有**撤销**：SnackBar 上的按钮直接把值改回去，不用重新走一遍面板。
- 笔记行副标题变成 `分类 · 路径`，归档的行尾多一个小图标 ——「全部笔记」里仍然能看到归档项，
  不标记的话看不出区别。
- 阅读页原来那个裸露的删除图标换成 `⋮` 菜单（分类 / 归档 / 复制路径 / 删除），
  删除不再紧挨着编辑；正文上方用两个小徽标显示「分类」和「已归档」。

### 5. 实测（模拟器 Android 12 / API 32）

| 场景 | 结果 |
|---|---|
| 长按 → 菜单 | ✅ 五项齐全，分类副标题正确显示「当前：Skill」 |
| 归档 → 撤销 | ✅ 归档 6→7，行尾出现归档标记，提示条带「撤销」；撤销后标记消失 |
| 移动到分类 | ✅ 面板列出 自媒体 6 / 个人成长 2 / 灵感素材 1 / 技术教程 3 / 账号资料 1，当前项打勾 |
| 分类后计数 | ✅ 自媒体 5→6、全部内容笔记 12→13、未归档/系统文件 21→20，改回后全部还原 |
| 新建分类去重 | ✅ 输入 `skill` → 复用已有「Skill」，不产生第二个视图 |
| 阅读页 ⋮ | ✅ 菜单四项；打开已归档笔记时显示「个人成长」「已归档」两枚徽标 |

> 一条副作用值得知道：改 frontmatter 会更新文件 mtime，所以「全部笔记」按修改时间排序时，
> 刚归档/刚分类的笔记会跳到顶部。桌面端写文件也是同样的结果，不是手机端特有的行为。

---

## v0.1.7：长按菜单离导航栏远一点

**问题**：长按菜单是贴底弹出的，`删除` 那一行的下边缘和屏幕底部重合（实测红字距屏底
**7 px ≈ 2 dp**）——系统三键导航 / 手势条的返回热区就在那儿，滑到一半手指搭在边缘就可能点中。

**两个原因叠加，只加 padding 不够**：

1. 原先外层是 `SafeArea`，但它读的是 `MediaQuery.padding.bottom`。App 全屏（edge-to-edge）时
   这个值经常是 **0**，SafeArea 等于什么都没做。
2. `showModalBottomSheet` 默认高度上限是屏高的 **9/16**（400 dp @ 640 dp 屏）。五行 + 手势条
   刚好顶到上限，多出来的底部间距会被 Column 溢出裁掉 —— 于是「加了 padding 看起来没变」。

**改法**：

- 新增 `lib/widgets/sheet_insets.dart`：
  ```dart
  final system = max(padding.bottom, max(viewPadding.bottom, systemGestureInsets.bottom));
  EdgeInsets.only(bottom: max(system + 16, 32));
  ```
  取 `systemGestureInsets` 是因为手势导航下只有它反映返回热区；两者都为 0 的机型（本机 MuMu
  就是）兜底给 32 dp。
- 长按菜单加 `isScrollControlled: true` 抬掉 9/16 上限，内容外面套
  `SingleChildScrollView`（小屏再挤也不会被裁）。
- 分类面板同样换成这个间距。

**实测（MuMu / Android 12，1080×1920 @ 480 dpi）**：

| 指标 | v0.1.6 | v0.1.7 |
|---|---|---|
| `删除` 文字底边距屏幕底部 | 7 px（≈2 dp） | 154 px（≈51 dp） |
| `删除` 行底边距屏幕底部 | 0 px | 96 px（**32 dp 死区**） |

`删除` 依然有二次确认，实测点开弹「删除笔记？」，取消后列表无变化。
`flutter analyze` 0 问题，`flutter test` **80/80**。

---

## v0.1.8：Agent 模式 —— 让模型真的能改你的笔记

v0.1.5 的 AI 只是"把笔记发过去、拿回答回来"，用户想改一句话得自己动手。桌面版能做到
"让 AI 改"，靠的是把本机的 Claude Code / Codex 当子进程拉起来、再丢给它一个 MCP server。
安卓上这条路走不通（没有 Node、不能常驻 CLI 子进程），所以这一版把**同样的能力在 Dart 里
重写了一遍**：模型拿到的是一组工具，循环在 App 内跑。

### 1. 工具层：9 个，没有 shell

`lib/services/agent/vault_tools.dart`

| 工具 | 作用 | 写？ |
|---|---|---|
| `list_notes` | 按 glob 列路径 + 标题，最多 200 条 | |
| `read_note` | 读整篇（含 frontmatter），可分段 | |
| `search_notes` | 全文/正则搜索，带上下文行 | |
| `note_meta` | 只读 frontmatter（分类、归档、链接） | |
| `fetch_url` | HTTP GET 一个网页 → 纯文本，截断 6000 字符 | |
| `web_search` | 主动搜关键词 → 标题/链接/摘要（有 Tavily Key 走 API，否则免 Key 抓 DuckDuckGo） | |
| `create_note` | 新建笔记，同名自动加 `-2`，**绝不覆盖** | ✅ |
| `edit_note` | 替换一段文字，`old_string` 必须**唯一命中** | ✅ |
| `append_note` | 末尾追加，原有内容不动 | ✅ |

对照桌面版实测的工具使用频次（read 10 / webfetch 10 / grep 8 / glob 6 / execute 6 /
edit 5 / create_note 2 / write 1），`execute` 是唯一没有复刻的——手机上没有意义也没有
安全边界可言。缺了它，模型被要求跑命令时会明说"这台设备不能跑命令，建议回电脑上做"。

**三道护栏都在工具层，不写在提示词里**（提示词只是请求，代码才是约束）：

- `_safeRelative()`：拒绝绝对路径、盘符、`..`、`.git`、非 `.md`、越出 vault 的路径。
- `edit_note` 先数命中次数：0 次说"没找到，先 read_note 看看"，>1 次说"出现 N 次，
  把 old_string 写长一点"，不让模型猜。
- 写工具必须先拿到用户确认（见下）。

### 2. 循环：`AgentRunner`

`lib/services/agent/agent_runner.dart`，一个 `Stream<AgentEvent>`：

```
system prompt（含知识库概况 + 当前笔记）
  → 请求（tools + tool_choice:auto, stream:false）
  → 有 tool_calls？执行 → 结果以 role:tool 回填 → 再请求
  → 没有 tool_calls 了 → yield AgentText → 结束
```

- `maxSteps=12`：防止模型自己绕圈；到顶就 `AgentNotice("达到 N 步上限")`，不假装完成。
- `maxToolCallsPerStep=4`：一步里要调 5 个工具时只执行前 4 个，并告知模型。
- 取消：`cancel()` 后不再发起下一步、不再跑工具，正在读的响应直接丢弃。
- **不做流式**。`tool_calls` 在 SSE 分片里被拆成多段再拼回来，是静默损坏的经典来源；
  工具轮次本来每次都短，只有最后一句话值得流式，以后可以只给末轮开。

### 3. 写之前一定问：确认弹窗带 diff

`lib/widgets/agent_view.dart` 的 `showToolApproval()`

- `edit_note`：左边红底「原文（将被替换）」，右边蓝底「改为」。
- `append_note`：蓝底「追加内容」+ 一句"原有内容不动"。
- `create_note`：标题、分类、正文预览。
- 按钮只有「不改」和「允许这次改动」，**点窗外 / 按返回都算不改**——"不"必须是最省事的
  那个选择。
- 拒绝不是错误：模型会收到 `用户拒绝了这次修改，文件没有改动。` 并换个方案，循环继续。
- 没有确认回调（比如将来做定时任务）时**默认拒绝**，不会出现"看起来在问、其实已经写了"。

### 4. 时间线：看得见每一步

`lib/providers/agent_provider.dart` + `AgentTimeline`

- 用户气泡 / 工具卡片 / 模型正文 / 提示条，按发生顺序排。
- 工具卡片默认折叠成一行：图标 + 中文动词（"修改笔记"而不是 `edit_note`）+ 目标路径 +
  状态（转圈 / 对勾 / 红叉）。点开才是参数 JSON 和结果原文。
- 失败的卡片**自动展开**，红边 + 失败原因——要用户自己去点开找错太糟了。
- 写操作有「改动」小标签；所有改动落盘后**立即重载笔记列表**，否则列表还显示旧 mtime，
  用户会以为没生效。
- 顶部 chip 显示当前引擎（Agent / 问答），点开有两个选项和一句话说明。

### 5. 顺手修的两处

- **设置页说明过时**：v0.1.5 写的是"桌面版能调 Claude Code 改文件，安卓上做不到"。现在
  做到了，文案改成"两种用法共用这里的配置，工具一样边界更窄"。
- **连接失败只说 `SocketException`**：现在报 `连不上 10.0.2.2:8090。检查 Base URL、端口，
  以及手机和电脑是否在同一个网络。（Connection refused）`。手机上这条错误九成是地址填错，
  不告诉用户试的是哪个地址等于没说。

### 6. 实测（MuMu / Android 12）

用 `.tools/mock_ai.py`（这一版给它加了 `tools` 分支：第一轮 `list_notes`，第二轮
`append_note`，第三轮出正文）跑完整链路：

| 步骤 | 结果 |
|---|---|
| 一句话 → 工具调用 | ✅ 先出现「列出笔记」卡片，执行完变对勾，展开能看到 `{"limit":20}` 和结果「共 1 篇」 |
| 写操作拦截 | ✅ 弹出「追加内容：欢迎使用-tolaria.md」，带内容预览和两个按钮 |
| 允许 | ✅ 卡片带「改动」标签；返回列表 mtime 从 14:33 变成 14:44；打开笔记正文多出追加的那一行 |
| 拒绝（单测覆盖） | ✅ 文件一个字节不变，模型收到"用户拒绝了"后改口 |
| `execute` 之类不存在的工具 | ✅ 转成文字告诉模型，不会崩 |

`flutter analyze` 0 问题，`flutter test` **130/130**（新增 50 个：工具层 23、循环 12、
时间线 8、卡片与弹窗 5、界面 2）。测试全部跑在真 `HttpServer` 上，脚本化回放
`tool_calls` 与 `role:tool` 回填，所以"第二次请求带没带工具结果"这种协议细节是被断言过的，
不是靠肉眼看。

---

## v0.1.22：Agent 末轮流式 —— 难点不在流，在 `tool_calls` 分片

v0.1.8 起 Agent 一直是 `stream: false`，理由是「`tool_calls` 在 SSE 分片里被拆开再拼是静默出错的
常见来源」。这句话没错，但结论错了：真正要解决的是**分片重组**，不是绕开流式。代价是最终回答
要等整段生成完才蹦出来，长回答体感像卡住。

### 为什么"只给最后一轮流式"做不到

哪一轮是最后一轮，只有拿到响应才知道。想只流最后一轮，就得先知道有没有 `tool_calls`——
那正是流式要解析的东西。所以只能**每一轮都流**：工具轮次先把它那句「我先查一下」流出来，
后面照旧跑工具。

### 三处必须做对

**1. 按 `index` 累积，不按 `id`**

分片里每段 `tool_calls` 只带 `index`（0/1/2…），`id` 和 `name` 早期可能是空的：

```
{"index":0,"id":"call_1","function":{"name":"read_note","arguments":"{\"pa"}}
{"index":0,"function":{"arguments":"th\":\"a.md\"}"}}
```

- `arguments` 只能**字符串拼接**；
- `name` 只在非空时**取一次**（拼接会得到 `list_noteslist_notes`）；
- `id` 取到非空值就覆盖（它可能在第一个分片就到齐）。

**2. 流过的文本不能再补一个整段 `AgentText`**

否则同一个回答会出现两次：一次逐字打出，一次整段粘贴。`_drive` 里用 `streamed` 标记本轮
有没有发过 delta，已发则不再发 `AgentText`。

**3. SSE 噪音要在**发送前**拦住，不能事后清理**

v0.1.20 的 `_visibleText()` 是在整段文本上清洗，流式下不能用——已经显示出去的字收不回来。
新增 `_pumpVisible()`：遇到**没有闭合花括号的 `{`** 就往后压着不发（智谱那种被 stringify 的
帧一定以 `{` 开头），认出 `{"index": N` 就整段扣住；流结束后再用 `_visibleText()` 统一清洗，
把合法的 `{"index": 0}` 正文在最后补发出去。判据仍是「带 `delta`/`finish_reason` 才算噪音」。

### 顺带修的一个真 bug

改成 `StreamController` 之后（生成器没法从 socket 回调里 yield），`onCancel` 会在流**正常结束**
时也触发一次，等于把 `_cancelled` 永久置真——**同一个 runner 的第二轮会被判成"用户已取消"，
一个请求都不发**。现在用 `finished` 标志区分「用户按了停止」和「这一轮自己跑完了」。
这个问题是测试 `a follow-up turn replays the previous conversation` 抓到的（历史里只剩
`['system','user']`）。

### 兼容与降级

- **忽略 `stream: true` 的网关**（不少国内代理会）：响应是 `application/json`，走
  `_decodeWholeBody()` 整段解析，照旧发一个 `AgentText`，不流但能答。
- **重试**：429/5xx 在响应体之前到达，所以退避重试仍然安全。万一真在已经吐字之后失败，
  不再重试（重发会让回答打印两遍），直接报错。
- **滚动**：`ai_chat_screen` 原来只在"时间线条目变多"时跟随到底部；逐字增长不改变条目数，
  补了「最后一条回答变长也算增长」。

### 验证

新增 5 例：流式分片拼成完整回答且**不重复出整段** / 分片 `tool_calls` 重组后参数正确、
回显的 `id` 与 `arguments` 完整（这正是以前会 400 的地方）/ 帧粘进 delta 不显示 /
网关忽略 stream 时降级正常 / 逐字增长只产生**一个**气泡。
`flutter analyze` 干净；`flutter test`：**179/179**。

---

## v0.1.21：连续对话记不住上一句 —— 根因是「只有输入『继续』才带历史」

用户原话：「现在是连续对话想不起前一句的内容，这点让我很难受。」

**这不是模型能力问题，是两处代码缺陷。**

### 根因

1. **Agent 模式每轮从零开始**。`AgentChatNotifier.send()` 里：

   ```dart
   history: _isContinueText(text) ? _lastHistory : null
   ```

   `_isContinueText` 只认整句恰好是「继续 / 接着做 / continue」（≤12 字、整句匹配）。
   用户正常追问「那第二点呢」匹配不上 → 传 `null` → 模型收到的是**全新的 system prompt
   ＋这一句**，上一轮的问答和工具结果全部消失。Agent 又是默认模式，于是几乎每次追问都撞上。

2. **无工具调用时，助手的回答根本没进 transcript**。`AgentRunner.run()` 在
   `rawCalls.isEmpty` 分支直接 `return`，没有把 `{'role': 'assistant'}` 追加进 `messages`。
   于是"历史"里只有一串 user 轮，模型连自己上一句说过什么都不知道。这条以前不显形，
   因为历史只服务于「继续」这一条路径。

顺带一层缺失：对话只存内存（`ai_provider.dart` 原注释写着 "killing the app drops it"），
杀进程就没了；桌面版是把会话落盘（`ai-workspace-sessions.json`）且能翻旧会话。

### 处理

**Agent 侧**

- `run()` 的 `history` 从「续跑专用」变成「每一轮都用」；删掉 `_isContinueText` 与
  `_continuePattern`——「继续」不再是特殊路径，它就是普通追问。
- transcript 只在 `completed` 时提交：请求根本没打到服务端的那一轮（连不上 / 401）不写进历史，
  否则下一轮会给模型一条「有问无答」的悬空 user 轮。
- **按轮裁剪**（`_pruneHistory`）：24000 字符预算 ＋ 最近 12 轮，切片**只能落在 user 轮边界**。
  原因：assistant 的 `tool_calls` 必须被等量的 `tool` 结果紧跟，切在轮中间会得到
  `insufficient tool messages following tool_calls message` 的 400。最新一轮即使超预算也保留，
  否则模型没有题可答。
- **换笔记才重述**：`_contextSignature = path|body.length`。同一篇追问不重复上传 1.2 万字；
  笔记被改过（长度变了）或换了笔记，才把最新正文塞进**这一轮的 user 消息**。
  不走第二条 system——部分网关拒绝会话中途出现 system 角色。

**持久化（新增 `services/ai_session_store.dart`）**

- 两个独立 key（agent / chat）：两个 notifier 各按自己的节奏写，共用一份会互相覆盖。
- 存时间线 ＋ transcript；`AgentWorkingItem`（"正在思考…"）不存，中途被杀的卡片恢复为
  「（应用关闭时中断）」，免得留一个永远转的圈。
- 全部 `try/catch` 兜底：存储不可用或 JSON 坏了都不能让面板答不了话（widget 测试也没有插件通道）。
- 恢复时把 `_contextSignature` 清空，强制重启后第一轮重述当前笔记——App 关着的时候笔记可能被改过。

### 验证

- 新增 7 例：追问带上一轮问答 / 换笔记走 user 轮且只有一条 system / 长历史按轮裁剪且无孤儿
  `tool` 消息 / 第二次 send 带第一轮 / 同笔记不重发而改过才重发 / `clear()` 冷启动 /
  失败轮不入档。
- `flutter analyze`：No issues found；`flutter test`：**174/174**。
  > 这个环境下多文件并发时偶发 flutter_tester 进程级抖动（`Unable to connect to
  > flutter_tester` 或某个文件 `loading` 失败），**`-j 1` 串行必过**；定位问题时也先单跑。

---

## v0.1.20：智谱把 SSE 帧塞进正文，聊天框里出现了裸 JSON

真机截图：发「帮我想一下戒烟的好处并写一篇笔记」，AI 气泡里先是一句正常的话，
紧接着整段滚出：

```json
{"index":0,"finish_reason":"tool_calls","delta":{"role":"assistant",…,
 "tool_calls":[{"id":"call_2026…","function":{"name":"web_search",
 "arguments":"{\"query\":\"戒烟的好处\"}"}}]}}
```

这是**流式响应的一个 chunk**，被智谱免费档服务端 `stringify` 后放进了
`message.content`。我们请求里明明写了 `stream: false`，那是对方的实现问题。

它有两个后果，第二个更麻烦：

1. 用户看到裸 JSON。
2. **这段文本被写进了 `messages` 历史**，模型下一轮看到"自己这么说过"，就更可能
   继续这么输出。

### 处理

新增 `_visibleText()`：在 assistant 文本进入气泡和 transcript **之前**清洗。

- 找 `{"index": N` 开头的片段，做**花括号配对**（字符串感知，`"}` 不误判），
  若这段里含 `delta` 或 `finish_reason`，判定为协议噪音并整段删除；反复直到没有。
- 判据刻意收窄：只有带 `delta`/`finish_reason` 的 JSON 才删。模型正经解释
  「返回体是 `{"index": 0}` 这样的结构」时，花括号原样保留。
- 清洗后的文本**两处都用**：既进气泡，也进历史——只清一处等于留个坏样本给模型模仿。

### 验证

- 新增 2 例：真实形态的噪音被剥掉（断言气泡文本、以及 `lastMessages` 里都不含
  `finish_reason`）＋ 合法 JSON 回答的括号不被误删。
- `flutter analyze`：No issues found；`flutter test`：**167/167**
  （162 + 5，分两批跑——`clone_*` 那 5 例在全量里偶发进程级抖动，单跑 / 分局跑必过）。

> 同一个"免费档"下，智谱的 flash 系列在协议层也不完全一致：`stream:false`
> 不一定给出非流式结构。客户端能做的就是**别信单个字段，做防御性清洗**。

---

## v0.1.19：智谱免费档为什么一直 429 —— 模型之间限流差十倍

用户问："现在是智谱的免费模型，一直提示服务商限流是为什么。" 查下来不是 bug，
是**免费档内部差别巨大**：

| 模型 | 社区实测（连发 15 个请求） |
|---|---|
| `glm-4-flash` | 15/15 通过，不限连发（号称 30 并发） |
| `glm-4.7-flash` | **第二个就 429**，15 个里 14 个被限 |

而 Agent 模式**每步发一次请求**（一轮 5–12 步）。在限流严的免费档上，第一步成功、
第二步就撞墙——重试也救不了，因为第三步、第四步还在同一个限速窗口里。

### 改动

1. **429 的文案带上服务商原话**（原来是固定一句话，看不到 `code 1302
   请求过于频繁` 这类线索），并点明"免费档限流按秒算，换个宽松模型通常立刻就好"。
2. **撞过一次 429 就让这一轮进入慢速模式**：之后每个请求前至少间隔
   `rateLimitGap`（默认 1.2 秒），并在界面上说一声「已切到慢速模式：这轮后面
   每个请求前多等 1.2 秒」。一轮 10 步多花 12 秒，但**能跑完**——比第五步失败重来
   划算得多。
3. 慢速模式只作用于当前这一轮（`AgentRunner` 每轮新建），下次任务重新判断，
   不会让本来不限流的模型一直慢下去。

### 验证

- 新增 1 例：429 之后同轮后续请求被限速（断言提示先「慢速模式」后「限流」、
  请求数正确）。原有 2 例 429 测试加 `rateLimitGap: Duration.zero` 保持瞬时。
- `flutter analyze`：No issues found；`flutter test --concurrency=1`：**165/165**。

> 结论给用户：**先把模型从 `glm-4.7-flash` 换成 `glm-4-flash`**，限流当场消失；
> 慢速模式是给"只能用严档"的人兜底的，不是替代方案。

---

## v0.1.18：模型编了一个不存在的目录，然后拿同一个错路径重试两次

真机截图（v0.1.17 已装）：429 重试和 SOP 引导都生效了——先「搜索笔记 脚本 SOP」，
再「读取笔记」。但读的是 **`Skill1/短视频带货脚本 SOP.md`**，失败，然后再读
**同一个错路径**，再失败。vault 是扁平的，真实文件名就是 `短视频带货脚本 SOP.md`。

两个问题叠在一起：

1. 模型会**自己造目录前缀**（`Skill1/`、`Skill/`）——它刚调完 `list_notes(type:"Skill")`，
   就把分类名当成了文件夹。
2. `read_note` 报「找不到」时**只说找不到**，模型没有新信息可用，于是原样重试。

### 改动

1. `vault_tools.dart`：新增 `_notFoundMessage()`。路径不存在时，按文件名和标题做
   两级匹配（精确 → 去 `.md` 后包含，且短于 4 字符不参与，否则「脚本」能命中半个库），
   把最可能的 1–3 个**真实相对路径**写进错误里：

   > 找不到 `Skill1/短视频带货脚本 SOP.md`。路径必须用 list_notes / search_notes
   > 返回的原样相对路径。可能你想读的是：`短视频带货脚本 SOP.md`

2. `agent_runner.dart` 系统提示第 2 条改成：路径要用**原样**相对路径，别加目录前缀
   （知识库通常扁平）；报「找不到」时直接改用错误里的候选或重新 list_notes，
   **不许拿同一个错路径再试**。

### 验证

- 新增 2 例：错前缀 → 错误里带回正确路径（`可能你想读` + 带反引号的真实文件名）；
  完全无关的路径（`zzz/qqq.md`）仍是普通 not-found，不乱猜。
- `flutter analyze`：No issues found；`flutter test --concurrency=1`：**164/164**。

> 这类"工具报错但不给下一步"是 Agent 最容易死循环的地方。兜底原则：**工具的失败
> 信息必须包含模型能直接采用的东西**（候选路径、可用值、约束），否则它只会重试。

---

## v0.1.17：429 限流改成"自动等一下再试"，不再直接报错

真机截图：发一句话，红条 **「请求太频繁（429），等几秒再试。」**，任务就没了。
logcat 里没有任何 Dart 异常——这是服务商（DeepSeek）的限流响应，只是被原样翻译
成了错误，**没有任何重试**。而 Agent 一轮要连发多次请求（每步一次），中途撞上
限流，整轮任务就废了。

### 改动

`agent_runner.dart`：`_chat` 拆成 `_chatOnce` + 重试包装。

- 只重试 **429 和 5xx**（429/500/502/503/504）——这类是"等一会儿就好"。
- **不重试 400/401/402/403/404**——参数错、key 错、欠费、没权限，重发一百次也
  是同一个结果，只会让用户白等 3 秒。原来那条 402「余额不足」的测试继续钉死这点。
- 重试 2 次，默认退避 1s → 2s；服务商回了 `Retry-After` 就听它的（只认秒数，
  上限 15 秒——HTTP date 形式要依赖手机时钟，手机时间不准就会卡很久）。
- 重试期间用 `onNotice` 往界面塞一条提示：「服务商限流（429），1 秒后自动重试
  （第 1/2 次）」。这句提示走的是**回调**而不是事件流——因为事件流此刻正停在
  `await _chat(...)` 里，yield 不出去。这也是"卡住"和"在等"的唯一区别。
- 重试是安全的：工具在上一步就执行完了，结果已在 `messages` 里，重发只是把同一个
  问题再问一次，不会重复写文件。

### 验证

- 新增 2 例：429 → 自动重试并成功（断言提示含「限流」「自动重试」、请求数 2、
  最终答案正常）＋ 连续 3 次 429 → 放弃并报出中文 429 文案（提示恰好 2 次、
  请求恰好 3 次）。
- `flutter analyze`：No issues found；`flutter test --concurrency=1`：**162/162**。
- 测试里踩到的坑：脚本化服务器原本"先取回复再定状态码"，429 那次把准备好的
  回复吃掉了，重试就拿到"（脚本用完了）"。改成**只有成功响应才消费 scripts 的
  回复**。

> Chat 模式（问答）仍不自动重试——它是用户手动发起、失败后重发很自然，且流式
> 响应中途重试需要处理半截内容。Agent 模式才是"自动重试"真正值钱的地方。

---

## v0.1.16：让手机上的 AI 真的会用你 vault 里的 SOP

用户问"手机上用 WorkBuddy 写笔记，还是用 App 内 AI"，顺着这个问下去发现一件
更要紧的事：**他 vault 里 100 篇笔记中有 54 篇是 `type: Skill`**（`仓颉拆书 SOP`、
`价值心法-*`、`Skill 模板：日报周报生成`…），这些随 Git 同步、手机上一直都有，
但手机 App 的 AI 从没读过它们——系统提示 7 条规则里，一句"先找 SOP"都没有。
所以它写文案时用的是自己的通用语感，用户"没感觉到"那些方法论在起作用。

**这不是同步问题，是没指路。**

### 改动

1. `vault_tools.dart`：`list_notes` 新增 `type` 参数，按 frontmatter 的 `type`
   精确过滤（大小写不敏感，回显保留原样）。模型现在能一次拿到全部 SOP 标题，
   而不是靠 `search_notes` 全文搜索碰运气（那个还有 60 条上限）。
2. `agent_runner.dart` 系统提示新增第 6 条：

   > 用户要写文案、脚本、选题、拆书、做计划、复盘这类「有方法论的活」时，先调
   > list_notes(type: "Skill") 看知识库里有哪些现成 SOP，挑一篇最相关的 read_note
   > 读完，再按它的步骤做。实在没有相关的 SOP 才用通用方法，并在回答开头说明
   > 「这次没找到对应 SOP，按通用方法做」。不要凭印象编一套流程。

   最后一句是重点：**允许退化成通用方法，但必须说出来**，不能让用户以为在用
   自己的 SOP。

### 验证

- 拿**真实 vault**（`E:/文档/vault`，100 篇）跑了一次探针：
  `list_notes(type: "Skill")` → `共 100 篇，显示 54 篇（分类 Skill）`，头几条正是
  `价值心法-能力圈.md`、`价值心法-第二技能.md`、`价值心法-第一性原理.md`。
  探针是临时文件，跑完即删（不把用户路径写进测试）。
- 新增 2 例测试：`list_notes` 的 type 过滤（含大小写、与 glob 的与关系、无匹配
  的提示）＋ 系统提示必须含 `list_notes(type: "Skill")`、`read_note`、
  `没找到对应 SOP`。
- `flutter analyze`：No issues found；`flutter test --concurrency=1`：**160/160**。

> 关于"用 WorkBuddy 手机版写笔记"：那条路在手机上走不通。Tolaria 的 vault 在
> `/data/user/0/com.tolaria.tolaria_android/app_flutter/`——app 私有目录，Android
> 分区存储对其它 app 完全封闭，而 App 也没有自选目录的入口。WorkBuddy 手机版
> 只能生成文字，搬运还得靠人。**真正能在手机上写库的只有 Tolaria 自己的 AI**，
> 所以把 SOP 接给它，比自己搬运一圈更划算。

---

## v0.1.15：AI 输入区只留文字，附件加号撤掉

v0.1.14 按「AI 助手不能传附件」加了个 ⊕（图片 / 文件 / 语音）。用户用过之后
的判断更准确：**"我想了想主要就是文字编辑"** —— 这个 App 的模型是纯文本的，
附件最后能做的只是把路径引用塞进 prompt，多一个按钮、多一层弹窗，换来的是
输入区变窄和一条走不到底的流程。撤掉。

**改动**：composer 去掉 ⊕ 与附件 chips 行，`Row` 直接是「输入框 + 发送」；
删掉 `_pickAttachment` / `_composeMessage` / `_storeAttachment` /
`_removeAttachment` 与 `models/chat_attachment.dart`；`file_picker` 依赖一并移除
（连带走了 `cross_file`、`flutter_plugin_android_lifecycle`）。

`android/build.gradle.kts` 里那段「强制所有 Android 模块 compileSdk = 36」的反射
兜底**留着**——它当初是为 file_picker 写死的 compileSdk 34 加的，但下一个插件
pin 老版本时会再撞同一个墙，注释里写清了来由。

**回归测试**：`ai_chat_screen_test.dart` 新增一例钉死"输入区没有附件入口"——
断言 `add_circle_outline_rounded` 图标与「添加附件」tooltip 都不存在、只有一个
TextField、空内容点发送不产生空回合。

> 语音输入若以后要做，正确位置是**输入法自己**（系统键盘就有），不是 App 里
> 再加一个上传按钮。

---

## v0.1.14：装机反馈的 8 个问题（1 个协议 bug + 1 个 edge-to-edge 布局 + 1 个永不消失的 SnackBar + 凭据持久化 + 附件 + 分类规则）

用户在真机上用了一夜，提了 8 个问题。根因互不相同，逐个说。

### 1. 模型调 5 个工具只执行 4 个，然后卡死 + 400 报错（P0）

`AgentRunner` 把 assistant 消息里的 tool_calls **原样全部**带回历史，却只
`take(maxToolCallsPerStep)` 执行前 4 个、只补 4 条 tool 结果——第 5 个
`tool_call_id` 没有对应的 tool 消息，下一轮请求违反 OpenAI 协议，DeepSeek
直接 400 `insufficient tool messages following tool_calls message`，循环中断。
用户视角：4 张绿卡之后什么都不发生。

**修法**：超限的调用补一条合成 tool 结果（"超过单步上限，这个调用被跳过了，
需要的话下一步重新发起"）。协议完整性由新测试钉死：二轮请求里每个
tool_call_id 恰好对应一条 tool 消息，不许多也不许少。

### 2. 键盘弹出挡住输入框（edge-to-edge）

`Scaffold` 把 `bottomNavigationBar` 定位在 `size.height - bottomWidgetsHeight`
——**不含键盘 inset**（scaffold.dart 源码级确认），它依赖窗口自己收缩
（adjustResize）。targetSdk 36 在 Android 15+ 强制 edge-to-edge，窗口不再收缩，
于是 body 缩了、composer 留在全屏底部被键盘盖住。MuMu 是 Android 12，
本地怎么测都复现不了——真机才行。

**修法**：`bottomNavigationBar` 包一层 `Padding(bottom: viewInsets.bottom)`。
老 Android 上窗口收缩时该 inset 已是 0，布局零变化；body 底部取
`max(键盘, bottomWidgets)` 而非两者之和，不会二次收缩。

### 3. 「撤销」提示永远不消失

截图证据：05:19 在 AI 页挂着，回到列表后仍在——**6 分钟都不消失**。

**根因**（框架既定行为，不是 bug）：`snack_bar.dart:303`
```dart
persist = persist ?? action != null;   // 带按钮 → 默认 persist = true
```
`scaffold.dart` 的 4 秒超时回调第一行就是 `if (snackBar.persist) return;`——
带 action 的 SnackBar 按 Material 规范**故意**驻留，等用户点按钮或关闭图标。
我们的撤销提示恰好带「撤销」按钮，于是那个 4 秒定时器被静默跳过。
文档原文："If not provided, but the snackbar action is not null, the snackbar
will persist as well."

**修法**：`note_actions.dart` 抽出 `undoSnackBar({message, onUndo})`，显式
`persist: false`（两处调用：归档撤销 / 分类撤销）。带 action 仍会自动消失。
跨页那条另由 `routeObserver` + `SnackbarDismissOnNavigate` 兜底：列表页一被
push 就收起，不必等超时；阅读页用屏幕级 ScaffoldMessenger。

### 4. 用户名 / Token 重启后要重输 + 远程配置页要能折叠

凭据此前**故意**只存内存（README 的已知限制里写了"要持久化请换
flutter_secure_storage"）。用户明确要求保存，遂落实：
新增 `CredentialsStore`（flutter_secure_storage → Android Keystore），
设置页保存即写、启动即读（`VaultNotifier._restore()` 里加载，冷启动就能同步）。
远程与分支/提交身份/凭据三段包进 `ExpansionTile`：配好了默认收起，
点标题展开改。

### 5. AI 助手不能传附件

`file_picker`（图片/音频/任意文件）。**行为边界**（DeepSeek 等是纯文本模型）：
- 文本类文件（md/txt/csv/json/代码…，≤200KB）→ 内容内联进 prompt，模型真能读；
- 图片/音频/其他 → 复制进 vault 的 `attachments/ai-chat/<日期>/`，消息里附
  markdown 引用（回答被存成笔记时图能跟着走）；
- >20MB 跳过并提示。

### 6. 魔法棒建的笔记没有分类

`create_note` 一直支持 `type` 参数，`describeVault` 也把分类列表给了模型，
但系统提示没有**强制**。新增规则："新建笔记时必须传 type，从分类列表选；
没有合适的先读 `Type.md` / `分类总览.md` 看规范。绝不能建没有分类的笔记。"
（测试断言系统提示里必须有这条。）

> **关于"规则同步"的确认**：AI 设置（含输出格式模板）存在 **App 自己的
  prefs 里，不随 git 同步**——电脑桌面版上设的规则手机看不到，手机上要在
  「AI 助手 → 齿轮 → 输出格式模板」单独配。而"笔记必须有分类"这类**知识库
  自身规范**在 vault 的 `Type.md` / `分类总览.md` 里，是随 git 同步的——
  Agent 现在被要求去读它。

### 7. 跑起来没有"工作中"提示

两轮工具之间等模型 HTTP 响应可以沉默 30 秒以上，屏幕上没有任何东西在动，
和卡死无法区分。新增：时间线底部「正在思考…」呼吸卡片（工具执行中由工具卡
自己的转圈表达，不重复）+ AppBar 底部 2px 不确定进度条。

### 改动文件

- `lib/services/agent/agent_runner.dart`：超限调用补合成 tool 结果；系统提示
  新增 create_note 必须带 type 的规则
- `lib/screens/ai_chat_screen.dart`：composer 键盘 inset padding；附件按钮 +
  chips + `_composeMessage`/`_storeAttachment`；「正在思考」卡片接入
- `lib/providers/agent_provider.dart` / `lib/widgets/agent_view.dart`：
  新增 `AgentWorkingItem` 及其渲染
- `lib/route_observer.dart`（新）：RouteObserver + `SnackbarDismissOnNavigate`
- `lib/app.dart`：注册 navigatorObservers
- `lib/screens/note_list_screen.dart` / `note_view_screen.dart`：接入 mixin /
  屏幕级 ScaffoldMessenger
- `lib/widgets/note_actions.dart`：新增 `undoSnackBar()`，`persist: false`
- `lib/services/credentials_store.dart`（新）：Keystore 加密凭据
- `lib/providers/vault_provider.dart`：`_restore()` 加载已存凭据
- `lib/screens/settings_screen.dart`：凭据读存 + 远程配置 ExpansionTile
- `lib/models/chat_attachment.dart`（新）：附件分类（内联/引用边界）
- `pubspec.yaml`：`file_picker`、`flutter_secure_storage`；版本 0.1.14+15

### 验证

- `flutter analyze`：**No issues found**（顺带清了 2 条 prefer_const）
- `flutter test`：**163/163**（新增：超限调用协议完整性、系统提示含分类规则、
  附件分类 6 例、撤销提示 4 秒自动消失 3 例）
- 构建：release APK 73.7 MB（顺带修了 `~/.gradle/gradle.properties` 里已失效的
  63224 代理——它挡住了所有需要下载 artifact 的构建，含加新插件后的 release）
- **模拟器实测**（MuMu / Android 12）：
  - 撤销提示：出现后约 4 秒自动消失（之前 6 分钟不消失）✓
  - 附件入口：⊕ → 图片/文件/语音 弹窗 → 系统选择器正常拉起 ✓
  - 凭据：填 → 保存 → 冷启动后仍在 ✓
  - `flutter test` 里写 SnackBar 超时用例的坑：`pump(Duration)` 只推进假时钟
    并画**一帧**，而 `Ticker._tick` 的 `_startTime` 在帧外启动时不置位，那一帧
    动画进度为 0 → 必须 `pumpAndSettle()` 才能走完 250ms 退场动画。

> 诚实边界：键盘遮挡（Android 15 edge-to-edge）在 Android 12 模拟器上复现不了；
> 协议修复与撤销提示有测试钉死。AI 相关三项（工具循环、分类规则、工作中提示）
> 需要填好 API Key 才能在设备上端到端验证。

---

## v0.1.13：首次打开克隆知识库，表单消失、要重输一遍 —— 已修

用户反馈："第一次打开软件输入远程仓库和令牌后，页面会消失，还要重新输一遍"。
排查后确认这不是一个 bug，而是**三个缺陷叠在一次失败的克隆上**：

1. 克隆失败（示例中是 `file:///sdcard/...` 地址，App 无 `/sdcard` 读取权限，libgit2 以
   App 身份访问直接 EACCES）后，`vault_path` 从未落盘；
2. 用户在设置页填的一切（地址、分支、作者）只活在内存里，重启即蒸发；
3. 失败提示只靠 SnackBar 一闪而过，用户根本没看清为什么失败。

### 1. 草稿持久化（令牌除外）

设置页 5 个输入框（地址、分支、作者名、作者邮箱、用户名）每次改动即写入
`setup_draft_*` 系列 prefs，**重启后自动预填**。令牌框**故意不落盘**——
克隆成功即清草稿，失败或中断则保留，用户改完地址再点一次「克隆」就能继续，
不用从头重输。

### 2. 错误常驻，不再一闪而过

克隆失败时错误信息以错误色常驻在按钮上方，不依赖 SnackBar。看不到原因的失败
等于没告诉用户。

### 3. 中断克隆可恢复

克隆中途被杀（切后台、崩溃、杀进程）时，暂存目录 `.tolaria_vault_incoming`
会残留在 App 数据目录。下次启动若检测到它非空，主界面提示"检测到上次未完成
的克隆…重新填写并点「克隆」即可继续"。

### 改动文件

- `lib/services/settings_service.dart`：5 个 draft key + `saveSetupDraft` /
  `loadSetupDraft` / `clearSetupDraft`（无 token）
- `lib/providers/vault_provider.dart`：`_restore()` 检测残留暂存目录并提示；
  克隆/新建成功后清草稿
- `lib/screens/setup_screen.dart`：initState 预填、5 个 controller 挂 listener
  实时存草稿、错误常驻展示、说明文案更新

### 验证

- `flutter test --concurrency=1`：**152/152** 通过（新增 `setup_draft_test` 3 例 +
  `clone_path_probe_test` 探针：预创建空目录后 `g.Repository.clone` 落点验证）
- 模拟器装机：填测试仓库地址 + 假令牌 → 强杀重启 → 表单预填成功（地址/用户名在，
  令牌空）→ 点「克隆」→ 10 秒后进入主界面，测试仓库 3 篇笔记正常显示

> 诚实边界：`file://` 远程在 `/sdcard` 下失败是 Android SELinux 权限问题
> （App 读不了共享存储），不是本版能"修"的——设置页文案已提示用
> `https://` 或 App 数据目录内的路径。

---

## v0.1.12：Agent 两个崩溃/断片 bug

### 1. `fetch_url` 抓 GBK 老页面直接崩（FormatException）

截图报错 `FormatException: Missing extension byte`：`fetch_url` 用
`utf8.decode(body)` 硬解响应体，遇到 GBK 编码的中文老站（编码字节不符合 UTF-8
结构）直接抛异常，整个 Agent 轮次崩掉。改为流式收字节 +
`utf8.decode(bytes, allowMalformed: true)`：**不崩，但 GBK 内容可能乱码**
（Dart 无内置 GBK 解码器，"不崩"不等于"可读"）。

### 2. 撞 12 步上限后点「继续」，模型说没有上文

达到工具调用步数上限后用户点「继续」，新一轮不带任何历史，模型看到的是裸奔的
新 prompt，自然回答"我没有上文"。修复：Runner 每轮结束把 messages 历史
（`lastMessages`，工具结果截断到 2000 字）交回 Provider；用户发「继续 / 接着来 /
continue / go on / 下一步」等窄正则匹配的续跑指令时，下一轮携带该历史，
且不重复注入 system prompt。

### 改动文件

- `lib/services/agent/vault_tools.dart`：`fetch_url` 改字节流 + 容错解码
- `lib/services/agent/agent_runner.dart`：`run()` 加 `history` 参数；新增
  `lastMessages` / `_condenseForHistory`（2000 字截断）
- `lib/providers/agent_provider.dart`：`_lastHistory` 暂存；`_isContinueText`
  窄正则（≤12 字）判定续跑

### 验证

- `flutter test --concurrency=1`：agent_tools + agent_runner 相关 **42/42** 通过
  （新增：GBK 真字节 `HttpServer` 抓取用例、非 http 拒绝用例、续跑历史结构用例）
- 模拟器真机三级递进：撞上限 → 「继续」接上列新分类 → 再撞 → 再接上；
  GBK 页面、新浪 https 抓取中文可读

---

## v0.1.11：联网搜索支持博查（BoCha）平替

用户想用国产搜索 API 当 Tavily 的平替（国内直连、低延迟）。之前 `web_search` 只认 Tavily，
博查的 Key 没地方填。本版把搜索后端做成可切换：

### 1. AI 设置新增「搜索服务商」下拉

- **Tavily**（默认，海外）：填 Key 走 Tavily；不填则免 Key 走 DuckDuckGo 兜底（国内常被墙）。
- **博查 BoCha**（国产）：填博查 Key 走 `api.bochaai.com/v1/web-search`，`Authorization: Bearer` 鉴权，
  国内直连、延迟低。**博查必须填 Key，无 Key 时 `web_search` 直接提示去填**。

搜索 Key 框的 hint 与说明随服务商切换。

### 2. 解析逻辑健壮化

`_bochaSearch` 请求体用 `{query, freshness, summary, count}`；解析函数 `parseBocha` 抽成纯函数，
容错识别 `name/url/snippet` 与 `title/link/description` 两套字段名，截断到 300 字并标注"共找到 N 条，已截断"。

### 改动文件

- `lib/models/ai_config.dart`：新增 `SearchProvider` enum 与 `searchProvider` 字段（向后兼容，缺省 tavily）
- `lib/services/agent/vault_tools.dart`：`buildVaultTools` 加 `searchProvider`；`_webSearch` 分支；新增
  `_bochaSearch` / `parseBocha` / `_pick`
- `lib/services/agent/agent_runner.dart`：透传 `searchProvider`
- `lib/providers/agent_provider.dart`：传 `config.searchProvider`
- `lib/screens/ai_settings_screen.dart`：服务商下拉 + 动态 hint

### 验证

- `flutter analyze`：0 错误（仅 2 条 `Uri.parse` 的 prefer_const 风格提示，与既有 `_duckSearch` 同源）
- `flutter test --concurrency=1`（agent_tools + agent_runner）：40/40 通过
- 新增 `parseBocha` 单测：标准字段、截断 max、备用字段名、空结果四种情况全过
- 模拟器装机：设置页「搜索服务商」下拉正常渲染，切到博查后 Key 框提示变为"博查 BoCha API Key"

> 诚实边界：博查的**真机联网返回**未实测（需要真实博查 Key）；解析逻辑已用 mock 响应单测覆盖，
> HTTP 端点与鉴权方式按博查公开文档实现。

---

## v0.1.10：AI 魔法棒能主动联网 + 自定义输出格式

用户问"AI 魔法棒能不能联网搜索、并结合现有笔记按设置好的格式输出"。之前 Agent 模式有
`fetch_url`（读指定网页），但**不能主动搜索**，输出格式也只能靠每轮手写在问题里。本版补齐：

### 1. 主动联网搜索 —— 新增 `web_search` 工具（第 9 个 Agent 工具）

模型给关键词即可搜索，返回「标题 + 链接 + 摘要」列表，可引用到回答里。两条路径：

- **填了 Tavily Key**（设置里可选填）→ 走结构化搜索 API，稳定；
- **没填 Key** → 免 Key 抓 DuckDuckGo HTML 兜底，开箱即用（App 直连偶被拦，返回文案会提示去填 Tavily）。

与 `fetch_url` 互补：一个"抓你给的链接"，一个"主动搜关键词"。

### 2. 输出格式模板 —— 新增 AI 设置项

`AI 助手设置` 里新增「输出格式模板」多行输入框（如"用 Markdown 表格、分三点、每条带来源链接"），
这段文字自动拼进 Agent 的系统提示词，每次回答都尽量按格式来；留空则保持默认风格
（中文、短句、先给结论）。

### 改动文件

- `lib/models/ai_config.dart`：新增 `outputTemplate`、`searchApiKey`（向后兼容）
- `lib/services/agent/vault_tools.dart`：`web_search` 工具 + DuckDuckGo/Tavily 解析，加入 `agentToolNames`
- `lib/services/agent/agent_runner.dart`：透传两参数，system prompt 末尾拼接格式模板
- `lib/providers/agent_provider.dart`：把设置传给 Runner
- `lib/screens/ai_settings_screen.dart`：两个新输入框 + 保存逻辑

### 验证

- `flutter analyze`：0 问题
- `flutter test --concurrency=1`（agent_tools + agent_runner）：36/36 通过
- 工具清单断言改为随 `agentToolNames.length` 自动同步，不再硬编码 8

> 诚实边界：真模型端到端（含联网搜索）未在真机跑过 —— 之前 DeepSeek key 余额 0（402），
> 需要换有余额的 key（如智谱 glm-4-flash 有免费额度）才能验证联网搜索这一步。

---

## v0.1.9：拉取为什么慢，以及怎么修的

用户反馈："每次打开从远程仓库拉取都特别慢"。排查后确认慢的不是网络带宽，而是**每一次
拉取都在做一次完整的 pack 协商**，哪怕远端一个字节都没变：

1. TLS 握手 + `GET info/refs`；
2. `POST git-upload-pack`，body 里带上本地所有 ref 的 `have` 行；
3. 服务端回答"up to date"，什么都没给。

手机一天点好几次拉取，绝大部分都是白跑这一整圈。修法是把"问远程有没有变化"和
"下载变化"拆开：

### 快路径：一次 `ls` 代替整个协商

`_pull` 现在先 `Remote.ls()`（一次很小的请求，只拿远端各分支的 tip OID），与本地
`refs/remotes/origin/<branch>` 比对。**相等就整个跳过 fetch**，直接走本地合并分析。
ls 失败（没网、没凭据、服务器抽风）一律回退到完整 fetch —— 快路径只是加速，不允许
改变"拉取"的语义。反过来的保证由两个测试钉死：

- `refs/heads/main` 还在、objects 全删光，拉取依然成功返回 upToDate（证明真的没下载）；
- 远程整个消失时必须报错，不许假装"已是最新"。

### 只拉当前分支，不再拖全家

原来的 `fetch()` 不传 refspecs，用的是 remote 默认的 `+refs/heads/*` —— 桌面端历史
上建过的每个分支手机都要付一遍下载费。现在显式传
`+refs/heads/<branch>:refs/remotes/origin/<branch>`，其他分支的 remote-tracking ref
**不再被创建**（有测试断言）。顺手 `setAutotag(none)`：知识库按版本打 tag，全量跟随
是纯浪费。

### 结果对用户可见

`pull` 现在返回 `PullOutcome{status, commits, fetched}`，UI 区分三种结局：
"已是最新（0.3 秒）"、"已拉取 N 个新提交（1.2 秒）"、冲突提示。**耗时是刻意显示的**
——不显示的话，一个 0.3 秒的空拉取和一个静默做了事的拉取在用户眼里没有区别。
另外 upToDate 时**不再重读全部笔记**（磁盘没变，重读是纯开销）；upToDate 的判定由
worker 报告的 `fetched:false` 锁定，谁要是把快路径改坏，测试立刻红。

### 两个后端都对齐

`CliGitService`（桌面）同样返回 PullOutcome：pull 前后比对 HEAD，`rev-list --count`
算提交数，stderr 含 `CONFLICT` 时返回 conflict 而不是抛裸错误。

### 验证

- 新增 `test/pull_fast_path_test.dart` 9 个用例（全部离线，本地裸仓库）。
- 模拟器端到端：克隆 → 拉取（已是最新 3ms）→ 远端加提交 → 拉取（传输 12B pack、
  新笔记出现、列表即时刷新）→ 再拉（已是最新）。测试期间发现的一个坑记入 HANDOFF §12：
  `adb push` **不创建空目录**，裸仓库缺 `refs/heads/` 时 libgit2 报
  "could not find repository"，跟权限问题的报错一模一样。
