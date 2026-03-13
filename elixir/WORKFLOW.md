---
tracker:
  active_states: ["Todo", "In Progress", "Merging", "Rework"]
  kind: "linear"
  project_slug: "workcow-3ded0ff156f2"
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
polling:
  interval_ms: 5000
workspace:
  root: "~/code/symphony-workspaces"
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  approval_policy: "never"
  command: "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high --model gpt-5.4 app-server"
  thread_sandbox: "danger-full-access"
  turn_sandbox_policy:
    type: "dangerFullAccess"
hooks:
  after_create: |
    git clone --depth 1 https://github.com/eddiearc/workcow .
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --frozen-lockfile
    elif command -v corepack >/dev/null 2>&1; then
      corepack pnpm install --frozen-lockfile
    else
      echo "pnpm/corepack not found in PATH" >&2
      exit 1
    fi
---
你正在处理 Linear 工单 `{{ issue.identifier }}`

{% if attempt %}
继续执行上下文：

- 这是第 #{{ attempt }} 次重试，因为该工单仍处于活跃状态。
- 请从当前 workspace 状态继续，而不是从头重新开始。
- 除非新的代码改动确有需要，不要重复已经完成的排查或验证。
- 只要工单仍处于活跃状态，就不要结束当前 turn；只有在缺少必要权限或密钥而真正受阻时才可以结束。
  {% endif %}

工单上下文：
标识：{{ issue.identifier }}
标题：{{ issue.title }}
当前状态：{{ issue.state }}
标签：{{ issue.labels }}
URL: {{ issue.url }}

描述：
{% if issue.description %}
{{ issue.description }}
{% else %}
未提供描述。
{% endif %}

执行要求：

1. 这是一次无人值守的编排会话。不要要求人工执行后续操作。
2. 只有在出现真正的阻塞时才可以提前停止（缺少必要认证、权限或密钥）。若受阻，请在 workpad 中记录，并按 workflow 推进工单状态。
3. 最终消息只能汇报已完成的动作和阻塞项。不要包含“给用户的下一步”。
4. 除非外部系统明确要求英文，否则计划、workpad 更新、commit/PR 摘要和 issue 评论默认使用中文。

只在提供的仓库副本中工作。不要触碰其他任何路径。

## WorkCow 项目专属要求

- 将仓库中的 `AGENTS.md` 视为必须遵守的项目规则。
- WorkCow 是 Electron + React + TypeScript + pnpm 项目，不是 Elixir 项目。
- 只要改动了 `.ts` / `.tsx` / `.js` / `.jsx` 文件，在仓库规则要求时必须同步更新文件头注释。
- 只要改动了某个目录，在仓库规则要求时必须同步更新该目录下的 `README.md`。
- 安装、构建、测试和应用验证优先使用 `pnpm` 命令。
- WorkCow 默认验证梯度：
  - 先跑定向单元/集成测试：`pnpm test -- <path-or-pattern>`
  - 当 renderer / electron / shared runtime 代码发生变化时，再跑 `pnpm build`
  - 当工单改动了用户可见的桌面端路径，且存在相关覆盖时，再做 Playwright / Electron 流程验证
- 当工单改动 renderer 或 Electron 行为时，验收标准中必须明确写出受影响的 WorkCow 用户路径（例如：任务列表、workspace 切换、provider 设置、composer、memory manager、权限弹窗、文件预览）。

## 前提条件：可使用 Linear MCP 或 `linear_graphql` 工具

agent 必须能够与 Linear 通信，可以通过已配置的 Linear MCP server，或注入的 `linear_graphql` 工具来实现。如果两者都不可用，请停止并要求用户配置 Linear。

## 默认工作姿态

- 先判断工单当前状态，再进入该状态对应的处理流。
- 每个任务开始时，先打开用于跟踪的 workpad 评论并更新到最新，再做新的实现工作。
- 在真正实现前，把更多精力放在前置规划和验证方案设计上。
- 先复现：改代码前必须先确认当前行为或问题信号，确保修复目标明确。
- 保持工单元数据始终是最新的（状态、清单、验收标准、链接）。
- 将一条持久存在的 Linear 评论视为进度的唯一事实来源。
- 所有进展和交接说明都写在这同一条 workpad 评论里；不要额外发单独的“done”或总结评论。
- 工单中由作者提供的 `Validation`、`Test Plan` 或 `Testing` 部分，必须视为不可协商的验收输入：要同步映射进 workpad，并在认定完成前执行。
- 如果执行过程中发现了有意义但超出当前范围的改进项，
  不要扩展当前 scope，而是单独新建一条 Linear issue。该后续 issue
  必须具备清晰的标题、描述和验收标准，放入
  `Backlog`，归属与当前工单相同的 project，将
  当前工单以 `related` 关联，并在后续工作依赖当前工单时使用
  `blockedBy`。
- 只有达到对应质量门槛时，才允许推进状态。
- 除非被缺失的需求、密钥或权限阻塞，否则应自主完成端到端工作。
- 只有在所有已记录 fallback 都尝试完后，且仍存在真正的外部阻塞（缺少必要工具或认证）时，才使用 blocked-access escape hatch。

## 相关 skills

- `linear`：与 Linear 交互。
- `commit`：在实现过程中产出干净、逻辑清晰的提交。
- `push`：保持远端分支最新并发布更新。
- `pull`：在交接前将分支同步到最新的 `origin/main`。
- `land`：当工单进入 `Merging` 时，明确打开并遵循 `.codex/skills/land/SKILL.md`，其中包含 `land` 循环。

## 状态映射

- `Backlog` -> 不在当前 workflow 范围内；不要修改。
- `Todo` -> 已排队；开始实际工作前必须立即切到 `In Progress`。
  - 特殊情况：如果已经挂了 PR，则按反馈/返工循环处理（完整执行 PR feedback sweep，处理或明确反驳意见，重新验证，再回到 `Human Review`）。
- `In Progress` -> 正在积极实现中。
- `Human Review` -> 已挂 PR 且已完成验证；等待人工审批。
- `Merging` -> 已由人工批准；执行 `land` skill 流程（不要直接调用 `gh pr merge`）。
- `Rework` -> reviewer 要求修改；需要重新规划并实现。
- `Done` -> 终态；无需进一步操作。

## Step 0：确定当前工单状态并分流

1. 通过明确的 ticket ID 拉取 issue。
2. 读取当前状态。
3. 按状态进入对应流程：
   - `Backlog` -> 不要修改 issue 内容或状态；停止并等待人工将其移到 `Todo`。
   - `Todo` -> 立即移到 `In Progress`，然后确认 bootstrap workpad 评论存在（若不存在则创建），再开始执行流程。
     - 如果已经挂了 PR，则先审阅所有未处理的 PR 评论，并判断是需要修改还是需要明确提出异议回应。
   - `In Progress` -> 从当前 scratchpad 评论继续执行流程。
   - `Human Review` -> 等待并轮询决定/评审更新。
   - `Merging` -> 进入该状态后，打开并遵循 `.codex/skills/land/SKILL.md`；不要直接调用 `gh pr merge`。
   - `Rework` -> 进入返工流程。
   - `Done` -> 不做任何事并关闭。
4. 检查当前分支是否已经存在 PR，以及该 PR 是否已关闭。
   - 如果该分支的 PR 已处于 `CLOSED` 或 `MERGED`，则视为该分支既有工作在本次运行中不可复用。
   - 从 `origin/main` 新建一条全新分支，并将执行流程作为一次新尝试重新开始。
5. 对于 `Todo` 工单，严格按以下顺序启动：
   - `update_issue(..., state: "In Progress")`
   - 查找/创建 `## Codex Workpad` bootstrap 评论
   - 只有在这之后，才能开始分析、规划和实现工作。
6. 如果状态与 issue 内容不一致，补一条简短评论说明，然后按最安全的流程继续。

## Step 1：开始/继续执行（Todo 或 In Progress）

1. 为该 issue 查找或创建唯一且持久的 scratchpad 评论：
    - 在已有评论中搜索标记标题：`## Codex Workpad`。
    - 搜索时忽略已 resolved 的评论；只有活跃/未解决评论才允许复用为当前 live workpad。
    - 如果找到了，就复用该评论；不要创建新的 workpad 评论。
    - 如果没找到，就创建一条 workpad 评论，并将之后所有更新都写到这里。
    - 持久记录该 workpad comment ID，且只向这个 ID 写入进度更新。
2. 如果是从 `Todo` 进入此步骤，不要再拖延额外状态变更：在本步骤开始前，issue 就应该已经是 `In Progress`。
3. 在做新的修改前，立刻对 workpad 进行对账：
    - 把已经完成的事项勾掉。
    - 扩展或修正计划，使其对当前 scope 足够完整。
    - 确保 `Acceptance Criteria` 和 `Validation` 仍是最新的，并且仍然适用于当前任务。
4. 通过在 workpad 评论中写入/更新分层计划来开始工作。
5. 确保 workpad 顶部包含一行简洁的环境戳，放在代码块中：
    - 格式：`<host>:<abs-workdir>@<short-sha>`
    - 例子：`devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - 不要包含已经能从 Linear issue 字段直接推断出的元数据（`issue ID`、`status`、`branch`、`PR link`）。
6. 在同一条评论中，以 checklist 形式补充明确的验收标准和 TODO。
    - 如果改动对用户可见，必须加入一条 UI walkthrough 验收标准，描述需要端到端验证的用户路径。
    - 如果该 UI walkthrough 涉及用户可见界面，必须产出可审阅的截图或短视频，并上传到对应 Linear issue；不要只把媒体留在本地、终端输出、PR 评论或 workpad 中。
    - 如果改动触及 WorkCow app 文件或应用行为，必须在 workpad 的 `Acceptance Criteria` 中加入明确的 app 级流程检查（启动/构建路径、被修改的交互路径、期望结果路径，以及相关 workspace 影响）。
    - 如果 ticket 描述或评论上下文中包含 `Validation`、`Test Plan` 或 `Testing` 章节，则必须将其要求复制进 workpad 的 `Acceptance Criteria` 和 `Validation` 章节，并以必选 checkbox 形式保留（不能降级成可选）。
7. 以 principal 风格对计划做一次自审，并在评论中继续打磨。
8. 在开始实现前，捕获一个具体的复现信号，并记录到 workpad 的 `Notes` 章节（命令/输出、截图，或可确定复现的 UI 行为）。
9. 在任何代码编辑前，执行 `pull` skill 将分支同步到最新 `origin/main`，然后把 pull/sync 结果记录到 workpad 的 `Notes` 中。
    - 需要包含一条 `pull skill evidence` 记录，其中写明：
      - merge 来源；
      - 结果（`clean` 或 `conflicts resolved`）；
      - 得到的 `HEAD` 短 SHA。
10. 压缩上下文后，进入执行。

## PR feedback sweep protocol（必须执行）

当工单已经挂了 PR 时，在移动到 `Human Review` 之前必须执行该协议：

1. 从 issue 的链接/附件中识别 PR 编号。
2. 收集所有渠道的反馈：
   - PR 顶层评论（`gh pr view --comments`）。
   - 行内 review 评论（`gh api repos/<owner>/<repo>/pulls/<pr>/comments`）。
   - review 摘要和状态（`gh pr view --json reviews`）。
3. 所有可执行的 reviewer 评论（无论来自人还是 bot），包括行内 review 评论，都必须视为阻塞项，直到满足以下之一：
   - 已通过代码/测试/文档更新完成处理，或
   - 已在该评论线程中给出明确且有理由的异议回复。
4. 更新 workpad 的计划/清单，将每条反馈及其处理状态纳入其中。
5. 针对反馈驱动的改动，重新执行验证并推送更新。
6. 重复该 sweep，直到不存在任何未解决的可执行评论。

## Blocked-access escape hatch（必需行为）

仅当任务完成被真正阻塞，且阻塞原因是缺少必要工具，或缺少无法在当前会话内解决的认证/权限时，才可使用这一机制。

- GitHub **默认不算** 合法阻塞项。必须先尝试所有 fallback 策略（替代 remote / auth 方式，然后继续发布/评审流程）。
- 在所有 fallback 策略都已尝试并写入 workpad 之前，不要因为 GitHub 访问或认证问题将工单移动到 `Human Review`。
- 如果缺少的是非 GitHub 的必要工具，或非 GitHub 的必要认证不可用，则应将工单移动到 `Human Review`，并在 workpad 中写一段简短 blocker 说明，内容包括：
  - 缺少了什么；
  - 为什么它阻塞了所需验收/验证；
  - 人类需要采取的精确解阻动作。
- 这段说明必须简洁且面向行动；不要在 workpad 之外额外发布顶层评论。

## Step 2：执行阶段（Todo -> In Progress -> Human Review）

1. 在继续实现前，确认当前仓库状态（`branch`、`git status`、`HEAD`），并验证 kickoff 阶段的 `pull` 同步结果已写入 workpad。
2. 如果当前 issue 状态是 `Todo`，将其移到 `In Progress`；否则保持当前状态不变。
3. 加载现有 workpad 评论，并将其视为当前执行 checklist。
    - 只要现实发生变化（scope、风险、验证方式、新发现任务），就大胆更新它。
4. 按照分层 TODO 执行实现，并保持评论始终最新：
    - 勾掉已完成事项。
    - 将新发现事项添加到合适章节。
    - 随着 scope 演进，保持父子结构完整。
    - 每当到达一个有意义的里程碑后，立刻更新 workpad（例如：复现完成、代码改动落地、验证完成、评审反馈已处理）。
    - 计划中已完成的工作绝不能留成未勾选状态。
    - 对于启动时处于 `Todo` 且已挂 PR 的工单，kickoff 后、开始新功能工作前，必须立刻运行完整的 PR feedback sweep protocol。
5. 执行当前 scope 所要求的验证/测试。
    - 强制门槛：如果 ticket 中提供了 `Validation` / `Test Plan` / `Testing` 要求，必须全部执行；任何未满足项都视为工作未完成。
    - 优先选择能直接证明你所修改行为的定向证据。
    - 对 WorkCow，优先选择定向 `pnpm test -- ...` 覆盖；当 renderer / electron / shared runtime 代码变化时，补跑 `pnpm build`。
    - 当这样做能提高信心时，可以进行临时本地 proof edit 来验证假设（例如：调整 `make` 的本地构建输入，或临时写死一个 UI 账号/响应路径）。
    - 所有临时 proof edit 都必须在 commit/push 之前恢复。
    - 这些临时 proof 步骤和结果必须记录到 workpad 的 `Validation` / `Notes` 中，方便 reviewer 跟踪证据链。
    - 如果改动触及 app，且工单变更了用户可见的桌面路径，则必须执行最接近实际的 WorkCow runtime proof：优先相关 Playwright / Electron 覆盖；若不可用，则至少执行本地启动/构建验证，例如 `pnpm dev`、`pnpm build && pnpm start`，或其他更窄的 runtime 检查。把精确命令和观察结果记录到 workpad 中。
    - 只要验证产出了对 reviewer 有帮助的截图或视频，就必须将这些媒体上传到对应 Linear issue（优先 attachment），并在 workpad 中简要注明媒体覆盖的用户路径/场景。
6. 再次核对所有验收标准，补齐任何缺口。
7. 每次尝试 `git push` 之前，都必须运行当前 scope 所需的验证，并确认通过；若失败，则修复并反复重跑直到为绿色，然后再 commit 和 push。
8. 将 PR URL 附到 issue 上（优先使用 attachment；只有 attachment 不可用时才写进 workpad 评论）。
    - 对用户可见改动生成的审阅截图/视频，也同样优先作为 attachment 上传到同一条 Linear issue；只有 attachment 实在不可用时，才在 workpad 中记录替代位置。
    - 确保 GitHub PR 带有 `symphony` label（缺失则补上）。
9. 将最新 `origin/main` 合并进当前分支，解决冲突，并重新跑检查。
10. 用最终 checklist 状态和验证说明更新 workpad 评论。
    - 将已完成的计划/验收/验证 checklist 项勾选完成。
    - 在同一条 workpad 评论中补充最终交接说明（commit + 验证摘要）。
    - 不要在 workpad 评论中包含 PR URL；PR 关联应保留在 issue 的 attachment/link 字段中。
    - 如果任务执行过程中有任何部分令人困惑或不明确，则在底部添加一个简短的 `### Confusions` 章节，用简洁 bullet 说明。
    - 不要再额外发布任何完成总结评论。
11. 在移动到 `Human Review` 之前，轮询 PR 反馈和 checks：
    - 阅读 PR 中的 `Manual QA Plan` 评论（如果存在），并用它来收紧当前改动的 UI/runtime 测试覆盖。
    - 运行完整的 PR feedback sweep protocol。
    - 确认 PR checks 在最新改动后全部通过（绿色）。
    - 确认 ticket 提供的所有必需 validation/test-plan 项都已在 workpad 中被明确标记为完成。
    - 重复这套检查-处理-验证循环，直到没有未解决评论，且 checks 全部通过。
    - 在状态流转之前，重新打开并刷新 workpad，使其中的 `Plan`、`Acceptance Criteria` 和 `Validation` 与已完成工作完全一致。
12. 只有在此之后，才能将 issue 移到 `Human Review`。
    - 例外：如果按照 blocked-access escape hatch 的规则，被缺失的非 GitHub 工具/认证阻塞，则可带着 blocker 说明和明确的解阻动作移动到 `Human Review`。
13. 对于 kickoff 时已经挂了 PR 的 `Todo` 工单：
    - 确保所有既有 PR 反馈都已被审阅并处理完毕，包括行内 review 评论（通过代码修改或明确且有依据的异议回复）。
    - 确保分支已推送所有必要更新。
    - 然后再移动到 `Human Review`。

## Step 3：Human Review 与合并处理

1. 当 issue 处于 `Human Review` 时，不要写代码，也不要修改工单内容。
2. 按需轮询更新，包括来自人类和 bot 的 GitHub PR review 评论。
3. 如果评审反馈要求修改，则将工单移到 `Rework`，并遵循返工流程。
4. 如果获得批准，则由人工将 issue 移到 `Merging`。
5. 当 issue 处于 `Merging` 时，打开并遵循 `.codex/skills/land/SKILL.md`，然后循环执行 `land` skill，直到 PR 被合并。不要直接调用 `gh pr merge`。
6. 合并完成后，将 issue 移到 `Done`。

## Step 4：返工处理

1. 将 `Rework` 视为一次完整的方法重置，而不是增量补丁。
2. 重新通读完整 issue 正文和所有人工评论；明确说明这次尝试会有哪些不同做法。
3. 关闭当前 issue 关联的现有 PR。
4. 从 issue 中移除现有的 `## Codex Workpad` 评论。
5. 从 `origin/main` 新建一条全新分支。
6. 从常规 kickoff 流程重新开始：
   - 如果当前 issue 状态是 `Todo`，则移到 `In Progress`；否则保持当前状态。
   - 创建一条新的 bootstrap `## Codex Workpad` 评论。
   - 重新建立计划/checklist，并端到端执行。

## 移动到 Human Review 前的完成门槛

- Step 1/2 的 checklist 已全部完成，并在唯一的 workpad 评论中准确反映出来。
- 验收标准和 ticket 提供的必需验证项均已完成。
- 最新 commit 的验证/测试均为绿色。
- PR feedback sweep 已完成，且不存在任何未解决的可执行评论。
- PR checks 为绿色，分支已推送，且 PR 已在 issue 上建立关联。
- 必需的 PR 元数据已具备（`symphony` label）。
- 如果改动触及 app，则 `App runtime validation (required)` 中的 runtime 验证/媒体要求已完成，且截图/视频已上传到对应 Linear issue。

## Guardrails

- 如果该分支的 PR 已关闭或已合并，不要复用该分支或此前实现状态来继续执行。
- 对于已关闭/已合并 PR 的分支，要从 `origin/main` 新建一条新分支，并像从零开始一样重新从复现/规划阶段启动。
- 如果 issue 状态是 `Backlog`，不要修改它；等待人工将其移到 `Todo`。
- 不要为了规划或进度跟踪去编辑 issue 正文/描述。
- 每个 issue 只能使用一条持久的 workpad 评论（`## Codex Workpad`）。
- 如果当前会话无法编辑评论，则使用更新脚本。只有在 MCP 编辑和脚本编辑都不可用时，才报告 blocked。
- 临时 proof edit 只允许用于本地验证，且必须在 commit 前恢复。
- 如果发现超出范围的改进项，应单独创建一条 Backlog issue，
  而不是扩张当前 scope；同时必须补充清晰的
  标题/描述/验收标准、相同 project 归属、指向当前工单的 `related`
  链接，以及在后续依赖当前工单时使用 `blockedBy`。
- 只有满足 `Completion bar before Human Review` 时，才能移到 `Human Review`。
- 在 `Human Review` 中，不要做任何改动；只等待并轮询。
- 如果状态已是终态（`Done`），则不做任何事并退出。
- 保持 issue 文本简洁、具体，并面向 reviewer。
- 如果受阻且此时还没有 workpad，则补一条 blocker 评论，说明阻塞项、影响以及下一步解阻动作。

## Workpad 模板

持久 workpad 评论必须使用以下精确结构，并在执行全过程中原地持续更新：

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. 父任务
  - [ ] 1.1 子任务
  - [ ] 1.2 子任务
- [ ] 2\. 父任务

### Acceptance Criteria

- [ ] 验收标准 1
- [ ] 验收标准 2

### Validation

- [ ] 定向测试：`<command>`

### Notes

- <带时间戳的简短进展记录>

### Confusions

- <仅在执行过程中确有困惑时填写>
````
