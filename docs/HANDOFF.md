# 交接说明（换窗口 / 换机器继续做这个任务看这里）

最后更新：2026-10-22 16:55 · 对应版本 **v0.1.22+23**（179/179 测试通过）

> **这份是公开发布版。** 本机维护的原件在项目上级目录，含本机精确路径；
> 这里把用户名替换成了 `you`、私有仓库地址替换成了占位符。
> 换机器按本文操作时，把 `you` 换回你自己的用户名即可。

---

## 0. 先回答一个常见误解

**只上传 `tolaria_android/README.md` 是不够的。**

README 记录的是**决策与结论**（为什么归档写 `_archived`、为什么在 Dart 里重写 Agent 而不是
搬桌面版那套、9/16 上限怎么把 padding 吃掉、130 个测试各测什么）。它**不含一行可编译的代码**，
也不含工具链路径、签名密钥、模拟器坐标这些"只在这台机器上才有"的东西。拿它续聊可以，接着改代码不行。

三种续接方式，按省事程度排：

| 场景 | 怎么做 | 够不够 |
|---|---|---|
| **同机、新开窗口**（推荐） | 工作目录开到 `C:\Users\you\WorkBuddy\2026-10-18-15-03-56`。AI 能直接读 `tolaria_android/lib/**`、跑 `flutter test`、adb 装机截图 | ✅ 完全够 |
| 换机器 / 换人 | 把整个项目目录打包发过去（含 `.tools/`），**再加** 本文件 + README.md | ✅ 够，但要重装工具链 |
| 只发 README.md | 只能继续**讨论**方案、写文档、查桌面版源码；不能改代码 | ⚠️ 只能聊 |

> 同一台机器上，README 本来就在项目里，**不需要上传**——直接说"接着 tolaria_android 做"就行。

---

## 1. 这个项目是什么

把桌面版知识库 [Tolaria](https://github.com/refactoringhq/tolaria) 移植到 Android。
桌面版是 Tauri（Rust + React），手机端**用 Flutter 重写**，MVP = 浏览 / 编辑 / Git 同步。
所有数据仍是纯 Markdown + YAML frontmatter + `views/*.yml`，**和桌面版同一个 vault，互相能读**。

能力边界（重要，别越界）：

- ✅ 有：读笔记、编辑、`[[wikilink]]` 跳转、Git 提交/推送/拉取、克隆（含私有库凭据）、
  侧边栏（视图 + 类型）、归档、分类、AI 问答（直连模型）、**AI Agent（9 个工具，能读改笔记）**
- ❌ 没有且**不会做**：把 Claude Code / Codex 这些 CLI 当子进程拉起来（安卓没有 Node、
  没有这些 CLI、起不了长驻子进程）。v0.1.8 的做法是**在 Dart 里重写同一套能力**：
  工具层 + 循环都在 App 内，边界比桌面版更窄（没有 `execute`，只能动 vault 里的 .md）
- ⏳ 没做：数据库视图、标签管理页、导出、本地搜索高亮、Agent 会话持久化

---

## 2. 目录结构

```
C:\Users\you\WorkBuddy\2026-10-18-15-03-56\
├─ tolaria_android\            ← Flutter 工程（源码在这）
│  ├─ lib\
│  │  ├─ models\               note.dart（含 isArchived/noteType 归一化）、note_filter.dart、ai_config.dart
│  │  ├─ services\             vault_service（读写 vault）、vault_index（侧边栏解析）、
│  │  │                        frontmatter_editor（**只改目标行**的 YAML 编辑器）、
│  │  │                        git2dart_service、ai_service（三种协议流式）、ai_context
│  │  │  └─ agent\             agent_tool（工具接口 + 护栏）、vault_tools（9 个工具）、
│  │  │                        agent_runner（循环：请求 → 跑工具 → 回填 → 再请求）
│  │  ├─ providers\            vault_provider、ai_provider（问答模式）、agent_provider（Agent 模式时间线）
│  │  ├─ screens\              note_list / note_view / note_editor / settings / ai_chat / ai_settings
│  │  └─ widgets\              note_markdown、color_dot、category_picker、note_actions、
│  │                           sheet_insets、agent_view（工具卡片 + 改动确认弹窗）
│  ├─ test\                    11 个测试文件，共 130 个用例
│  ├─ tool\build_apk.sh        一条命令 pub get → analyze → test → release
│  └─ README.md                **技术档案**：每个版本修了什么、为什么这么修
├─ .tools\                     ← 本机脚手架（不随 APK 发布）
│  ├─ flutter\                 Flutter SDK 3.47.7（本地解压，不走 PATH）
│  ├─ fl.sh                    跑 flutter 的包装脚本（绕过 flutter.bat 的重复 pub upgrade）
│  ├─ ad.sh                    adb 包装：`./ad.sh shot x.png` / `dump` / 自动等设备上线
│  ├─ pyenv\                   Python venv（Pillow，做图标用）
│  ├─ mock_ai.py               假 OpenAI 端点，端口 8090；流式回答 + **agent 分支**（tools 请求回脚本化 tool_calls）
│  ├─ make_icons.py            从桌面版 512 图标生成 adaptive + legacy 两套
│  └─ make_test_vault.py       造 300 篇测试笔记，压克隆性能
└─ Tolaria-0.1.x-release.apk   历次产物（0.1.0 → 0.1.7）
```

---

## 3. 环境（精确路径，别猜）

| 项 | 值 |
|---|---|
| Flutter | `3.47.7 stable`，本地 SDK 在 `.tools/flutter`，**用 `.tools/fl.sh` 调** |
| Dart | 随 Flutter 一起，`bin/cache/dart-sdk` |
| JDK | `C:\Users\you\AppData\Local\Programs\jdk17\jdk-17.0.20.1+1` |
| Android SDK | `C:\Users\you\AppData\Local\Android\Sdk`（platform-tools 里有 adb） |
| 模拟器 | MuMu，`emulator-5554`，Android 12 / API 32 / x86_64，1080×1920 @ 480dpi |
| 镜像（必须） | `PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` |
| 签名 | **release 也用 debug key**（`~/.android/debug.keystore`）。换机器想覆盖安装，这个文件必须一起带，否则装不上 |

---

## 4. 三条命令

```bash
cd C:/Users/you/WorkBuddy/2026-10-18-15-03-56/tolaria_android

# 1) 静态检查 + 测试（**必须**去掉代理，否则所有用例一起挂 WebSocket 报错）
../.tools/fl.sh analyze
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost ../.tools/fl.sh test

# 2) 构建（约 70–90 秒）
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY ../.tools/fl.sh build apk --release
cp build/app/outputs/flutter-apk/app-release.apk ../Tolaria-0.1.8-release.apk

# 3) 装机 + 截图（install 也要走 ad.sh，直接调 adb 会偶尔 "device offline"）
cd ../.tools && ./ad.sh install -r ../Tolaria-0.1.8-release.apk
./ad.sh shell "monkey -p com.tolaria.tolaria_android -c android.intent.category.LAUNCHER 1"
mkdir -p shots && ./ad.sh shot shot.png
```

App 包名 **`com.tolaria.tolaria_android`**（不是 `com.tolaria.android`，历史上踩过这个坑）。

---

## 5. 模拟器操作备忘

- 截图是 **1080×1920 原始分辨率**；我看到的预览图被缩到 608 宽，**目测坐标要 ×1.777**
- 长按 = `input swipe x y x y 900`（`input tap` 长按无效）
- 拿精确坐标不要靠眼睛：`./ad.sh shell "uiautomator dump /sdcard/ui.xml"` 再 `cat` 出来读 `bounds`
- release 包 **`run-as` 不可用**，vault 在内部存储读不到文件，只能靠 UI 计数验证
- vault 落盘位置（debug 包可看）：`/data/data/com.tolaria.tolaria_android/app_flutter/tolaria_vault`
- adb 经常自己掉线（`device offline`）：`adb kill-server; adb start-server` + 轮询 `get-state`
- 假 AI 端点：`python .tools/mock_ai.py`，App 里 Base URL 填 `http://10.0.2.2:8090/v1`，Key 随便填

---

## 6. 已经踩平的坑（照抄结论，别重走）

| 坑 | 结论 |
|---|---|
| 克隆 300 篇卡死 ANR | 克隆必须跑在 isolate，主线程只收进度 |
| 克隆失败会删光本地 | 先 clone 到临时目录，成功才替换 |
| 分支写死 `main` | 用远端实际 HEAD 分支名 |
| 取消克隆 → 原生崩溃 | patch git2dart 的回调，取消时不再触碰已释放的对象 |
| 类型定义笔记 YAML 漏进正文 | `type: Type` 的文件，frontmatter 之后可能还有第二段 `---`，要跳过 |
| 长按菜单删除贴导航栏 | `SafeArea` 在 edge-to-edge 下读到的 `padding.bottom` 是 0；且 `showModalBottomSheet` 默认高度上限 9/16 会把多加的 padding **静默裁掉**。正解见 `widgets/sheet_insets.dart`：`max(padding, viewPadding, systemGestureInsets)` 取大者，兜底 32dp，并加 `isScrollControlled: true` |
| 分类面板只显示 3 条 | sheet 必须 `isScrollControlled: true`，否则被 9/16 卡住 |
| 改一个归档标记却重排整个 frontmatter | 禁用 `toMarkdown()` 全量重写，用 `FrontmatterEditor.upsert()` 只动目标行，保留 BOM/CRLF，实测可逐字节还原 |
| Dart `HttpClient` 发 chunked，网关读不到 body | `request.contentLength = payload.length` 显式给长度 |
| 设置页把本地 Ollama 误判成「未配置」 | 判定用 `config.isUsable`（本地端点不需要 Key），不要用 `apiKey.isEmpty` |
| 测试全挂，报 `Invalid WebSocket upgrade request` | 本机装着代理，跑测试前去掉 `http_proxy/https_proxy`，并设 `NO_PROXY=127.0.0.1,localhost` |
| 测试并发参数随测试数量漂移 | 测试少时默认并发没事；到 139 个后 `--concurrency=2` 起 isolate 的 git 测试会随机 "did not complete"。**现在用 `--concurrency=1`（139/139，约 30 秒）**，先单独跑失败文件确认不是测试本身的问题再动代码 |

---

## 7. 版本历史（一行一版）

| 版本 | 内容 |
|---|---|
| 0.1.0 | MVP：打开 / 克隆 vault、列表、阅读、编辑 |
| 0.1.1 | 修克隆 ANR、克隆失败删库、分支写死 |
| 0.1.2 | 修克隆进度条卡在 6% |
| 0.1.3 / 0.1.4 | 修取消克隆崩溃、标题点开侧边栏、修 frontmatter 解析漏 YAML |
| 0.1.5 | 桌面版图标 + AI Chat（11 个预设、三协议流式、上下文拼装、存为笔记） |
| 0.1.6 | 长按菜单补「归档」「分类」，frontmatter 原地编辑 |
| 0.1.7 | 长按菜单 / 分类面板与导航栏之间留 32dp 死区 |
| 0.1.8 | **Agent 模式**：8 个知识库工具（无 shell）、App 内 agent 循环、写前 diff 确认、工具卡片时间线；Chat/Agent 一键切换 |
| 0.1.9 | 拉取快路径：`Remote.ls()` 一次轻请求代替完整 pack 协商；只拉当前分支；返回 `PullOutcome` 让用户看到耗时 |
| 0.1.10 | `web_search` 工具（Tavily / DuckDuckGo 兜底）+ AI 设置「输出格式模板」 |
| 0.1.11 | 搜索服务商可切换：新增博查（BoCha）国产平替，`parseBocha` 容错两套字段名 |
| 0.1.12 | 修 `fetch_url` GBK 页面 `FormatException`；修 12 步上限后「继续」无上文（history 续跑机制） |
| 0.1.13 | 修首次克隆失败后「表单消失要重输」：草稿持久化（令牌不落盘）、错误常驻、中断克隆提示 |
| 0.1.14 | 装机反馈 8 项：工具调用协议截断（400 卡死）、键盘遮挡（edge-to-edge）、撤销提示永不消失（`SnackBar.persist` 默认 true）、凭据 Keystore 持久化 + 远程配置折叠、AI 附件、create_note 强制分类、工作中提示（呼吸卡片 + AppBar 进度条） |
| 0.1.15 | **撤掉 AI 输入区的附件加号**（用户：主要就是文字编辑）。composer 回归「输入框 + 发送」，删 `chat_attachment` 模型与 `file_picker` 依赖（连带 cross_file / flutter_plugin_android_lifecycle），补「输入区无附件入口」回归测试 |
| 0.1.16 | **让手机上的 Agent 会用 vault 里的 SOP**：`list_notes` 新增 `type` 过滤（真实 vault 验到 54 篇 `type: Skill`）；系统提示加第 6 条「写文案/选题/拆书/复盘这类有方法论的活，先 `list_notes(type:"Skill")` 找 SOP 读完再做，没有才用通用方法且必须声明」。根因：vault 里 54 篇 SOP 一直没被读过，不是同步问题而是没指路 |
| 0.1.17 | **429 限流自动重试**：`_chat` 拆成 `_chatOnce` + 退避包装，只重试 429/5xx（400/401/402/403/404 不重试），默认 1s→2s，认 `Retry-After`（只认秒数、上限 15s）；重试期间通过 `onNotice` 回调把「限流…自动重试（第 N/2 次）」推进界面（事件流此刻停在 await 里，yield 不出去）。安全前提：工具结果已在上一步写入 messages，重发不会重复执行写操作 |
| 0.1.18 | **read_note 报错时回推候选路径**：模型为扁平 vault 编了 `Skill1/短视频带货脚本 SOP.md`，报「找不到」后又拿同一个错路径重试两次。现在 `_notFoundMessage()` 按文件名/标题两级匹配（短于 4 字符不参与，避免"脚本"命中半库）把 1–3 个真实路径写进错误；系统提示第 2 条改为「原样相对路径、别加目录前缀、报找不到就改用候选或重新 list_notes、不许重试同一个错路径」 |
| 0.1.19 | **免费档限流**：智谱免费模型之间差十倍（`glm-4-flash` 连发 15/15 通过；`glm-4.7-flash` 第二个就 429），而 Agent 每步一次请求必然连发。429 文案改为带服务商原话并提示换宽松模型；撞过 429 后本轮进入**慢速模式**（后续每个请求间隔 `rateLimitGap` 默认 1.2s，界面告知），慢速模式每轮重置 |
| 0.1.20 | **AI 气泡滚出裸 JSON**：智谱免费档即使发 `stream: false`，也可能把 stringify 后的 SSE 分片（`{"index":0,"finish_reason":"tool_calls","delta":{…}}`）追加进 `message.content`。新增 `_visibleText()`：用 `{"index":N` 定位、`_matchingBrace()`（字符串感知，处理 `\\` 转义）找到配对的 `}`，且片段里必须含 `"delta"` 或 `"finish_reason"` 才剥——合法业务 JSON 不动。清洗同时作用于**气泡显示**与 `lastMessages`（只清一处等于把坏样本回灌给下一轮）。新增 2 例测试（噪音剥净 / 合法 JSON 保留括号） |
| 0.1.21 | **连续对话记不住上一句**：根因不是模型，是两处代码缺陷——① `history: _isContinueText(text) ? _lastHistory : null` 让历史只在整句是「继续」时才带，正常追问「那第二点呢」传 `null`，模型收到全新上下文；② `run()` 在 `rawCalls.isEmpty` 分支直接 return，**助手的回答根本没进 transcript**。改为每轮都带历史、删掉「继续」特殊路径、按轮裁剪（24000 字 / 最近 12 轮，切点只落 user 轮边界，否则 `tool_calls` 缺配对 400）、换笔记才重述正文（`_contextSignature = path\|body.length`，走 user 轮不走第二条 system）。新增 `services/ai_session_store.dart` 落盘会话（agent/chat 两个独立 key）。174/174 |
| 0.1.22 | **Agent 末轮流式**：推翻 v0.1.8「`tool_calls` 分片重组太容易静默出错所以不流式」的结论——要解决的是重组，不是绕开。① 按 `index` 累积（`id` 取到非空即覆盖、`name` 只在非空时**取一次**、`arguments` 只能字符串拼）；② 流过的文本不再补整段 `AgentText`（否则同一回答打印两遍，用 `streamed` 标记）；③ `_pumpVisible()` 在**发送前**拦 SSE 噪音（未闭合 `{` 先压着不发，认出 `{"index": N` 整段扣住，流结束再统一清洗补发），因为已显示的字收不回来。顺带修真 bug：改 `StreamController` 后 `onCancel` 在**正常结束**时也触发，把 `_cancelled` 永久置真，同一 runner 第二轮一个请求都不发——用 `finished` 标志区分「用户停止」与「本轮跑完」。网关忽略 `stream:true` 时降级整段解析。179/179 |

---

## 8. 下一步待办（按价值排序）

1. **真机端到端 Git**：用户的私有库 `gitee.com/<your-account>/tolaria` 还没跑过完整「克隆 → 改 → 提交 → 推送」。
   需要私人访问令牌，目前只用模拟器里的本地裸库验证过。
2. **用一个真模型跑一次 Agent**：链路已用 `.tools/mock_ai.py` 的 `tools` 分支验证过（脚本化
   `tool_calls`），但真实模型的工具调用习惯、`old_string` 是否够唯一、多步规划质量都还没验。
   用户的 DeepSeek Key 余额为 0（402），需要充值或换智谱 `glm-4-flash`（有免费额度）。
3. **⚠️ v0.1.23 半成品，在代码里躺着**：`AgentWritePolicy`（ask / session / always）
   与 `lib/services/agent/project_instructions.dart`（读 vault 根的 `AGENTS.md` /
   `CLAUDE.md` / `GEMINI.md`，6000 字上限，兼容小写文件名）都写完了，但**没有任何调用点**——
   UI 没入口、`agent_runner` 没读它。`ai_config.dart` 的字段声明原本缺失导致编译失败，
   2026-10-22 16:50 已补齐字段 / `copyWith` / `toMap` / `fromMap`（`orElse` 兜底 `ask`），
   现在能编译、179 例全过，但**功能本身没接上**。接着做的话：设置页加策略选择器 →
   `agent_provider` 的 approver 按策略短路（`always` 不弹窗但仍出工具卡）→
   `agent_runner` 系统提示里拼项目指令（标注来源文件名，截断时说明）。
4. **会话持久化的收尾**：v0.1.21 已落盘（`ai_session_store.dart`），但还没有「翻旧会话 / 新建会话」
   的入口，等于只能恢复最后一次。桌面版能翻历史会话列表。
5. 桌面端视图颜色用命名色（`blue`/`amber`），手机端新建分类写的是 hex，桌面端会退化成漏斗图标。
   要对齐得内置一张命名色 → hex 的映射表。
6. 本地搜索、标签管理页、数据库视图（桌面版有，手机端没搬）。

---

## 9. 判断"能不能接着做"的最简标准

- 要**改代码 / 打包 / 装机** → 必须有整个项目目录（含 `.tools/`）+ 本文件
- 只需要**讨论 / 写文档 / 查资料** → `README.md` 一份就够
- 只想知道**做到哪了** → 看 README 开头的状态表（版本、测试数、APK 体积、实测项）

---

## 10. 开发环境被删了怎么重建（2026-10-21 实际走过一遍）

**先说哪些通常没被删**：`~/.android/debug.keystore`（签名，丢了新包无法覆盖安装）、
`%LOCALAPPDATA%\Android\Sdk`、JDK17、`%LOCALAPPDATA%\Pub\Cache`（910MB，留着省很多时间）。
这四样还在，重建只要两步。

### 第一步：取回源码

资料库「Tolaria Android 备份」→ `Tolaria-Android-源码备份-v0.1.7.zip`（21MB）。
zip 内根目录是 `tolaria-android-backup-v0.1.7/`，按这个映射放回去：

| zip 内路径 | 放到 |
|---|---|
| `tolaria_android/**` | 项目根 `./tolaria_android/` |
| `HANDOFF.md` | 项目根 |
| `tools/**` | `./.tools/` |
| `vault/gitrepo/**` | `./.tools/gitrepo/` |

### 第二步：装 Flutter SDK

镜像直连可用（1.93GB，实测约 2 分钟）：

```
https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.7-stable.zip
```

zip 里顶层目录就是 `flutter/`，解压到 `.tools/` 即可，解压后确认
`.tools/flutter/bin/flutter.bat` 存在。`.tools/fl.sh` 把 `FLUTTER_ROOT` 写死指向
`.tools/flutter`，不依赖 PATH。

### 第三步：验证（三条命令都要过）

```bash
cd tolaria_android
../.tools/fl.sh pub get
../.tools/fl.sh analyze    # 期望 No issues found
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY ../.tools/fl.sh test   # 期望 80/80
```

### 坑：Gradle 会连不上（大概率会踩）

`~/.gradle/gradle.properties` 里写死了**本机出口代理的端口**。这个端口**每次会话都可能变**，
变了之后构建直接报 `java.net.ConnectException: Connection refused`，而且报错只发生在
Gradle 阶段，看不出是代理问题。

修法：把文件里的 `proxyPort` 改成当前 `$https_proxy` 的端口：

```bash
sed -i "s/proxyPort=[0-9]*/proxyPort=$(echo $https_proxy | sed 's|http://127.0.0.1:||')/g" ~/.gradle/gradle.properties
```

首次构建（`~/.gradle` 被清过）还要重下 **Gradle 9.3.1**（约 200MB）+ AGP/Kotlin 依赖，
5–10 分钟属正常；之后回到 70–90 秒。

### 构建命令（必须显式给 JDK）

```bash
cd tolaria_android
JAVA_HOME="C:/Users/you/AppData/Local/Programs/jdk17/jdk-17.0.20.1+1" \
ANDROID_HOME="C:/Users/you/AppData/Local/Android/Sdk" \
../.tools/fl.sh build apk --release
```

### 重建后逐项核对

- [ ] `fl.sh --version` → **3.47.7 / Dart 3.13.5**
- [ ] `tolaria_android/android/local.properties` 的 `flutter.sdk` 指向 `.tools\flutter`
- [ ] `~/.gradle/gradle.properties` 的 proxyPort 等于当前 `$https_proxy` 端口
- [ ] `~/.android/debug.keystore` 在
- [ ] `.tools/gitrepo/vault-user.git` 在（41 篇笔记的本地历史）
---

## 11. Agent 模式：改哪里、别破坏什么（v0.1.8 起，v0.1.22 已同步为流式）

### 文件分工

| 文件 | 职责 | 改动前先想清楚 |
|---|---|---|
| `lib/services/agent/agent_tool.dart` | 工具接口、参数取值、`guardToolCall` 把异常翻成模型能读的文字 | 别在这里加"允许任意路径"的口子 |
| `lib/services/agent/vault_tools.dart` | 9 个工具的实现 + `_safeRelative` 路径护栏 | 写工具必须标 `writes: true`，否则不会弹确认 |
| `lib/services/agent/agent_runner.dart` | 循环、`tool_calls` 按 `index` 重组、SSE 噪音拦截、状态码中文化、`cancel`、历史裁剪 | 请求体里 `stream:true` 是刻意的，见约束 5 |
| `lib/services/ai_session_store.dart` | Agent / 问答两条会话的落盘与恢复（两个独立 key） | 写盘全程 try/catch，存储不可用不能让面板答不了话 |
| `lib/providers/agent_provider.dart` | 事件 → 时间线；`approve` 回调；写完重载列表 | `approve == null` 时必须**拒绝**写 |
| `lib/widgets/agent_view.dart` | 工具卡片、`showToolApproval`、`AgentTimeline` | 失败卡片自动展开，别改回折叠 |
| `lib/screens/ai_chat_screen.dart` | Chat / Agent 两档切换（AppBar chip） | 两个 provider 各自独立，清空要一起清 |

### 五条不能松的约束

1. **没有 shell**。9 个工具之外不认任何工具名，未知工具转成文字告诉模型。`execute` 是桌面版
   有、这里故意没有的。
2. **写操作默认拒绝**。`AgentRunner` 只在 `approve != null` 时才问；provider 里 `approve` 为
   空时直接回 false。
3. **路径必须落在 vault 内**。`_safeRelative()` 是唯一入口，别在工具里直接拼路径。
4. **`edit_note` 必须唯一命中**，0 次/多次都报错让模型改写法，不许猜。
5. **流式可以开，但 `tool_calls` 必须按 `index` 重组**（v0.1.22 起）。三个不准动的地方：
   `id` 取到非空值就覆盖、`name` **只在非空时取一次**（拼接会得到 `list_noteslist_notes`）、
   `arguments` **只能字符串拼**（分片会把 JSON 切在引号中间）。另外流过的文本不能再补一个整段
   `AgentText`，SSE 噪音必须在**发送前**用 `_pumpVisible()` 压住（已经上屏的字收不回来）。

### 怎么在没有真 Key 的情况下验证

```bash
# 1) 起假端点（必须用后台任务，用 nohup & 会被回收）
python -u .tools/mock_ai.py --port 8090 --delay 0.01
# 2) App 里 AI 设置：Base URL = http://10.0.2.2:8090/v1，模型 = mock-tolaria-1，Key 可空
#    （10.0.2.2 已算本地端点，不需要 Key）
# 3) 先点「检测连接」确认能拿到 3 个模型，再发一句话
```

脚本行为：第 1 轮 `list_notes` → 第 2 轮 `append_note`（会弹确认框）→ 第 3 轮出正文。
问题里含「新建」时改调 `create_note`。注意 `adb shell input text` **打不了中文**，用英文提问。

### 模拟器坐标换算（1080×1920，预览图 608 宽）

`真实 = 预览 × 1.777`。常点位置：设置齿轮 `(1009,151)`、模式 chip `(663,151)`、
发送键 `(986,1765)`、AI 悬浮球 `(966,1524)`。**改完设置页文案后布局会整体下移**，
Base URL 输入框可能从 y≈1199 变到 y≈1294 —— 先截图确认再点。

---

## 12. 拉取优化（v0.1.9）：改哪里、别破坏什么

### 改了什么

`git_worker.dart` 的 `_pull`：先 `Remote.ls()` 比对远程 tip 与本地 remote-tracking ref，
相等就跳过整个 fetch；fetch 时限定单分支 refspec + `setAutotag(none)`。
`GitService.pull` 返回 `PullOutcome{status, commits, fetched}`，两个后端都已实现。
`vault_provider.pullNow` 按结果显示"已是最新（耗时）/已拉取 N 个新提交/冲突"，
**upToDate 时不重读笔记列表**。

### 三条不能破坏的语义

1. **快路径失败必须回退 fetch，不许报错** —— `_remoteTipMatchesHead` 里任何异常都
   返回 false。把"加速"变成"新的失败模式"是最大的倒退。
2. **"已是最新"不许撒谎** —— 测试用"远程目录还在、objects 全删光仍能拉取成功"和
   "远程整个消失必须报错"两端钉死；worker 返回的 `fetched:false` 是契约的一部分。
3. **拉取结果必须告诉用户发生了什么** —— 别把 message 合并回一个"拉取完成"。

### 模拟器端到端怎么搭测试远程（无真机仓库也能跑）

1. 宿主机建裸仓库：`git init work && git commit` → `git clone --bare work vault.git`。
2. `adb root`（MuMu 可用）→ `adb push vault.git /data/local/tmp/`。
3. root shell：`cp -r /data/local/tmp/remote.git /data/data/com.tolaria.tolaria_android/app_flutter/`，
   然后 **三步不能少**：`mkdir -p .../refs/heads .../refs/tags`（`adb push` 不建空目录，
   缺了 libgit2 报 "could not find repository"，和权限错误长得一模一样）、
   `chown -R u0_a41:u0_a41`（uid 用 `stat` 看 vault 现有 owner）、`restorecon -R`。
4. App 克隆 URL 填 `file:///data/user/0/com.tolaria.tolaria_android/app_flutter/remote.git`。
5. 模拟远程更新：宿主机 push 后重新 push+同步那份裸仓库（记得同样补 refs/tags）。

模拟器踩坑：设置页按钮点击坐标 = 截图预览坐标 × 1.776（预览 608 宽 vs 真机 1080 宽）；
点错一次浪费的时间比多截一张图多得多。
