defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony orchestration
            </p>
            <h1 class="hero-title">
              编排席
            </h1>
            <p class="hero-copy">
              把在途会话、退避节奏与配额窗口压进一张更克制的控制面，给值守、接管与判断留出空间。
            </p>

            <div class="hero-facts">
              <a :if={project_url()} class="hero-chip hero-chip-link" href={project_url()} target="_blank" rel="noreferrer">
                <span class="hero-chip-label">project</span>
                <span class="mono"><%= SymphonyElixir.Config.linear_project_slug() %></span>
              </a>
              <span class="hero-chip">
                <span class="hero-chip-label">snapshot</span>
                <span class="mono"><%= display_timestamp(@payload.generated_at) %></span>
              </span>
            </div>
          </div>

          <div class="hero-aside">
            <div class="status-stack">
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                在线
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                离线
              </span>
            </div>

            <div class="signal-panel">
              <p class="signal-label">pulse</p>
              <div class="signal-row">
                <span>在途</span>
                <strong class="numeric"><%= payload_count(@payload, :running) %></strong>
              </div>
              <div class="signal-row">
                <span>退避</span>
                <strong class="numeric"><%= payload_count(@payload, :retrying) %></strong>
              </div>
              <div class="signal-row">
                <span>用时</span>
                <strong class="numeric"><%= format_runtime_seconds(payload_runtime_seconds(@payload, @now)) %></strong>
              </div>
            </div>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            快照暂不可用
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card metric-card-major">
            <p class="metric-label">在途</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">当前实例里仍在推进的 issue 会话数量。</p>
            <div class="metric-meta-grid">
              <div class="metric-meta">
                <span class="metric-meta-label">退避</span>
                <strong class="numeric"><%= @payload.counts.retrying %></strong>
              </div>
              <div class="metric-meta">
                <span class="metric-meta-label">快照</span>
                <strong class="mono"><%= display_timestamp(@payload.generated_at) %></strong>
              </div>
            </div>
          </article>

          <article class="metric-card">
            <p class="metric-label">退避</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">已进入退避窗口、等待下一次重试的工单。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Token</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              输入 <%= format_int(@payload.codex_totals.input_tokens) %> / 输出 <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">累计用时</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">已完成与进行中会话叠加后的 Codex 总运行时长。</p>
          </article>
        </section>

        <div class="section-layout">
          <section class="section-card section-card-main">
            <div class="section-header">
              <div>
                <p class="section-kicker">live stream</p>
                <h2 class="section-title">在途会话</h2>
                <p class="section-copy">追踪活跃工单、最近一次 Codex 动态，以及当前回合内的 Token 消耗。</p>
              </div>
            </div>

            <%= if @payload.running == [] do %>
              <p class="empty-state">当前没有活跃会话。</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-running">
                  <colgroup>
                    <col style="width: 10rem;" />
                    <col style="width: 7rem;" />
                    <col style="width: 8.8rem;" />
                    <col style="width: 8.5rem;" />
                    <col />
                    <col style="width: 11rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>工单</th>
                      <th>状态</th>
                      <th>会话</th>
                      <th>用时 / 回合</th>
                      <th>最新动态</th>
                      <th>Token</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.running}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>查看 JSON</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= display_state(entry.state) %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="复制会话 ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = '已复制'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              复制会话 ID
                            </button>
                          <% else %>
                            <span class="muted">未分配</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={display_last_message(entry.last_message || to_string(entry.last_event || "n/a"))}
                          ><%= display_last_message(entry.last_message || to_string(entry.last_event || "n/a")) %></span>
                          <span class="muted event-meta">
                            <%= display_event_name(entry.last_event) %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= display_timestamp(entry.last_event_at) %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>总计 <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">输入 <%= format_int(entry.tokens.input_tokens) %> / 输出 <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <div class="section-stack">
            <section class="section-card">
              <div class="section-header">
                <div>
                  <p class="section-kicker">quota</p>
                  <h2 class="section-title">配额视窗</h2>
                  <p class="section-copy">将主窗口、次窗口和 credits 折叠成更适合值班查看的中文摘要。</p>
                </div>
              </div>

              <%= if rate_limits_available?(@payload.rate_limits) do %>
                <div class="limit-grid">
                  <article class="limit-card">
                    <p class="limit-label">通道</p>
                    <p class="limit-value"><%= rate_limit_identity(@payload.rate_limits) %></p>
                    <p class="limit-copy">当前实例拿到的限流命名空间与计划类型。</p>
                  </article>

                  <article class="limit-card">
                    <p class="limit-label">主窗口</p>
                    <p class="limit-value numeric"><%= format_percent(primary_limit_used(@payload.rate_limits)) %></p>
                    <p class="limit-copy"><%= format_rate_window(primary_limit_bucket(@payload.rate_limits)) %></p>
                  </article>

                  <article class="limit-card">
                    <p class="limit-label">次窗口</p>
                    <p class="limit-value numeric"><%= format_percent(secondary_limit_used(@payload.rate_limits)) %></p>
                    <p class="limit-copy"><%= format_rate_window(secondary_limit_bucket(@payload.rate_limits)) %></p>
                  </article>

                  <article class="limit-card">
                    <p class="limit-label">Credits</p>
                    <p class="limit-value numeric"><%= format_credits(rate_limit_value(@payload.rate_limits, :credits)) %></p>
                    <p class="limit-copy">若上游未返回该字段，这里会明确标记为未返回。</p>
                  </article>
                </div>
              <% else %>
                <p class="empty-state">上游暂未返回限流快照。</p>
              <% end %>
            </section>

            <section class="section-card">
              <div class="section-header">
                <div>
                  <p class="section-kicker">backoff</p>
                  <h2 class="section-title">退避序列</h2>
                  <p class="section-copy">查看哪些工单正在等待下一个退避窗口，以及当前失败原因。</p>
                </div>
              </div>

              <%= if @payload.retrying == [] do %>
                <p class="empty-state">当前没有进入退避的工单。</p>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table retry-table">
                    <thead>
                      <tr>
                        <th>工单</th>
                        <th>尝试</th>
                        <th>下次重试</th>
                        <th>错误</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={entry <- @payload.retrying}>
                        <td>
                          <div class="issue-stack">
                            <span class="issue-id"><%= entry.issue_identifier %></span>
                            <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>查看 JSON</a>
                          </div>
                        </td>
                        <td class="numeric"><%= entry.attempt %></td>
                        <td class="mono"><%= display_timestamp(entry.due_at) %></td>
                        <td><%= entry.error || "未返回" %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </section>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp payload_count(payload, key) when is_map(payload) do
    payload
    |> Map.get(:counts, %{})
    |> Map.get(key, 0)
  end

  defp payload_runtime_seconds(%{error: _error}, _now), do: 0
  defp payload_runtime_seconds(payload, now), do: total_runtime_seconds(payload, now)

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}轮"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)

    cond do
      mins > 0 -> "#{mins}分 #{secs}秒"
      true -> "#{secs}秒"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp display_state(state) do
    case state |> to_string() |> String.trim() do
      "Todo" -> "待开始"
      "In Progress" -> "进行中"
      "Human Review" -> "人工评审"
      "Rework" -> "返工中"
      "Merging" -> "合并中"
      "Done" -> "已完成"
      "Canceled" -> "已取消"
      "Cancelled" -> "已取消"
      "Closed" -> "已关闭"
      other when other in ["", "nil"] -> "未返回"
      other -> other
    end
  end

  defp display_event_name(nil), do: "未返回"

  defp display_event_name(event) do
    case event |> to_string() do
      "notification" -> "通知"
      "item_started" -> "步骤开始"
      "item_completed" -> "步骤完成"
      "turn_started" -> "回合开始"
      "turn_completed" -> "回合完成"
      "turn_failed" -> "回合失败"
      "turn_timeout" -> "回合超时"
      other when other in ["", "nil"] -> "未返回"
      other -> other
    end
  end

  defp display_last_message(message) when is_binary(message), do: localize_dashboard_message(message)
  defp display_last_message(message), do: message |> to_string() |> localize_dashboard_message()

  defp localize_dashboard_message(message) do
    translations = [
      {"agent message streaming: ", "Agent 消息流："},
      {"agent message content streaming: ", "Agent 内容流："},
      {"reasoning streaming: ", "推理流："},
      {"reasoning content streaming: ", "推理内容流："},
      {"item started: ", "步骤开始："},
      {"item completed: ", "步骤完成："},
      {"mcp startup: ", "MCP 启动："},
      {"rate limits updated: ", "限流已更新："},
      {"turn diff updated", "本轮差异已更新"},
      {"mcp startup complete", "MCP 启动完成"},
      {"task started", "任务开始"},
      {"user message received", "已接收用户消息"},
      {"command output streaming", "命令输出流"},
      {"command completed", "命令执行完成"},
      {"command started", "命令执行开始"},
      {"dynamic tool call requested", "动态工具调用请求"},
      {"token count update", "Token 计数更新"},
      {"tool requires user input", "工具需要用户输入"}
    ]

    Enum.reduce_while(translations, message, fn {prefix, replacement}, acc ->
      cond do
        acc == prefix -> {:halt, replacement}
        String.starts_with?(acc, prefix) -> {:halt, replacement <> String.replace_prefix(acc, prefix, "")}
        true -> {:cont, acc}
      end
    end)
  end

  defp display_timestamp(nil), do: "未返回"

  defp display_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%SZ")
  end

  defp display_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> display_timestamp(datetime)
      _ -> timestamp
    end
  end

  defp display_timestamp(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp) do
      {:ok, datetime} -> display_timestamp(datetime)
      _ -> Integer.to_string(timestamp)
    end
  end

  defp display_timestamp(timestamp), do: timestamp |> to_string()

  defp rate_limits_available?(rate_limits), do: is_map(rate_limits) and map_size(rate_limits) > 0

  defp rate_limit_identity(rate_limits) do
    [rate_limit_value(rate_limits, :limit_name), rate_limit_value(rate_limits, :limit_id), rate_limit_value(rate_limits, :plan_type)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      [] -> "未返回"
      values -> Enum.join(values, " / ")
    end
  end

  defp primary_limit_bucket(rate_limits), do: rate_limit_value(rate_limits, :primary)
  defp secondary_limit_bucket(rate_limits), do: rate_limit_value(rate_limits, :secondary)

  defp primary_limit_used(rate_limits), do: rate_limit_value(primary_limit_bucket(rate_limits), :used_percent)
  defp secondary_limit_used(rate_limits), do: rate_limit_value(secondary_limit_bucket(rate_limits), :used_percent)

  defp format_percent(value) when is_integer(value), do: "#{value}%"
  defp format_percent(value) when is_float(value), do: "#{:erlang.float_to_binary(value, decimals: 0)}%"
  defp format_percent(_value), do: "未返回"

  defp format_rate_window(bucket) when is_map(bucket) do
    window = bucket |> rate_limit_value(:window_minutes) |> humanize_window_minutes()
    reset_at = bucket |> rate_limit_value(:resets_at) |> display_timestamp()
    "#{window} · 重置 #{reset_at}"
  end

  defp format_rate_window(_bucket), do: "窗口信息未返回"

  defp humanize_window_minutes(minutes) when is_integer(minutes) and minutes >= 1 do
    cond do
      rem(minutes, 1_440) == 0 -> "#{div(minutes, 1_440)}天窗口"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)}小时窗口"
      true -> "#{minutes}分钟窗口"
    end
  end

  defp humanize_window_minutes(_minutes), do: "窗口未返回"

  defp format_credits(nil), do: "未返回"
  defp format_credits("unlimited"), do: "无限"
  defp format_credits(value) when is_integer(value), do: format_int(value)
  defp format_credits(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_credits(value) when is_binary(value), do: value
  defp format_credits(value), do: to_string(value)

  defp rate_limit_value(nil, _key), do: nil

  defp rate_limit_value(rate_limits, key) when is_map(rate_limits) do
    Map.get(rate_limits, key) || Map.get(rate_limits, Atom.to_string(key))
  end

  defp project_url do
    case SymphonyElixir.Config.linear_project_slug() do
      project_slug when is_binary(project_slug) and project_slug != "" ->
        "https://linear.app/project/#{project_slug}/issues"

      _ ->
        nil
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
