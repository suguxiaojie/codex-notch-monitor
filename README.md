<div align="center">

# Codex Notch Monitor

**在 Mac 顶部实时掌握 Codex 额度、成本与多项目运行状态**

[![Download v1.1.2](https://img.shields.io/badge/Download-v1.1.2-27C2FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/suguxiaojie/codex-notch-monitor/releases/latest)
[![CoverAI](https://img.shields.io/badge/Built%20by-CoverAI-111827?style=for-the-badge&labelColor=111827&color=0EA5E9)](https://coverai.store/?utm_source=github&utm_medium=repository&utm_campaign=codex_notch_monitor_header)

由 [**CoverAI**](https://coverai.store/?utm_source=github&utm_medium=repository&utm_campaign=codex_notch_monitor_header) 打造<br>
发现实用的 AI 工具、订阅服务与中文使用指南。

[访问 CoverAI 官网 →](https://coverai.store/?utm_source=github&utm_medium=repository&utm_campaign=codex_notch_monitor_header)

</div>

---

一个原生 macOS 刘海/顶部胶囊应用，用于显示 Codex 剩余使用额度和本机任务状态。

当前 MVP 已实现：

- 通过官方 Codex App Server 的 `account/rateLimits/read` 读取真实额度。
- 显示多额度桶、剩余百分比、套餐类型和重置时间。
- 同一 Codex 额度桶的短周期与长周期窗口会独立显示：若 App Server 同时返回 5 小时和周限额，展开页分别显示两行；没有返回的窗口不制造空占位。收起态优先显示周期最短、最需要即时关注的窗口，且不依赖 `primary/secondary` 字段顺序。
- 通过 Codex lifecycle Hooks 接收开始、工具调用、等待批准、完成等状态。
- 只读监听最近活跃的多份 Codex 会话，通过结构化 `task_started` / `task_complete` 信号同时识别多个项目；同一路径的多个会话会聚合为一个项目，等待批准的项目优先成为收起栏焦点。
- 展开面板实时显示最近的进度播报与动作级工具记录；可区分正在/已完成的读取文件、搜索、修改文件、验证、图片检查和普通命令，收起栏显示最新短摘要。
- 展开页将“活跃项目”和“实时动作”分工显示：项目卡只保留项目名称、运行会话数与阶段状态，最新动作统一放在下方时间线；收起态悬停预览仍显示项目名与最新动作，便于不展开面板快速查看进度。
- Usage 页复用本地结构化会话日志的一次扫描，同时统计 `~/.codex/sessions/` 与 `~/.codex/archived_sessions/`，会话归档后当日／本周／本月的 Usage 和 Cost 不会减少；若迁移期间两处短暂存在同一会话，会按结构化 Token 事件去重。页面支持今日／本周／本月切换；分别显示 Token 总量、输入／输出／缓存拆分、会话与项目数量、按小时或按日的非累计折线趋势，以及根据真实 `session_meta.cwd` 聚合的项目排行。趋势使用青色折线、渐变面积和“统计截至当前”的末端光点，只绘制到当前小时／当前星期／今天，不会把未来空桶画成虚假的骤降；鼠标在折线区域移动时会吸附最近节点，以参考线、光点和气泡显示对应小时或日期的精确 Token；切换周期只使用内存快照，不会重新扫描磁盘。
- 项目目录在会话运行期间改名时，插件会用同一 `session_id` 的最新 Hook 路径覆盖历史 `session_meta.cwd`，因此改名前后的 Token 会合并到新项目名；顶部刷新按钮会同时刷新额度、运行状态与 Usage/Cost，而不再只刷新额度。
- Usage 项目排行以完整路径作为稳定统计主键，但显示名称优先读取 Codex 本地 `local-projects` 的侧栏别名；因此只在 Codex 左侧栏修改项目名（不修改磁盘文件夹）后，刷新即可同步为新名称。未设置侧栏别名时才回退到文件夹名称。
- 展开面板新增“会话”模块，为同一台 Mac 上的 Codex 项目与会话提供本地盘点：通过官方 App Server `account/read` 识别当前账号，只保存带随机盐的本机指纹、脱敏邮箱和本地观察到的会话归属；基线前的历史会话不会被猜测为当前账号。应用只监听 Codex 账号状态文件的修改时间、大小与文件编号，不读取文件内容；切换账号后会防抖约 0.8 秒并立即重新盘点，30 秒轮询只作为文件事件丢失时的兜底。
- “会话”模块会同时盘点活动与已归档 JSONL，并用 App Server 的仅状态库视图发现“本地文件仍在、当前列表缺失”的会话。恢复前强制要求完全退出 Codex／ChatGPT Desktop，自动备份 SQLite 状态库、会话索引和项目映射，再让官方 App Server 扫描 JSONL 并修复索引；原始会话 JSONL 不会被改写。
- 会话初始化采用文件头／文件尾有界解析：大文件最多读取 1.5 MiB，并按路径、大小和修改时间复用进程内解析缓存。账号确认、App Server 可见性查询和本地日志扫描并行执行；扫描中显示真实进度并保留上一次结果，不再把多 GB 历史日志完整载入内存。
- 会话行保留“复制摘要”，并新增单会话“导出”和项目级批量导出。系统保存面板可选择脱敏 Markdown、脱敏自包含 HTML，或原始 `.codexmonitorbundle` 可恢复备份；备份包使用 `codex-notch-session/v1` 清单、逐文件 SHA-256、活动／归档状态、项目路径和可靠观察到的账号别名，但不包含账号指纹、`auth.json`、Cookie 或 Token。原始 JSONL 可能含提示词、源码、终端输出、绝对路径和图片，只适合私下备份，不应公开分享。导出过程不会调用 `thread/start` 或 `turn/start`，不会创建新 Codex 会话，也不会消耗额度。“会话”页可重新导入该备份：写入前会校验包路径、符号链接、Manifest、JSONL 内部 ID／项目路径和 SHA-256；原项目缺失时要求手动映射新目录，同 ID 默认跳过，也可生成新 ID 作为副本。
- 展开面板新增“动态”模块，读取 Codex Runway 的公开 `https://www.codexrunway.com/api/status.json`，显示 `@thsottiaux` 与 Codex 额度相关的已完成重置、计划重置、额度提升等结构化消息。兼容 `resetTimeline` 扩展：人工确认的重置会置顶，已履行的计划作为证据合并展示，并按 `suppressedPostIds` 去重；旧版缺少时间线的 ETag 缓存会自动执行一次完整迁移请求。请求支持 ETag／Last-Modified、本地最后成功缓存、来源账号与规范 X 链接校验；网络或上游异常时保留旧数据并提示可能延迟，点击“在 X 查看”可打开原始内容。macOS 15 及以上版本可按条调用系统 Translation 框架翻译成简体中文，译文只在当前应用内存中缓存，不调用第三方翻译服务；旧版 macOS 继续显示原文和明确的兼容性提示。该数据源非 OpenAI 官方，也不是 Tibo 的完整推文时间线。
- 动态页同时监控额度从低位恢复至满额：窗口 `resetsAt` 可以确认自然到期重置，近期 Tibo 动态可以确认官方临时或计划重置；缺少证据的跳变会先进入待核验队列，避免首次启动、切换账号或接口抖动造成误报。确认后通过 macOS 系统通知显示具体额度窗口与前后百分比，并在本地保留最近记录；通知关闭时可从卡片直接跳转到 Codex Monitor 的系统通知设置。
- 收起栏顶部仅在摄像头左右安全翼显示项目数量/运行状态和额度，物理摄像头所在中段不再放置文字。摄像头下方使用自适应项目板：1 个项目单列、2 个项目左右双列、3 个项目采用“2＋1”、4 个项目采用“2×2”，超过 4 个时显示 3 个高优先级项目和一个 `+N` 汇总格。每格独立显示状态点、项目名与动作摘要，点击会展开并选中该项目；项目槽位在运行期间保持稳定。
- 收起栏采用 CodexIsland 风格的 `compact → peek` 交互：默认只显示菜单栏内的状态和额度，不向下遮挡当前应用；鼠标移入后才展开多项目动作板，离开整个区域 450ms 后自动收起，等待批准时保持可见。活跃状态点以约 2.4 秒周期呼吸，新活动到达时轻弹；运行期间有一条状态色角向渐变沿整个收起态轮廓约 3.6 秒环绕一周；项目悬停与按压提供短促反馈。展开使用较柔和的弹簧，收起更快，且所有动效均保持物理摄像头安全区不承载文字；空闲时停止逐帧动画。
- 默认待命态采用“隐形岛”设计：黑底直接与实体摄像头融合，不绘制横跨整条胶囊的静态描边或环境光。左翼使用 ChatGPT.app 自带的 Retina 菜单栏模板旋结替代普通状态点：待命时低亮度慢呼吸，运行时增强蓝光和闪烁节奏，等待批准时随状态切换为橙色；右翼是迷你环形额度表与百分比徽标。鼠标移入时两翼局部提亮，只有运行时才出现沿完整外轮廓移动的动态环绕光。
- 展开面板支持 `Usage / Cost / 动态` 点击、触控板双指横向滑动或 `Shift + 鼠标滚轮` 切换。窗口级 AppKit 监听会在内部 ScrollView 消费事件前累计手势；横向累计达到 30pt 且明显占优时立即切一页，不再依赖可能丢失的结束事件。一次物理手势有触发锁，惯性不会造成第二次切页；纵向事件仍原样进入内容滚动。Cost 仅读取 `~/.codex/sessions/` 的结构化模型、时间和 token 计数字段，估算今天与本月至今的 API 等价美元成本、输入/输出/缓存 token 和今日每小时趋势；暂不扫描 Claude 日志。
- 不读取推理内容、工具输出或项目文件内容；命令摘要会截断，并遮盖常见 Token、密钥和密码参数。
- 有刘海屏幕使用系统报告的左右辅助区域测量摄像头宽度，收起态内容分布在刘海左右双翼；展开态整体位于刘海下方。无刘海或外接显示器显示顶部浮动胶囊。
- 收起态高度跟随当前菜单栏高度；横向宽度会参考刘海几何和右侧实时菜单栏项目边界自动计算。中间留白按实体遮挡近似宽度计算，而不是 macOS 额外加宽的保守安全区；切换分辨率、显示器或菜单栏项目时会重新适配。
- 菜单栏重排、唤醒或切换分辨率时，macOS 偶发返回瞬时缺失的刘海／菜单项几何；应用会保留上一次可靠布局，拒绝异常坐标并限制收起态最大宽度，避免偶发拉成横跨菜单栏的黑条。
- 额度读取超过 12 秒会进入可恢复失败状态，并按 8 秒、20 秒、60 秒退避自动重试。若有上一次成功额度，会继续显示百分比并附加过期警告；首次启动无快照时显示 `--%` 而不是含义不明的单独感叹号。
- 收起态、点击展开态、菜单栏备用入口、手动刷新和退出。
- 展开后点击底部提示区，或点击桌面、其他应用、菜单栏等面板外区域，会自动收起；按钮点击不会误触发收起。
- 缩略栏与完整面板采用 CodexIsland 式固定宿主窗口：AppKit 窗口本身不再随展开改变尺寸，只在 `460×560` 的固定透明宿主内让黑色岛体形变；展开内容区为 `430×500`，常见的“1 个项目＋3 条动作＋2 个额度桶”默认完整显示，数据更多时仍可纵向滚动。详细面板一直预挂载，避免点击帧临时构建整个卡片树。展开时缩略内容先淡出，约 220ms 后详细内容以淡入、轻微下移和去模糊进入；收起顺序相反。透明宿主区域通过自定义命中测试和鼠标穿透，不会挡住下面应用。
- `Usage / Cost / 动态` 分段的三个视觉区域都是完整按钮，透明留白也参与命中测试；横向滑动仍可切换页面，但不再要求准确点中文字。
- `Usage / Cost / 动态`、刷新和电源按钮使用独立点击区域，不再继承面板的展开/收起手势；展开态只有底部提示区或面板外点击会收起。
- 展开页标题以可点击的 `BY COVERAI ↗` 标注产品归属，Usage 与 Cost 内容末尾提供一张轻量 CoverAI 官网入口卡，菜单栏备用入口也可直接访问官网；三个入口使用固定的 `https://coverai.store/` 域名与独立 UTM 活动参数，不会附带额度、项目名、日志或其他本机数据。套餐类型移到“剩余额度”标题行，避免与品牌归属信息混在一起。
- 纯 Swift Package 构建，不要求完整 Xcode，Command Line Tools 即可。

## 下载已构建版本

在 GitHub [Releases](https://github.com/suguxiaojie/codex-notch-monitor/releases) 下载对应版本的 DMG。从 `v1.1.0` 起，`universal` 安装包同时原生支持 Apple Silicon `arm64` 和 Intel `x86_64`；打开 DMG 后，将 `CodexNotchMonitor.app` 拖入 `Applications` 即可。已发布的 `v1.0.0` 仍是仅支持 Apple Silicon 的历史版本。

当前应用使用 ad-hoc 本地签名，尚未使用 Apple Developer ID 公证。macOS 第一次启动若拦截，可在“系统设置 → 隐私与安全性”中确认打开。安装后仍需按下文说明审核 Codex 用户级 Hook。

## 系统要求

- macOS 13 或更新版本。
- Apple Silicon 或 64 位 Intel Mac。
- Swift 6 / Xcode Command Line Tools。
- 已安装并登录 Codex 或 ChatGPT 桌面端。

## 快速运行

```bash
./scripts/test.sh
./scripts/build-app.sh
open build/CodexNotchMonitor.app
```

构建产物位于：

```text
build/CodexNotchMonitor.app
```

`build-app.sh` 默认按当前 Mac 的原生架构构建，适合本地开发。也可以显式生成单架构或 Universal 2 应用：

```bash
./scripts/build-app.sh arm64
./scripts/build-app.sh x86_64
./scripts/build-app.sh universal
```

Universal 构建会分别编译主程序与 Hook 的 `arm64`、`x86_64` 版本，再用 `lipo` 合并；合并完成后才进行应用签名。

生成可发布的 DMG：

```bash
./scripts/build-dmg.sh
```

DMG 脚本默认生成 Universal 2 版本，也可以传入 `arm64` 或 `x86_64`。脚本会重新执行 Release 构建、校验应用签名，并生成带 `Applications` 快捷方式的只读压缩镜像：

```text
build/CodexNotchMonitor-v<version>-<architecture>.dmg
```

在带刘海的 MacBook 上，收起态继续使用左右安全翼布局；在 Intel Mac 和无刘海外接显示器上，应用会自动切换为不预留摄像头空白的紧凑菜单栏胶囊。

## 安装到 Applications

```bash
./scripts/install-app.sh
```

默认安装当前 Mac 的原生架构开发版本；要安装与 Release 相同的双架构应用，可执行：

```bash
./scripts/install-app.sh universal
```

该命令会：

1. 构建并进行 ad-hoc 签名。
2. 如果 `/Applications/CodexNotchMonitor.app` 已存在，先备份到 `build/backups/`。
3. 安装新应用。
4. 以合并方式更新 `~/.codex/hooks.json`。
5. 如果原 Hooks 文件存在，先创建带时间戳的备份。
6. 启动应用。

安装 Hooks 后，在 Codex 中输入 `/hooks`，审核并信任新增的用户级 Hooks。Codex 会按 Hook 定义的哈希记录信任；应用升级导致 Helper 发生变化后，可能需要重新审核。

## Hook 状态映射

| Codex Hook | 显示状态 |
|---|---|
| `SessionStart` | 正在开始 |
| `UserPromptSubmit` | 正在开始 |
| `PreToolUse` | 正在执行工具 |
| `PostToolUse` | 正在思考 |
| `PermissionRequest` | 等待你的批准 |
| `SubagentStart` | 正在思考 |
| `SubagentStop` | 任务已完成 |
| `Stop` | 任务已完成 |
| `SessionEnd` | 会话已结束 |

所有 Relay Hooks 都以同步、2 秒超时模式运行，以兼容仍会跳过 `async: true` Hook 的 Codex 版本。Helper 不读取项目文件或执行网络请求，只向应用支持目录写入一个小型 JSON 事件后立即退出；即使 Helper 异常，单次同步等待也不会超过 2 秒。安装脚本会移除旧版监控 Hook 的异步定义，同时保留其他已有 Hooks。

## 本地数据和隐私

应用只处理：

- App Server 返回的额度窗口数据。
- Hook 提供的会话 ID、Turn ID、工作目录、模型、工具名称、事件名称和时间。
- `~/Library/Application Support/CodexNotchMonitor/events/` 下的临时事件文件。
- `~/.codex/sessions/` 最近 24 小时有写入的候选会话 JSONL 中的任务边界、工作目录、模型、commentary 进度文字，以及工具名称/命令短摘要。会话按实际修改时间跨日期目录发现，不以任务创建日期判断活跃性。
- “会话”页盘点 `~/.codex/sessions/` 与 `~/.codex/archived_sessions/` 的线程 ID、项目目录、Git 分支、修改时间和最近可读的用户／助手消息；消息正文只保存在当前应用内存中，仅用于用户主动复制交接摘要或生成导出文件，不写入插件状态文件。可读导出会流式扫描所选原始 JSONL 并脱敏；可恢复备份则逐字节复制所选 JSONL，因此需要按敏感本地记录保护。
- 会话连续性统计只包含有真实用户消息的主会话；Guardian／Subagent 内部线程和无用户消息的系统记录不计入“会话”或“待恢复”。插件首次建立账号基线前已存在的会话会标记为“基线前未记录”，不会猜测历史账号归属。
- App Server `account/read` 返回的账号类型、套餐与邮箱。邮箱只以脱敏形式显示；持久状态使用每台 Mac 独立随机盐生成的不可逆指纹，不保存登录 Token 或原始邮箱。
- 执行会话恢复时，`state_5.sqlite`、WAL/SHM、`session_index.jsonl` 和 `.codex-global-state.json` 的操作前备份。备份仅保存在 `~/Library/Application Support/CodexNotchMonitor/continuity-backups/`，带 SHA-256 校验清单，供面板回滚使用。
- 导入 `.codexmonitorbundle` 时，只有用户在预览后确认才会写入 `~/.codex/sessions/` 或 `~/.codex/archived_sessions/`。导入前备份索引和项目状态，并记录本次新建文件；面板可在 Codex 完全退出时撤销导入。导入不读取、复制或改写登录凭据。
- Cost 页扫描当月活动及已归档 Codex JSONL 中的 `turn_context.payload.model` 和 `event_msg.token_count.info.last_token_usage`，不读取提示词、回答或工具输出正文。
- Cost 模型价格来自 CodexIsland 的公开 HTTPS 目录。应用先使用本地缓存或内置价格立即计算，后台每 24 小时最多成功刷新一次；失败后至少等待 6 小时再重试。请求使用 ETag，目录未变化时不重复下载正文。

应用不会保存或显示：

- 用户提示词正文和助手消息正文不会被插件持久化或默认显示；只有用户点击“复制摘要”时，最近可读消息才会经过脱敏并写入本机剪贴板。
- 模型推理内容和加密推理数据。
- 工具输出或项目文件内容。
- Codex 认证 Token。
- 项目文件内容。

价格目录请求只下载公开 JSON，不附带 Codex 账号、会话日志、模型使用量或 token 数据。缓存保存在 `~/Library/Caches/com.coverai.codex-notch-monitor/model-prices.json`；网络失败、响应格式异常或目录为空时不会覆盖上一次有效缓存。

额度读取由独立的本机 `codex app-server --stdio` 子进程完成。应用不直接解析 `~/.codex/auth.json`，也不把数据发送到第三方服务。

## 卸载 Hooks

```bash
./scripts/uninstall-hooks.py
```

该脚本只移除命令路径中包含 `CodexNotchMonitor` 的 Handler，保留其他已有 Hooks。随后可以正常删除 `/Applications/CodexNotchMonitor.app`。

## 项目结构

```text
Sources/CodexNotchMonitor/
  App.swift                    应用生命周期和菜单栏入口
  AccountContinuity.swift      当前账号脱敏识别、本机指纹与观察式归属
  CodexAccountStateWatcher.swift 账号状态文件元数据监听与切换防抖
  CodexAppServerClient.swift   可复用的本机 App Server 协议客户端
  SessionContinuityService.swift 本地会话盘点、可见性和安全交接摘要
  SessionExportService.swift    会话 Markdown／HTML 渲染和校验备份包
  SessionImportService.swift    备份预检、路径映射、安全导入和事务回滚
  SessionRecoveryService.swift 恢复前备份、官方索引回填与回滚
  NotchWindowController.swift  顶部 NSPanel、多屏和展开动画
  NotchView.swift              收起/展开 SwiftUI 界面
  QuotaService.swift           Codex App Server JSON-RPC 客户端
  SessionActivityService.swift 本地会话活动和安全摘要读取
  PricingCatalog.swift        联网价格目录、ETag、缓存和失败回退
  ModelPricing.swift          模型规范化与 Codex 内置价格后备表
  CostService.swift           本地 token 日志与美元估值聚合
  MonitorStore.swift           额度、Hook 与会话活动状态汇总
  Models.swift                 额度及任务状态模型

Sources/CodexMonitorHook/
  main.swift                   极小的 Hook Relay Helper
```

## 已知边界

- 未信任 Hook 时仍可识别工作/空闲及实时进度；“等待批准”等精细阶段需要在 Codex 中信任 Hook。
- App Server 额度返回的是额度窗口使用比例，不是固定“剩余消息条数”。
- Cost 是按参考模型单价折算的 API 等价估值，不是 ChatGPT/Codex 订阅的真实账单；普通未知模型会列出并按 $0 处理。Codex 内部的 `codex-auto-review` 路由会按本地时间线上当时使用的主模型估算，并在界面中明确显示映射关系。
- 当前只显示最近 8 个本机会话状态，不读取远程 Cloud 任务详情。
- 账号归属采用“从启用后观察”的证据口径：首次盘点前已经存在的历史会话保持未知；离线期间创建并在下一次盘点前又切换账号的会话也不能可靠归属。应用不会为填满界面而猜测。
- 会话管理仅面向本地 JSONL 和本应用生成的 `codex-notch-session/v1` 备份。它不会迁移 `auth.json`、云端任务、审批状态、加密推理内容或模型内部缓存；复制的交接摘要由用户自行检查和决定是否粘贴到新会话。导入后会请求本机 App Server 重新发现，但 Codex 版本变化仍可能导致“JSONL 已写入、App Server 暂不可见”；界面会如实报告可见数，不把复制成功冒充恢复成功。
- 若 App Server 只返回 API Key 登录类型而没有稳定账号标识，一期无法可靠区分两把不同 Key，因此不会宣称已检测到切换；ChatGPT 登录会使用本机加盐后的邮箱指纹识别，原始邮箱不落盘。
- 应用目前使用 ad-hoc 签名，正式分发前应加入 Developer ID、Notarization 和 Sparkle 更新签名。

## 官方协议依据

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex Hooks](https://learn.chatgpt.com/docs/hooks)

## 参考与致谢

- Cost 页的数据口径、`last_token_usage` 处理、API 等价成本思路，以及导航栏的部分动效语言参考 MIT 项目 [ericjypark/codex-island](https://github.com/ericjypark/codex-island)。本项目当前只实现 Codex，本地不扫描 Claude 或 OpenCode；第三方许可见 `THIRD_PARTY_NOTICES.md`。
- 模型价格每日从 CodexIsland 公开目录刷新，并保留随应用发布的 Codex 后备表。由于模型名称和公开价格可能变化，未知模型不计价并在界面中明确列出。

## 许可证

项目暂未指定对外许可证。发布到 GitHub 或允许第三方复用前，请先确定 MIT、Apache-2.0 或其他许可证。
