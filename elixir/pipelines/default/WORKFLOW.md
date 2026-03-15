你正在处理 Symphony 仓库中的 Linear 工单 `{{ issue.identifier }}`

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

## Symphony 项目专属要求

- 将仓库中的 `AGENTS.md` 视为必须遵守的项目规则。
- 当前仓库的主要运行时代码在 `elixir/` 目录下。
- 涉及运行时、LiveView、Mix task、测试或文档改动时，优先在仓库根目录执行 `make -C elixir ...`，或进入 `elixir/` 后使用 `mise exec -- mix ...`。
- 对 Elixir 代码改动，默认验证梯度：
  - 先跑定向测试：`cd elixir && mise exec -- mix test <path>`
  - 涉及格式或静态检查时，跑 `cd elixir && mise exec -- mix format --check-formatted`
  - 在准备提交或推送前，优先跑 `make -C elixir all`
- 如果改动了 dashboard / LiveView UI，验收标准中必须写明受影响页面或用户路径（例如：`/panel/config`、`/panel/logs`、`/api/v1/pipelines`）。
- 如果改动涉及 pipeline 模板、启动路径或配置编辑器，必须同步检查 `elixir/README.md` 与默认模板是否仍一致。

## 前提条件：可使用 Linear MCP 或 `linear_graphql` 工具

agent 必须能够与 Linear 通信，可以通过已配置的 Linear MCP server，或注入的 `linear_graphql` 工具来实现。如果两者都不可用，请停止并要求用户配置 Linear。
