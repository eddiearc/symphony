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
- 当工单改动 renderer 或 Electron 行为时，验收标准中必须明确写出受影响的 WorkCow 用户路径。

## 前提条件：可使用 Linear MCP 或 `linear_graphql` 工具

agent 必须能够与 Linear 通信，可以通过已配置的 Linear MCP server，或注入的 `linear_graphql` 工具来实现。如果两者都不可用，请停止并要求用户配置 Linear。

## 默认工作姿态

- 先判断工单当前状态，再进入该状态对应的处理流。
- 每个任务开始时，先打开用于跟踪的 workpad 评论并更新到最新，再做新的实现工作。
- 在真正实现前，把更多精力放在前置规划和验证方案设计上。
- 先复现：改代码前必须先确认当前行为或问题信号，确保修复目标明确。
- 保持工单元数据始终是最新的。
- 将一条持久存在的 Linear 评论视为进度的唯一事实来源。
- 所有进展和交接说明都写在这同一条 workpad 评论里；不要额外发单独的“done”或总结评论。
- 工单中由作者提供的 `Validation`、`Test Plan` 或 `Testing` 部分，必须视为不可协商的验收输入。
- 只有达到对应质量门槛时，才允许推进状态。
- 除非被缺失的需求、密钥或权限阻塞，否则应自主完成端到端工作。

## 状态映射

- `Backlog` -> 不在当前 workflow 范围内；不要修改。
- `Todo` -> 已排队；开始实际工作前必须立即切到 `In Progress`。
- `In Progress` -> 正在积极实现中。
- `Human Review` -> 已挂 PR 且已完成验证；等待人工审批。
- `Merging` -> 已由人工批准；执行 `land` skill 流程。
- `Rework` -> reviewer 要求修改；需要重新规划并实现。
- `Done` -> 终态；无需进一步操作。
