defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Pipeline, PipelineLoader, PipelineSupervisor, StatusDashboard, Workflow}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @state_labels %{
    "Todo" => "待开始",
    "In Progress" => "进行中",
    "Human Review" => "人工评审",
    "Rework" => "返工中",
    "Merging" => "合并中",
    "Done" => "已完成",
    "Canceled" => "已取消",
    "Cancelled" => "已取消",
    "Closed" => "已关闭"
  }
  @event_labels %{
    "notification" => "通知",
    "item_started" => "步骤开始",
    "item_completed" => "步骤完成",
    "turn_started" => "回合开始",
    "turn_completed" => "回合完成",
    "turn_failed" => "回合失败",
    "turn_timeout" => "回合超时"
  }

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:panel, normalize_panel(Map.get(params || %{}, "panel")))
      |> assign(:selected_pipeline_id, nil)
      |> assign(:config_view, "structured")
      |> assign(:pipeline_root_path, Workflow.pipeline_root_path())
      |> assign(:pipeline_root_available, File.dir?(Workflow.pipeline_root_path()))
      |> assign(:new_pipeline_form_open, false)
      |> assign(:new_pipeline_form, new_pipeline_form_defaults())
      |> assign(:new_pipeline_feedback, nil)
      |> assign(:workflow_feedback, nil)
      |> assign_workflow_editor()

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :panel, normalize_panel(Map.get(params || %{}, "panel")))

    if socket.assigns.panel == "config" do
      {:noreply, assign_workflow_editor(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> refresh_log_payload()}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("workflow_changed", %{"workflow" => %{"body" => body}}, socket) do
    socket =
      socket
      |> assign(:workflow_body, body)
      |> assign(:workflow_dirty, true)
      |> assign(:workflow_feedback, nil)
      |> maybe_sync_workflow_form_from_body(body)

    {:noreply, socket}
  end

  def handle_event("workflow_form_changed", %{"workflow_form" => params}, socket) do
    workflow_form = Map.merge(socket.assigns.workflow_form, params)
    workflow_body = build_workflow_body(socket.assigns.workflow_loaded, workflow_form)

    socket =
      socket
      |> assign(:workflow_form, workflow_form)
      |> assign(:workflow_body, workflow_body)
      |> assign(:workflow_dirty, true)
      |> assign(:workflow_feedback, nil)
      |> maybe_sync_workflow_form_from_body(workflow_body)
      |> assign_workflow_insights()

    {:noreply, socket}
  end

  def handle_event("workflow_form_preset", %{"field" => field, "value" => value}, socket) do
    workflow_form = Map.put(socket.assigns.workflow_form, field, value)
    workflow_body = build_workflow_body(socket.assigns.workflow_loaded, workflow_form)

    socket =
      socket
      |> assign(:workflow_form, workflow_form)
      |> assign(:workflow_body, workflow_body)
      |> assign(:workflow_dirty, true)
      |> assign(:workflow_feedback, nil)
      |> maybe_sync_workflow_form_from_body(workflow_body)
      |> assign_workflow_insights()

    {:noreply, socket}
  end

  def handle_event("reload_workflow", _params, socket) do
    feedback = %{kind: :info, message: reload_feedback_message(socket.assigns.workflow_target)}

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign_workflow_editor(feedback: feedback)
     |> assign(:panel, "config")}
  end

  def handle_event("select_config_pipeline", %{"pipeline_id" => pipeline_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_pipeline_id, pipeline_id)
     |> assign_workflow_editor()
     |> assign(:panel, "config")}
  end

  def handle_event("open_new_pipeline_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_pipeline_form_open, true)
     |> assign(:new_pipeline_form, new_pipeline_form_defaults())
     |> assign(:new_pipeline_feedback, nil)
     |> assign(:panel, "config")}
  end

  def handle_event("cancel_new_pipeline_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_pipeline_form_open, false)
     |> assign(:new_pipeline_form, new_pipeline_form_defaults())
     |> assign(:new_pipeline_feedback, nil)
     |> assign(:panel, "config")}
  end

  def handle_event("new_pipeline_form_changed", %{"new_pipeline" => params}, socket) do
    {:noreply,
     socket
     |> assign(:new_pipeline_form, merge_new_pipeline_form(params))
     |> assign(:new_pipeline_feedback, nil)
     |> assign(:panel, "config")}
  end

  def handle_event("create_pipeline", %{"new_pipeline" => params}, socket) do
    form = merge_new_pipeline_form(params)

    case scaffold_pipeline(socket.assigns.pipeline_root_path, form) do
      {:ok, pipeline_id} ->
        feedback = %{kind: :ok, message: "已创建并装载新的 pipeline。"}

        {:noreply,
         socket
         |> assign(:selected_pipeline_id, pipeline_id)
         |> assign(:new_pipeline_form_open, false)
         |> assign(:new_pipeline_form, new_pipeline_form_defaults())
         |> assign(:new_pipeline_feedback, nil)
         |> assign(:payload, load_payload())
         |> assign_workflow_editor(feedback: feedback)
         |> assign(:panel, "config")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:new_pipeline_form_open, true)
         |> assign(:new_pipeline_form, form)
         |> assign(:new_pipeline_feedback, %{kind: :error, message: format_new_pipeline_reason(reason)})
         |> assign(:panel, "config")}
    end
  end

  def handle_event("switch_config_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, :config_view, normalize_config_view(view))}
  end

  def handle_event("save_workflow", %{"workflow" => %{"body" => body}}, socket) do
    effective_body = resolve_workflow_save_body(socket, body)

    case save_workflow_body(socket.assigns.workflow_target, effective_body) do
      :ok ->
        feedback = %{kind: :ok, message: save_feedback_message(socket.assigns.workflow_target)}

        {:noreply,
         socket
         |> assign(:payload, load_payload())
         |> assign_workflow_editor(feedback: feedback)
         |> assign(:panel, "config")}

      {:error, reason} ->
        feedback = %{kind: :error, message: format_workflow_reason(reason, socket.assigns.workflow_target)}

        {:noreply,
         socket
         |> assign(:workflow_body, effective_body)
         |> assign(:workflow_dirty, true)
         |> assign(:workflow_feedback, feedback)
         |> assign(:panel, "config")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <div class="workspace-frame">
        <aside class="control-nav-shell">
          <div class="control-nav-card">
            <p class="control-nav-kicker">control deck</p>
            <h2 class="control-nav-title">工作区</h2>
            <p class="control-nav-copy">把模块切换放进最左侧，让观测和配置像两条并列工位，而不是页面上的临时标签。</p>

            <nav class="control-nav-list" aria-label="控制面模块">
              <.link
                navigate={panel_path("observability")}
                class={control_nav_link_class(@panel, "observability")}
              >
                <span class="control-nav-eyebrow">Monitor</span>
                <strong>观测区</strong>
                <span>查看在途会话、退避、配额和实时运行状态。</span>
              </.link>
              <.link
                navigate={panel_path("config")}
                class={control_nav_link_class(@panel, "config")}
              >
                <span class="control-nav-eyebrow">Configure</span>
                <strong>配置区</strong>
                <span>按 pipeline 管理运行配置，保存前确认改动范围，并热重载编辑器。</span>
              </.link>
              <.link
                navigate={panel_path("logs")}
                class={control_nav_link_class(@panel, "logs")}
              >
                <span class="control-nav-eyebrow">Logs</span>
                <strong>日志区</strong>
                <span>查看 Symphony 当前实例的磁盘日志尾部输出和落盘路径。</span>
              </.link>
            </nav>

            <div class="control-nav-meta">
              <span class="hero-chip">
                <span class="hero-chip-label">snapshot</span>
                <span class="mono"><%= display_timestamp(@payload.generated_at) %></span>
              </span>
            </div>
          </div>
        </aside>

        <div class="workspace-main">
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
                  <span :if={multi_pipeline_payload?(@payload)} class="hero-chip hero-chip-ghost">
                    <span class="hero-chip-label">pipelines</span>
                    <span class="mono"><%= payload_pipeline_count(@payload) %></span>
                  </span>
                  <a :if={!multi_pipeline_payload?(@payload) and project_url()} class="hero-chip hero-chip-link" href={project_url()} target="_blank" rel="noreferrer">
                    <span class="hero-chip-label">project</span>
                    <span class="mono"><%= Config.linear_project_slug() %></span>
                  </a>
                  <span class="hero-chip hero-chip-ghost">
                    <span class="hero-chip-label">mode</span>
                    <span class="mono"><%= panel_mode_label(@panel) %></span>
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

          <%= if @panel == "config" do %>
            <section class="config-stack">
              <section class="section-card config-command-bar">
                <div class="config-command-grid">
                  <div class="config-command-copy">
                    <p class="section-kicker">pipeline control</p>
                    <h2 class="config-studio-title"><%= workflow_editor_title(@workflow_target, @config_pipelines) %></h2>
                    <p class="config-studio-copy">先看清宿主上有多少 pipeline、当前选中的是谁、它是不是在线，再进入具体编辑器。配置区现在应该像控制台，而不是一整块表单。</p>

                    <div class="config-command-stats">
                      <article class="config-command-stat">
                        <p class="config-command-stat-label">pipelines</p>
                        <strong class="config-command-stat-value numeric"><%= length(@config_pipelines) %></strong>
                        <span class="config-command-stat-copy">宿主当前可切换的 pipeline 数量</span>
                      </article>
                      <article class="config-command-stat">
                        <p class="config-command-stat-label">enabled</p>
                        <strong class="config-command-stat-value numeric"><%= enabled_pipeline_count(@config_pipelines) %></strong>
                        <span class="config-command-stat-copy">处于启用状态的管线数量</span>
                      </article>
                      <article class="config-command-stat">
                        <p class="config-command-stat-label">draft</p>
                        <strong class="config-command-stat-value"><%= if @workflow_dirty, do: "Dirty", else: "Synced" %></strong>
                        <span class="config-command-stat-copy">当前编辑器是否有未保存改动</span>
                      </article>
                    </div>
                  </div>

                  <div class="config-command-focus">
                    <p class="config-focus-label">selected pipeline</p>
                    <%= if pipeline_editor_target?(@workflow_target) do %>
                      <div class="config-focus-main">
                        <strong><%= @workflow_target.pipeline.id %></strong>
                        <span><%= pipeline_switcher_copy(@workflow_target.pipeline) %></span>
                      </div>
                      <div class="config-focus-signals">
                        <span class="hero-chip">
                          <span class="hero-chip-label">status</span>
                          <span><%= selected_pipeline_status(@payload, @workflow_target) %></span>
                        </span>
                        <span class="hero-chip hero-chip-ghost">
                          <span class="hero-chip-label">running</span>
                          <span class="numeric"><%= selected_pipeline_count(@payload, @workflow_target, :running_agents) %></span>
                        </span>
                        <span class="hero-chip hero-chip-ghost">
                          <span class="hero-chip-label">retrying</span>
                          <span class="numeric"><%= selected_pipeline_count(@payload, @workflow_target, :retrying_agents) %></span>
                        </span>
                        <span class="hero-chip hero-chip-wide">
                          <span class="hero-chip-label">next poll</span>
                          <span class="mono"><%= selected_pipeline_next_poll(@payload, @workflow_target) %></span>
                        </span>
                      </div>
                    <% else %>
                      <div class="config-focus-main">
                        <strong>legacy</strong>
                        <span>当前仍在兼容单 `WORKFLOW.md` 模式。</span>
                      </div>
                    <% end %>
                    <div class="config-command-root">
                      <span class="hero-chip hero-chip-wide">
                        <span class="hero-chip-label">root</span>
                        <span class="mono"><%= @pipeline_root_path %></span>
                      </span>
                    </div>
                  </div>
                </div>
              </section>

              <div class="config-workbench">
                <aside :if={@pipeline_root_available} class="config-pipeline-column">
                  <section class="section-card config-pipeline-catalog">
                    <div class="section-header">
                      <div>
                        <p class="section-kicker">pipelines</p>
                        <h2 class="section-title">托管管线</h2>
                        <p class="section-copy">左侧永远先展示 pipeline 目录。你可以直接看出当前宿主管了几个项目、哪个正在编辑、哪个在线，哪个只是静态落盘。</p>
                      </div>

                      <div class="editor-actions">
                        <button
                          id="open-new-pipeline"
                          type="button"
                          class="secondary"
                          phx-click="open_new_pipeline_form"
                        >
                          + New Pipeline
                        </button>
                      </div>
                    </div>

                    <div :if={@new_pipeline_feedback} class={workflow_feedback_class(@new_pipeline_feedback.kind)}>
                      <strong><%= workflow_feedback_title(@new_pipeline_feedback.kind) %></strong>
                      <span><%= @new_pipeline_feedback.message %></span>
                    </div>

                    <section :if={@new_pipeline_form_open} class="pipeline-creator-shell">
                      <div class="section-header">
                        <div>
                          <p class="section-kicker">create</p>
                          <h3 class="section-title">Create Pipeline</h3>
                          <p class="section-copy">先创建最小可运行配置，后续再补高级项。</p>
                        </div>
                      </div>

                      <form
                        id="pipeline-create-form"
                        class="structured-form"
                        phx-change="new_pipeline_form_changed"
                        phx-submit="create_pipeline"
                      >
                        <div class="pipeline-creator-grid">
                          <label class="structured-field">
                            <span class="structured-label">pipeline id</span>
                            <span class="structured-help">会同时作为目录名，建议使用小写字母、数字、`-` 或 `_`。</span>
                            <input class="structured-input" type="text" name="new_pipeline[id]" value={Map.get(@new_pipeline_form, "id")} />
                          </label>

                          <label class="structured-field">
                            <span class="structured-label">project slug</span>
                            <span class="structured-help">这是这个 pipeline 默认连接的 Linear project slug。</span>
                            <input class="structured-input" type="text" name="new_pipeline[tracker_project_slug]" value={Map.get(@new_pipeline_form, "tracker_project_slug")} />
                          </label>

                          <label class="structured-field">
                            <span class="structured-label">enabled</span>
                            <span class="structured-help">创建后默认启用；取消勾选则只落盘不参与调度。</span>
                            <input type="hidden" name="new_pipeline[enabled]" value="false" />
                            <input type="checkbox" name="new_pipeline[enabled]" value="true" checked={truthy_param?(Map.get(@new_pipeline_form, "enabled"))} />
                          </label>

                          <label class="structured-field">
                            <span class="structured-label">prompt template</span>
                            <span class="structured-help">先放最小 prompt，创建后可在右侧继续补全高级规则。</span>
                            <textarea class="structured-textarea structured-textarea-compact mono" name="new_pipeline[prompt_template]"><%= Map.get(@new_pipeline_form, "prompt_template") %></textarea>
                          </label>

                          <div class="editor-actions editor-actions-outside">
                            <button type="button" class="secondary" phx-click="cancel_new_pipeline_form">
                              Cancel
                            </button>
                            <button type="submit">
                              Create Pipeline
                            </button>
                          </div>
                        </div>
                      </form>
                    </section>

                    <p :if={@config_pipelines == []} class="workflow-empty-note">
                      当前还没有已装载的 pipeline，先创建一个最小配置即可。
                    </p>

                    <div class="pipeline-catalog-list">
                      <button
                        :for={pipeline <- @config_pipelines}
                        id={"config-pipeline-" <> pipeline.id}
                        type="button"
                        class={config_pipeline_button_class(@selected_pipeline_id, pipeline.id)}
                        phx-click="select_config_pipeline"
                        phx-value-pipeline_id={pipeline.id}
                      >
                        <div class="pipeline-card-head">
                          <span class="pipeline-card-kicker"><%= if pipeline.enabled, do: "Enabled", else: "Disabled" %></span>
                          <span class="pipeline-card-status"><%= config_pipeline_status(@payload, pipeline) %></span>
                        </div>
                        <strong class="pipeline-card-title"><%= pipeline.id %></strong>
                        <span class="pipeline-card-copy"><%= pipeline_switcher_copy(pipeline) %></span>
                        <div class="pipeline-card-signals">
                          <span class="pipeline-card-signal">
                            在途 <strong class="numeric"><%= pipeline_payload_count(@payload, pipeline.id, :running_agents) %></strong>
                          </span>
                          <span class="pipeline-card-signal">
                            退避 <strong class="numeric"><%= pipeline_payload_count(@payload, pipeline.id, :retrying_agents) %></strong>
                          </span>
                          <span class="pipeline-card-signal mono">
                            <%= pipeline_payload_next_poll(@payload, pipeline.id) %>
                          </span>
                        </div>
                      </button>
                    </div>
                  </section>
                </aside>

                <section class="section-card section-card-main config-editor-card config-studio-card">
                  <div class="config-studio-head">
                    <div>
                      <p class="section-kicker">editor</p>
                      <h2 class="config-studio-title"><%= workflow_editor_title(@workflow_target, @config_pipelines) %></h2>
                      <p class="config-studio-copy"><%= workflow_editor_copy(@workflow_target) %></p>
                    </div>

                    <div class="config-chip-stack">
                      <%= if pipeline_editor_target?(@workflow_target) do %>
                        <span class="hero-chip">
                          <span class="hero-chip-label">pipeline</span>
                          <span class="mono"><%= @workflow_target.pipeline.id %></span>
                        </span>
                        <span class="hero-chip hero-chip-wide">
                          <span class="hero-chip-label">pipeline.yaml</span>
                          <span class="mono"><%= @workflow_pipeline_config_path %></span>
                        </span>
                        <span class="hero-chip hero-chip-wide">
                          <span class="hero-chip-label">WORKFLOW.md</span>
                          <span class="mono"><%= @workflow_path %></span>
                        </span>
                      <% else %>
                        <span class="hero-chip hero-chip-wide">
                          <span class="hero-chip-label">path</span>
                          <span class="mono"><%= @workflow_path %></span>
                        </span>
                      <% end %>
                      <span :if={@workflow_dirty} class="hero-chip hero-chip-warning">
                        <span class="hero-chip-label">draft</span>
                        <span class="mono">有未保存改动</span>
                      </span>
                    </div>
                  </div>

                  <div class="config-studio-toolbar">
                    <div class="config-tab-row" role="tablist" aria-label="配置视图">
                      <button
                        type="button"
                        class={config_tab_class(@config_view, "structured")}
                        phx-click="switch_config_view"
                        phx-value-view="structured"
                      >
                        结构化
                      </button>
                      <button
                        type="button"
                        class={config_tab_class(@config_view, "yaml")}
                        phx-click="switch_config_view"
                        phx-value-view="yaml"
                      >
                        YAML
                      </button>
                    </div>

                    <form
                      id="workflow-save-form"
                      class="workflow-save-form"
                      phx-submit="save_workflow"
                      phx-hook="WorkflowEditor"
                      data-save-shortcut="meta+s,ctrl+s"
                      data-confirm-message={workflow_confirm_message(@workflow_change_manifest, @workflow_dirty, @workflow_target)}
                    >
                      <input type="hidden" name="workflow[body]" value={@workflow_body} />

                      <div class="editor-actions editor-actions-outside">
                        <button type="button" class="secondary" phx-click="reload_workflow">
                          从磁盘重载
                        </button>
                        <button type="submit" phx-disable-with="保存中…">
                          <%= save_button_label(@workflow_target) %>
                        </button>
                      </div>
                    </form>
                  </div>

                  <div :if={@workflow_feedback} class={workflow_feedback_class(@workflow_feedback.kind)}>
                    <strong><%= workflow_feedback_title(@workflow_feedback.kind) %></strong>
                    <span><%= @workflow_feedback.message %></span>
                  </div>

                  <div class="workflow-meta-grid">
                    <article class="workflow-meta-card">
                      <p class="workflow-meta-label">草稿统计</p>
                      <p class="workflow-meta-value numeric"><%= @workflow_stats.line_count %> 行</p>
                      <p class="workflow-meta-copy">字符 <span class="mono"><%= @workflow_stats.char_count %></span> · YAML <span class="mono"><%= @workflow_stats.yaml_lines %></span> · Prompt <span class="mono"><%= @workflow_stats.prompt_lines %></span></p>
                    </article>

                    <article class="workflow-meta-card workflow-meta-card-manifest">
                      <p class="workflow-meta-label">变更清单</p>
                      <%= if @workflow_change_manifest == [] do %>
                        <p class="workflow-empty-note">当前草稿和已装载配置一致。</p>
                      <% else %>
                        <div class="workflow-change-list">
                          <div :for={item <- @workflow_change_manifest} class="workflow-change-item">
                            <span class="workflow-change-label"><%= item.label %></span>
                            <span class="workflow-change-arrow"><%= item.before %> -> <%= item.after %></span>
                          </div>
                        </div>
                      <% end %>
                    </article>
                  </div>

                  <div class="config-panel-stack">
                  <section class={config_panel_class(@config_view, "structured")} role="tabpanel" aria-label="结构化配置">
                    <div class="structured-toolbar">
                      <div>
                        <p class="section-kicker">structured controls</p>
                        <h2 class="structured-title">结构化字段</h2>
                        <p class="section-copy">优先编辑结构化视图，右侧 YAML 只保留给精细修改和最终核对。</p>
                      </div>
                    </div>

                    <form id="workflow-structured-form" class="structured-form" phx-change="workflow_form_changed">
                      <div class="structured-grid">
                  <section class="structured-card">
                    <div class="structured-card-header">
                      <p class="structured-card-kicker">tracker</p>
                      <h3 class="structured-card-title">追踪器</h3>
                      <p class="structured-card-copy">决定 Symphony 去哪里拉任务、用什么身份访问，以及哪些状态会被视为需要继续编排。</p>
                    </div>

                    <div class="structured-field">
                      <span class="structured-label">kind</span>
                      <span class="structured-help">当前配置区固定使用 Linear 作为任务源；这里展示的是当前生效的 tracker 类型。</span>
                      <input type="hidden" name="workflow_form[tracker_kind]" value="linear" />
                      <div class="structured-choice-row">
                        <button
                          type="button"
                          class={structured_option_class("linear", "linear")}
                        >
                          Linear
                        </button>
                      </div>
                    </div>

                    <label class="structured-field">
                      <span class="structured-label">project slug</span>
                      <span class="structured-help">决定 Symphony 连接哪个 Linear project，并据此拉取和更新 issue。</span>
                      <input class="structured-input" type="text" name="workflow_form[tracker_project_slug]" value={Map.get(@workflow_form, "tracker_project_slug")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">api key</span>
                      <span class="structured-help">优先使用这里的值；留空则回退到环境变量 `LINEAR_API_KEY`。</span>
                      <input class="structured-input" type="text" name="workflow_form[tracker_api_key]" value={Map.get(@workflow_form, "tracker_api_key")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">endpoint</span>
                      <span class="structured-help">Linear GraphQL 接口地址。通常保持默认即可，只有代理或自建转发时才需要改。</span>
                      <input class="structured-input" type="text" name="workflow_form[tracker_endpoint]" value={Map.get(@workflow_form, "tracker_endpoint")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">active states</span>
                      <span class="structured-help">只有这些状态的 issue 会被 orchestrator 持续轮询和调度，使用逗号分隔。</span>
                      <input class="structured-input" type="text" name="workflow_form[tracker_active_states]" value={Map.get(@workflow_form, "tracker_active_states")} />
                      <div class="structured-chip-row">
                        <span :for={value <- state_chip_values(Map.get(@workflow_form, "tracker_active_states"))} class="structured-chip"><%= value %></span>
                      </div>
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">terminal states</span>
                      <span class="structured-help">进入这些状态后，Symphony 会把任务视为终态，不再继续调度，必要时还会清理 workspace。</span>
                      <input class="structured-input" type="text" name="workflow_form[tracker_terminal_states]" value={Map.get(@workflow_form, "tracker_terminal_states")} />
                      <div class="structured-chip-row structured-chip-row-muted">
                        <span :for={value <- state_chip_values(Map.get(@workflow_form, "tracker_terminal_states"))} class="structured-chip structured-chip-muted"><%= value %></span>
                      </div>
                    </label>
                  </section>

                  <section class="structured-card">
                    <div class="structured-card-header">
                      <p class="structured-card-kicker">runtime</p>
                      <h3 class="structured-card-title">调度</h3>
                      <p class="structured-card-copy">控制 orchestrator 轮询节奏、并发上限和失败回退范围，决定系统整体吞吐方式。</p>
                    </div>

                    <label class="structured-field">
                      <span class="structured-label">workspace root</span>
                      <span class="structured-help">每个 issue 对应 workspace 的根目录。agent 的代码操作都会落在这个路径下面。</span>
                      <input class="structured-input" type="text" name="workflow_form[workspace_root]" value={Map.get(@workflow_form, "workspace_root")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">poll interval (ms)</span>
                      <span class="structured-help">控制 orchestrator 轮询 tracker 的频率；值越小越灵敏，但请求和调度开销也更高。</span>
                      <input class="structured-input" type="number" name="workflow_form[polling_interval_ms]" value={Map.get(@workflow_form, "polling_interval_ms")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">max concurrent agents</span>
                      <span class="structured-help">限制同一时间最多能并行运行多少个 agent，用来控制整体资源占用。</span>
                      <input class="structured-input" type="number" name="workflow_form[agent_max_concurrent_agents]" value={Map.get(@workflow_form, "agent_max_concurrent_agents")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">max turns</span>
                      <span class="structured-help">限制单个 issue 在一次连续运行里最多能推进多少个 turn，避免长任务无限占用会话。</span>
                      <input class="structured-input" type="number" name="workflow_form[agent_max_turns]" value={Map.get(@workflow_form, "agent_max_turns")} />
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">max retry backoff (ms)</span>
                      <span class="structured-help">设置失败重试的最大退避上限，避免错误任务在异常情况下退得过慢或无限拉长。</span>
                      <input class="structured-input" type="number" name="workflow_form[agent_max_retry_backoff_ms]" value={Map.get(@workflow_form, "agent_max_retry_backoff_ms")} />
                    </label>
                  </section>

                  <section class="structured-card">
                    <div class="structured-card-header">
                      <p class="structured-card-kicker">codex</p>
                      <h3 class="structured-card-title">执行器</h3>
                      <p class="structured-card-copy">决定每次会话如何启动 Codex、给它什么权限，以及多久才算真正卡住。</p>
                    </div>

                    <label class="structured-field">
                      <span class="structured-label">command</span>
                      <span class="structured-help">实际启动 Codex app-server 的命令行。模型、配置项和运行参数都在这里决定。</span>
                      <textarea class="structured-textarea structured-textarea-compact mono" name="workflow_form[codex_command]"><%= Map.get(@workflow_form, "codex_command") %></textarea>
                    </label>

                    <div class="structured-field">
                      <span class="structured-label">thread sandbox</span>
                      <span class="structured-help">决定整条会话线程默认拥有哪些文件系统权限；权限越高，自主性越强，风险也越高。</span>
                      <div class="structured-choice-row structured-choice-row-stack">
                        <button
                          type="button"
                          class={structured_option_class(Map.get(@workflow_form, "codex_thread_sandbox"), "read-only")}
                          phx-click="workflow_form_preset"
                          phx-value-field="codex_thread_sandbox"
                          phx-value-value="read-only"
                        >
                          Read Only
                        </button>
                        <button
                          type="button"
                          class={structured_option_class(Map.get(@workflow_form, "codex_thread_sandbox"), "workspace-write")}
                          phx-click="workflow_form_preset"
                          phx-value-field="codex_thread_sandbox"
                          phx-value-value="workspace-write"
                        >
                          Workspace Write
                        </button>
                        <button
                          type="button"
                          class={structured_option_class(Map.get(@workflow_form, "codex_thread_sandbox"), "danger-full-access")}
                          phx-click="workflow_form_preset"
                          phx-value-field="codex_thread_sandbox"
                          phx-value-value="danger-full-access"
                        >
                          Danger Full Access
                        </button>
                      </div>
                    </div>

                    <label class="structured-field">
                      <span class="structured-label">stall timeout (ms)</span>
                      <span class="structured-help">如果会话长时间没有新进展，会被判定为 stalled 并交还给 orchestrator 处理。</span>
                      <input class="structured-input" type="number" name="workflow_form[codex_stall_timeout_ms]" value={Map.get(@workflow_form, "codex_stall_timeout_ms")} />
                    </label>
                  </section>

                  <section class="structured-card structured-card-hooks">
                    <div class="structured-card-header">
                      <p class="structured-card-kicker">hooks</p>
                      <h3 class="structured-card-title">Hooks</h3>
                      <p class="structured-card-copy">这几步是 Symphony 在 workspace 生命周期里自动执行的脚本节点，适合放仓库初始化、验证和清理动作。</p>
                    </div>

                    <label class="structured-field">
                      <span class="structured-label">after create</span>
                      <span class="structured-help">创建 workspace 后立刻执行。常用于 `git clone`、安装依赖、准备基础环境。</span>
                      <textarea class="structured-textarea structured-textarea-hook mono" name="workflow_form[hooks_after_create]"><%= Map.get(@workflow_form, "hooks_after_create") %></textarea>
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">before run</span>
                      <span class="structured-help">每次 agent 真正开始跑任务前执行。适合做轻量同步、预检查或生成上下文文件。</span>
                      <textarea class="structured-textarea structured-textarea-compact mono" name="workflow_form[hooks_before_run]"><%= Map.get(@workflow_form, "hooks_before_run") %></textarea>
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">after run</span>
                      <span class="structured-help">一次任务运行结束后执行。适合收尾验证、补充产物或导出报告。</span>
                      <textarea class="structured-textarea structured-textarea-compact mono" name="workflow_form[hooks_after_run]"><%= Map.get(@workflow_form, "hooks_after_run") %></textarea>
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">before remove</span>
                      <span class="structured-help">workspace 被删除前执行。适合做清理、归档或临时文件回收。</span>
                      <textarea class="structured-textarea structured-textarea-compact mono" name="workflow_form[hooks_before_remove]"><%= Map.get(@workflow_form, "hooks_before_remove") %></textarea>
                    </label>

                    <label class="structured-field">
                      <span class="structured-label">hook timeout (ms)</span>
                      <span class="structured-help">限制单个 hook 最长运行时间，避免安装或脚本卡住整个编排流程。</span>
                      <input class="structured-input" type="number" name="workflow_form[hooks_timeout_ms]" value={Map.get(@workflow_form, "hooks_timeout_ms")} />
                    </label>
                  </section>

                  <section class="structured-card structured-card-prompt">
                    <div class="structured-card-header">
                      <p class="structured-card-kicker">prompt</p>
                      <h3 class="structured-card-title">任务模版</h3>
                      <p class="structured-card-copy">这是发给每个任务 agent 的核心执行说明，会和 issue 上下文一起组成实际 prompt。</p>
                    </div>

                    <label class="structured-field">
                      <span class="structured-label">prompt template</span>
                      <span class="structured-help">定义 agent 的默认工作方式、状态流转要求和项目规则。这里的改动会直接影响后续新任务的行为。</span>
                      <textarea class="structured-textarea mono" name="workflow_form[prompt_template]"><%= Map.get(@workflow_form, "prompt_template") %></textarea>
                    </label>
                  </section>
                      </div>
                    </form>
                  </section>

                  <section class={config_panel_class(@config_view, "yaml")} role="tabpanel" aria-label="YAML 配置">
                    <form
                      id="workflow-editor-form"
                      class="workflow-form"
                      phx-change="workflow_changed"
                      phx-submit="save_workflow"
                    >
                      <textarea
                        id="workflow-editor"
                        name="workflow[body]"
                        class="workflow-editor mono"
                        spellcheck="false"
                        autocapitalize="off"
                        autocomplete="off"
                        autocorrect="off"
                      ><%= @workflow_body %></textarea>
                    </form>
                  </section>
                </div>
                </section>

                <aside class="config-support-grid">
                  <section class="section-card">
                    <div class="section-header">
                      <div>
                        <p class="section-kicker">runtime</p>
                        <h2 class="section-title"><%= workflow_summary_title(@workflow_target) %></h2>
                        <p class="section-copy"><%= workflow_summary_copy(@workflow_target) %></p>
                      </div>
                    </div>

                    <div class="config-summary-list">
                      <article :for={entry <- @workflow_summary} class="config-summary-item">
                        <p class="config-summary-label"><%= entry.label %></p>
                        <p class="config-summary-value mono"><%= entry.value %></p>
                      </article>
                    </div>
                  </section>

                  <section class="section-card">
                    <div class="section-header">
                      <div>
                        <p class="section-kicker">notes</p>
                        <h2 class="section-title">编辑约束</h2>
                        <p class="section-copy"><%= workflow_notes_copy(@workflow_target) %></p>
                      </div>
                    </div>

                    <div class="code-panel">
                      <pre><%= workflow_notes_text(@workflow_target) %></pre>
                    </div>
                  </section>
                </aside>
              </div>
            </section>
          <% else %>
            <%= if @panel == "logs" do %>
              <section class="section-card section-card-main">
                <div class="section-header">
                  <div>
                    <p class="section-kicker">logs</p>
                    <h2 class="section-title">日志区</h2>
                    <p class="section-copy">读取当前 Symphony 磁盘日志的尾部输出，方便单独查看系统最近行为，而不是混在观测卡片里。</p>
                  </div>
                </div>

                <div class="log-meta">
                  <span class="hero-chip hero-chip-wide">
                    <span class="hero-chip-label">path</span>
                    <span class="mono"><%= @payload.logs.path %></span>
                  </span>
                </div>
                <p :if={Map.get(@payload.logs, :source_paths, []) != []} class="log-note">
                  读取来源:
                  <span class="mono"><%= Enum.join(@payload.logs.source_paths, ", ") %></span>
                </p>

                <%= if @payload.logs.available and @payload.logs.lines != [] do %>
                  <div class="log-panel">
                    <pre class="log-panel-pre mono"><%= Enum.join(@payload.logs.lines, "\n") %></pre>
                  </div>
                  <p :if={@payload.logs.truncated} class="log-note">仅展示最近一段日志内容。</p>
                <% else %>
                  <p class="empty-state">当前日志文件还没有可展示内容。</p>
                <% end %>
              </section>
            <% else %>
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

              <section :if={multi_pipeline_payload?(@payload)} class="section-card">
                <div class="section-header">
                  <div>
                    <p class="section-kicker">pipelines</p>
                    <h2 class="section-title">托管管线</h2>
                    <p class="section-copy">每条 pipeline 独立轮询、独立退避、独立 workspace；这里汇总当前宿主上的在线状态。</p>
                  </div>
                </div>

                <div class="limit-grid">
                  <article :for={pipeline <- @payload.pipelines} class="limit-card">
                    <p class="limit-label"><%= pipeline.id %></p>
                    <p class="limit-value"><%= dashboard_pipeline_status(pipeline) %></p>
                    <p class="limit-copy">
                      在途 <span class="numeric"><%= pipeline.running_agents %></span> ·
                      退避 <span class="numeric"><%= pipeline.retrying_agents %></span> ·
                      下次轮询 <span class="mono"><%= pipeline_next_poll(pipeline) %></span>
                    </p>
                    <a :if={pipeline.project_url} class="issue-link" href={pipeline.project_url} target="_blank" rel="noreferrer">
                      打开 Linear
                    </a>
                  </article>
                </div>
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
                                <span :if={entry[:pipeline_id]} class="muted mono"><%= entry.pipeline_id %></span>
                                <span class="issue-id"><%= entry.issue_identifier %></span>
                                <a :if={!entry[:pipeline_id]} class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>查看 JSON</a>
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
                                  <span :if={entry[:pipeline_id]} class="muted mono"><%= entry.pipeline_id %></span>
                                  <span class="issue-id"><%= entry.issue_identifier %></span>
                                  <a :if={!entry[:pipeline_id]} class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>查看 JSON</a>
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
            <% end %>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  defp load_payload do
    pipelines = pipelines_catalog()

    if multi_pipeline_catalog?(pipelines) do
      Presenter.dashboard_payload(pipelines, &orchestrator_for_pipeline/1, snapshot_timeout_ms())
    else
      Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp orchestrator_for_pipeline(pipeline_id) when is_binary(pipeline_id) do
    endpoint_orchestrators = Endpoint.config(:pipeline_orchestrators)

    if is_map(endpoint_orchestrators) and Map.has_key?(endpoint_orchestrators, pipeline_id) do
      Map.get(endpoint_orchestrators, pipeline_id)
    else
      case PipelineSupervisor.lookup(pipeline_id, pipeline_registry_name()) do
        {:ok, pid} -> pid
        :error -> fallback_orchestrator_for_pipeline(pipeline_id)
      end
    end
  end

  defp fallback_orchestrator_for_pipeline("default"), do: orchestrator()
  defp fallback_orchestrator_for_pipeline(_pipeline_id), do: nil

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

  defp format_runtime_and_turns(started_at, turn_count, now)
       when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}轮"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)

    if mins > 0, do: "#{mins}分 #{secs}秒", else: "#{secs}秒"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now)
       when is_binary(started_at) do
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
    state
    |> to_string()
    |> String.trim()
    |> normalize_display_value(@state_labels)
  end

  defp display_event_name(nil), do: "未返回"

  defp display_event_name(event) do
    event
    |> to_string()
    |> normalize_display_value(@event_labels)
  end

  defp display_last_message(message) when is_binary(message),
    do: localize_dashboard_message(message)

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
        acc == prefix ->
          {:halt, replacement}

        String.starts_with?(acc, prefix) ->
          {:halt, replacement <> String.replace_prefix(acc, prefix, "")}

        true ->
          {:cont, acc}
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

  defp refresh_log_payload(socket) do
    payload = Map.put(socket.assigns.payload, :logs, Presenter.logs_payload())
    assign(socket, :payload, payload)
  end

  defp rate_limit_identity(rate_limits) do
    [
      rate_limit_value(rate_limits, [:limit_name]),
      rate_limit_value(rate_limits, [:limit_id]),
      rate_limit_value(rate_limits, [:plan_type, :planType])
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      [] -> "未返回"
      values -> Enum.join(values, " / ")
    end
  end

  defp primary_limit_bucket(rate_limits), do: rate_limit_value(rate_limits, :primary)
  defp secondary_limit_bucket(rate_limits), do: rate_limit_value(rate_limits, :secondary)

  defp primary_limit_used(rate_limits),
    do: rate_limit_value(primary_limit_bucket(rate_limits), [:used_percent, :usedPercent])

  defp secondary_limit_used(rate_limits),
    do: rate_limit_value(secondary_limit_bucket(rate_limits), [:used_percent, :usedPercent])

  defp format_percent(value) when is_integer(value), do: "#{value}%"

  defp format_percent(value) when is_float(value),
    do: "#{:erlang.float_to_binary(value, decimals: 0)}%"

  defp format_percent(_value), do: "未返回"

  defp format_rate_window(bucket) when is_map(bucket) do
    window =
      bucket
      |> rate_limit_value([:window_minutes, :windowDurationMins])
      |> humanize_window_minutes()

    reset_at = bucket |> rate_limit_value([:resets_at, :resetsAt]) |> display_timestamp()
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

  defp format_credits(%{} = credits) do
    unlimited = rate_limit_value(credits, [:unlimited]) == true
    has_credits = rate_limit_value(credits, [:has_credits, :hasCredits]) == true
    balance = rate_limit_value(credits, [:balance])

    cond do
      unlimited -> "无限"
      has_credits and is_number(balance) -> format_credits(balance)
      has_credits -> "可用"
      true -> "无"
    end
  end

  defp format_credits(value) when is_integer(value), do: format_int(value)
  defp format_credits(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_credits(value) when is_binary(value), do: value
  defp format_credits(value), do: to_string(value)

  defp rate_limit_value(nil, _key), do: nil

  defp rate_limit_value(rate_limits, keys) when is_map(rate_limits) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(rate_limits, key) or Map.has_key?(rate_limits, Atom.to_string(key)) do
        {:halt, rate_limit_value(rate_limits, key)}
      else
        {:cont, nil}
      end
    end)
  end

  defp rate_limit_value(rate_limits, key) when is_map(rate_limits) do
    Map.get(rate_limits, key) || Map.get(rate_limits, Atom.to_string(key))
  end

  defp project_url do
    case Config.linear_project_slug() do
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
      String.contains?(normalized, ["progress", "running", "active"]) ->
        "#{base} state-badge-active"

      String.contains?(normalized, ["blocked", "error", "failed"]) ->
        "#{base} state-badge-danger"

      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) ->
        "#{base} state-badge-warning"

      true ->
        base
    end
  end

  defp control_nav_link_class(active_panel, panel) do
    base = "control-nav-link"
    if active_panel == panel, do: "#{base} control-nav-link-active", else: base
  end

  defp config_tab_class(active_view, view) do
    base = "config-tab"
    if active_view == view, do: "#{base} config-tab-active", else: base
  end

  defp config_panel_class(active_view, view) do
    base = "config-panel"
    if active_view == view, do: base, else: "#{base} config-panel-hidden"
  end

  defp normalize_panel(panel) when panel in ["observability", "config", "logs"], do: panel
  defp normalize_panel(_panel), do: "observability"

  defp normalize_config_view(view) when view in ["structured", "yaml"], do: view
  defp normalize_config_view(_view), do: "structured"

  defp panel_path("config"), do: "/panel/config"
  defp panel_path("logs"), do: "/panel/logs"
  defp panel_path(_panel), do: "/"

  defp panel_mode_label("config"), do: "workflow editing"
  defp panel_mode_label("logs"), do: "log tail"
  defp panel_mode_label(_panel), do: "live monitoring"

  defp workflow_feedback_class(kind) do
    base = "workflow-feedback"

    case kind do
      :ok -> "#{base} workflow-feedback-ok"
      :info -> "#{base} workflow-feedback-info"
      :error -> "#{base} workflow-feedback-error"
      _ -> base
    end
  end

  defp workflow_feedback_title(:ok), do: "已应用"
  defp workflow_feedback_title(:info), do: "已同步"
  defp workflow_feedback_title(:error), do: "保存失败"
  defp workflow_feedback_title(_kind), do: "状态"

  defp pipelines_catalog do
    case Endpoint.config(:pipelines) do
      pipelines when is_list(pipelines) and pipelines != [] ->
        pipelines

      _ ->
        configured_pipelines()
    end
  end

  defp configured_pipelines do
    pipeline_root_path = Workflow.pipeline_root_path()

    if File.dir?(pipeline_root_path) do
      case PipelineLoader.load_pipeline_root(pipeline_root_path) do
        {:ok, pipelines} -> pipelines
        {:error, _reason} -> compatibility_pipelines()
      end
    else
      compatibility_pipelines()
    end
  end

  defp compatibility_pipelines do
    case Config.current_pipeline() do
      {:ok, pipeline} -> [pipeline]
      {:error, _reason} -> []
    end
  end

  defp multi_pipeline_catalog?(pipelines) when is_list(pipelines) do
    pipelines
    |> Enum.filter(&match?(%Pipeline{enabled: true}, &1))
    |> length()
    |> Kernel.>(1)
  end

  defp multi_pipeline_catalog?(_pipelines), do: false

  defp multi_pipeline_payload?(payload) when is_map(payload) do
    case Map.get(payload, :pipelines) do
      pipelines when is_list(pipelines) -> length(pipelines) > 1
      _ -> false
    end
  end

  defp multi_pipeline_payload?(_payload), do: false

  defp payload_pipeline_count(payload) when is_map(payload) do
    payload
    |> Map.get(:pipelines, [])
    |> Enum.count()
  end

  defp payload_pipeline_count(_payload), do: 0

  defp dashboard_pipeline_status(pipeline) when is_map(pipeline) do
    cond do
      pipeline.available != true -> "离线"
      pipeline.paused == true -> "暂停中"
      true -> "运行中"
    end
  end

  defp dashboard_pipeline_status(_pipeline), do: "未知"

  defp pipeline_next_poll(%{paused: true}), do: "paused"

  defp pipeline_next_poll(%{polling: %{checking: true}}), do: "checking"

  defp pipeline_next_poll(%{polling: %{next_poll_in_ms: due_in_ms}})
       when is_integer(due_in_ms) and due_in_ms >= 0 do
    seconds = div(due_in_ms + 999, 1000)
    "#{seconds}s"
  end

  defp pipeline_next_poll(_pipeline), do: "n/a"

  defp pipeline_registry_name do
    Endpoint.config(:pipeline_registry_name) || SymphonyElixir.PipelineRegistry
  end

  defp workflow_editor_catalog do
    pipeline_root_path = Workflow.pipeline_root_path()

    if File.dir?(pipeline_root_path) do
      case PipelineLoader.load_pipeline_root(pipeline_root_path) do
        {:ok, [_ | _] = pipelines} -> {:pipeline, pipelines}
        _ -> {:legacy, []}
      end
    else
      {:legacy, []}
    end
  end

  defp selected_editor_pipeline_id(selected_pipeline_id, pipelines) when is_list(pipelines) do
    case Enum.find(pipelines, &(&1.id == selected_pipeline_id)) do
      %Pipeline{id: pipeline_id} ->
        pipeline_id

      nil ->
        case preferred_editor_pipeline(pipelines) do
          %Pipeline{id: pipeline_id} -> pipeline_id
          _ -> nil
        end
    end
  end

  defp preferred_editor_pipeline(pipelines) when is_list(pipelines) do
    Enum.find(pipelines, & &1.enabled) || List.first(pipelines)
  end

  defp workflow_target(:pipeline, pipelines, selected_pipeline_id) when is_list(pipelines) do
    pipeline =
      Enum.find(pipelines, fn
        %Pipeline{id: pipeline_id} -> pipeline_id == selected_pipeline_id
        _ -> false
      end) || List.first(pipelines)

    %{
      mode: :pipeline,
      pipeline: pipeline,
      pipeline_config_path: pipeline_config_path(pipeline),
      workflow_path: workflow_target_path(pipeline)
    }
  end

  defp workflow_target(_editor_mode, _pipelines, _selected_pipeline_id) do
    %{
      mode: :legacy,
      pipeline: nil,
      pipeline_config_path: nil,
      workflow_path: Workflow.workflow_file_path()
    }
  end

  defp assign_workflow_editor(socket, opts \\ []) do
    feedback = Keyword.get(opts, :feedback)
    {editor_mode, pipelines} = workflow_editor_catalog()
    pipeline_root_path = Workflow.pipeline_root_path()
    selected_pipeline_id = selected_editor_pipeline_id(socket.assigns[:selected_pipeline_id], pipelines)
    target = workflow_target(editor_mode, pipelines, selected_pipeline_id)

    socket =
      socket
      |> assign(:pipeline_root_path, pipeline_root_path)
      |> assign(:pipeline_root_available, File.dir?(pipeline_root_path))
      |> assign(:config_pipelines, if(editor_mode == :pipeline, do: pipelines, else: []))
      |> assign(:selected_pipeline_id, selected_pipeline_id)
      |> assign(:workflow_target, target)
      |> assign(:workflow_path, target.workflow_path)
      |> assign(:workflow_pipeline_config_path, target.pipeline_config_path)

    case load_workflow_editor_content(target) do
      {:ok, content, parsed_workflow} ->
        socket
        |> assign(:workflow_persisted_body, content)
        |> assign(:workflow_body, content)
        |> assign(:workflow_dirty, false)
        |> assign(:workflow_feedback, feedback)
        |> assign(:workflow_loaded, parsed_workflow)
        |> assign(:workflow_loaded_form, workflow_form_from_loaded(parsed_workflow))
        |> assign(:workflow_form, workflow_form_from_loaded(parsed_workflow))
        |> assign(:workflow_summary, workflow_summary(target, parsed_workflow))
        |> assign_workflow_insights()

      {:error, reason} ->
        socket
        |> assign(:workflow_persisted_body, "")
        |> assign(:workflow_body, "")
        |> assign(:workflow_dirty, false)
        |> assign(
          :workflow_feedback,
          feedback || %{kind: :error, message: format_workflow_reason(reason, target)}
        )
        |> assign(:workflow_loaded, nil)
        |> assign(:workflow_loaded_form, workflow_form_defaults())
        |> assign(:workflow_form, workflow_form_defaults())
        |> assign(:workflow_summary, workflow_summary(target, nil))
        |> assign_workflow_insights()
    end
  end

  defp load_workflow_editor_content(%{mode: :pipeline, pipeline: %Pipeline{} = pipeline, workflow_path: workflow_path}) do
    with {:ok, workflow} <- Workflow.load(workflow_path) do
      content = Workflow.render_content(pipeline_editor_config(pipeline), workflow.prompt_template)
      {:ok, content, parse_workflow_body(content)}
    end
  end

  defp load_workflow_editor_content(%{workflow_path: workflow_path}) do
    with {:ok, content} <- Workflow.raw_content(workflow_path) do
      {:ok, content, parse_workflow_body(content)}
    end
  end

  defp pipeline_config_path(%Pipeline{source_path: source_path}) when is_binary(source_path) do
    Path.join(source_path, "pipeline.yaml")
  end

  defp pipeline_config_path(_pipeline), do: nil

  defp workflow_target_path(%Pipeline{workflow_path: workflow_path}) when is_binary(workflow_path),
    do: workflow_path

  defp workflow_target_path(_pipeline), do: Workflow.workflow_file_path()

  defp maybe_sync_workflow_form_from_body(socket, body) when is_binary(body) do
    case Workflow.parse_content(body) do
      {:ok, parsed_workflow} ->
        socket
        |> assign(:workflow_loaded, parsed_workflow)
        |> assign(:workflow_form, workflow_form_from_loaded(parsed_workflow))
        |> assign_workflow_insights()

      {:error, _reason} ->
        socket
        |> assign_workflow_insights()
    end
  end

  defp parse_workflow_body(body) when is_binary(body) do
    case Workflow.parse_content(body) do
      {:ok, parsed_workflow} -> parsed_workflow
      {:error, _reason} -> nil
    end
  end

  defp resolve_workflow_save_body(socket, submitted_body) when is_binary(submitted_body) do
    persisted_body = socket.assigns[:workflow_persisted_body] || ""
    draft_body = socket.assigns[:workflow_body] || submitted_body

    cond do
      submitted_body != persisted_body -> submitted_body
      draft_body != persisted_body -> draft_body
      true -> submitted_body
    end
  end

  defp save_workflow_body(%{mode: :pipeline} = target, body) when is_binary(body) do
    with {:ok, %{config: config, prompt_template: prompt_template}} <- Workflow.parse_content(body),
         :ok <- validate_editor_tracker_kind(config),
         :ok <- File.write(target.pipeline_config_path, render_pipeline_config_yaml(target.pipeline, config)),
         :ok <- File.write(target.workflow_path, prompt_file_content(prompt_template)) do
      StatusDashboard.notify_update()
      :ok
    end
  end

  defp save_workflow_body(_target, body) when is_binary(body) do
    case Workflow.parse_content(body) do
      {:ok, %{config: config}} ->
        with :ok <- validate_editor_tracker_kind(config),
             :ok <- Workflow.save(body) do
          StatusDashboard.notify_update()
          :ok
        end

      _ ->
        with :ok <- Workflow.save(body) do
          StatusDashboard.notify_update()
          :ok
        end
    end
  end

  defp workflow_summary(%{mode: :pipeline, pipeline: %Pipeline{} = pipeline}, %{config: config})
       when is_map(config) do
    [
      %{label: "pipeline.id", value: summary_value(pipeline.id)},
      %{label: "pipeline.enabled", value: summary_value(pipeline.enabled)},
      %{label: "tracker.project_slug", value: summary_value(get_in(config, ["tracker", "project_slug"]))},
      %{label: "workspace.root", value: summary_value(get_in(config, ["workspace", "root"]))},
      %{label: "codex.command", value: summary_value(get_in(config, ["codex", "command"]))}
    ]
  end

  defp workflow_summary(_target, %{config: config}) when is_map(config) do
    [
      %{label: "tracker.kind", value: summary_value(get_in(config, ["tracker", "kind"]))},
      %{label: "tracker.project_slug", value: summary_value(get_in(config, ["tracker", "project_slug"]))},
      %{label: "workspace.root", value: summary_value(get_in(config, ["workspace", "root"]))},
      %{label: "codex.command", value: summary_value(get_in(config, ["codex", "command"]))}
    ]
  end

  defp workflow_summary(%{mode: :pipeline, pipeline: %Pipeline{} = pipeline} = target, nil) do
    [
      %{label: "pipeline.id", value: summary_value(pipeline.id)},
      %{label: "status", value: "未能读取当前 pipeline 配置"},
      %{label: "reason", value: format_workflow_reason(:missing_pipeline_editor_content, target)}
    ]
  end

  defp workflow_summary(target, nil) do
    [
      %{label: "status", value: "未能读取当前配置"},
      %{label: "reason", value: format_workflow_reason(:missing_pipeline_editor_content, target)}
    ]
  end

  defp summary_value(nil), do: "未设置"
  defp summary_value(""), do: "未设置"
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(value), do: inspect(value, pretty: false, limit: 4)

  defp workflow_form_from_loaded(nil), do: workflow_form_defaults()

  defp workflow_form_from_loaded(%{config: config, prompt_template: prompt_template}) do
    config
    |> tracker_workflow_form()
    |> Map.merge(runtime_workflow_form(config))
    |> Map.merge(codex_workflow_form(config))
    |> Map.merge(hooks_workflow_form(config))
    |> Map.put("prompt_template", prompt_template)
  end

  defp workflow_form_defaults do
    %{
      "tracker_kind" => "",
      "tracker_project_slug" => "",
      "tracker_api_key" => "",
      "tracker_endpoint" => "",
      "tracker_active_states" => "",
      "tracker_terminal_states" => "",
      "workspace_root" => "",
      "polling_interval_ms" => "",
      "agent_max_concurrent_agents" => "",
      "agent_max_turns" => "",
      "agent_max_retry_backoff_ms" => "",
      "codex_command" => "",
      "codex_thread_sandbox" => "",
      "codex_stall_timeout_ms" => "",
      "hooks_after_create" => "",
      "hooks_before_run" => "",
      "hooks_after_run" => "",
      "hooks_before_remove" => "",
      "hooks_timeout_ms" => "",
      "prompt_template" => ""
    }
  end

  defp assign_workflow_insights(socket) do
    body = socket.assigns[:workflow_body] || ""
    loaded_form = socket.assigns[:workflow_loaded_form] || workflow_form_defaults()
    workflow_form = socket.assigns[:workflow_form] || workflow_form_defaults()

    socket
    |> assign(:workflow_stats, workflow_stats(body))
    |> assign(:workflow_change_manifest, workflow_change_manifest(loaded_form, workflow_form))
  end

  defp build_workflow_body(workflow_loaded, workflow_form) do
    base_config =
      case workflow_loaded do
        %{config: config} when is_map(config) -> config
        _ -> %{}
      end

    config =
      base_config
      |> put_nested(["tracker", "kind"], blank_to_nil(workflow_form["tracker_kind"]))
      |> put_nested(
        ["tracker", "project_slug"],
        blank_to_nil(workflow_form["tracker_project_slug"])
      )
      |> put_nested(["tracker", "api_key"], blank_to_nil(workflow_form["tracker_api_key"]))
      |> put_nested(["tracker", "endpoint"], blank_to_nil(workflow_form["tracker_endpoint"]))
      |> put_nested(
        ["tracker", "active_states"],
        csv_to_list(workflow_form["tracker_active_states"])
      )
      |> put_nested(
        ["tracker", "terminal_states"],
        csv_to_list(workflow_form["tracker_terminal_states"])
      )
      |> put_nested(["workspace", "root"], blank_to_nil(workflow_form["workspace_root"]))
      |> put_nested(
        ["polling", "interval_ms"],
        integer_or_nil(workflow_form["polling_interval_ms"])
      )
      |> put_nested(
        ["agent", "max_concurrent_agents"],
        integer_or_nil(workflow_form["agent_max_concurrent_agents"])
      )
      |> put_nested(["agent", "max_turns"], integer_or_nil(workflow_form["agent_max_turns"]))
      |> put_nested(
        ["agent", "max_retry_backoff_ms"],
        integer_or_nil(workflow_form["agent_max_retry_backoff_ms"])
      )
      |> put_nested(["codex", "command"], blank_to_nil(workflow_form["codex_command"]))
      |> put_nested(
        ["codex", "thread_sandbox"],
        blank_to_nil(workflow_form["codex_thread_sandbox"])
      )
      |> put_nested(
        ["codex", "stall_timeout_ms"],
        integer_or_nil(workflow_form["codex_stall_timeout_ms"])
      )
      |> put_nested(["hooks", "after_create"], blank_to_nil(workflow_form["hooks_after_create"]))
      |> put_nested(["hooks", "before_run"], blank_to_nil(workflow_form["hooks_before_run"]))
      |> put_nested(["hooks", "after_run"], blank_to_nil(workflow_form["hooks_after_run"]))
      |> put_nested(
        ["hooks", "before_remove"],
        blank_to_nil(workflow_form["hooks_before_remove"])
      )
      |> put_nested(["hooks", "timeout_ms"], integer_or_nil(workflow_form["hooks_timeout_ms"]))

    Workflow.render_content(config, workflow_form["prompt_template"] || "")
  end

  defp put_nested(map, [key], value) when is_map(map) do
    put_or_delete(map, key, value)
  end

  defp put_nested(map, [key | rest], value) when is_map(map) do
    nested = Map.get(map, key)
    normalized_nested = if is_map(nested), do: nested, else: %{}
    updated_nested = put_nested(normalized_nested, rest, value)
    put_or_delete(map, key, updated_nested)
  end

  defp put_or_delete(map, key, value) when value in [nil, %{}], do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp csv_to_list(nil), do: nil

  defp csv_to_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      values -> values
    end
  end

  defp joined_state_list(values) when is_list(values), do: Enum.join(values, ", ")
  defp joined_state_list(_values), do: ""

  defp integer_string(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_string(_value), do: ""

  defp workflow_stats(body) when is_binary(body) do
    lines = String.split(body, "\n", trim: false)
    yaml_lines = yaml_line_count(lines)
    prompt_lines = max(length(lines) - yaml_lines - 2, 0)

    %{
      line_count: length(lines),
      char_count: String.length(body),
      yaml_lines: yaml_lines,
      prompt_lines: prompt_lines
    }
  end

  defp yaml_line_count(["---" | rest]) do
    rest
    |> Enum.split_while(&(&1 != "---"))
    |> elem(0)
    |> length()
  end

  defp yaml_line_count(_lines), do: 0

  defp pipeline_editor_config(%Pipeline{} = pipeline) do
    %{
      "id" => pipeline.id,
      "enabled" => pipeline.enabled,
      "tracker" => plain_config_value(pipeline.tracker),
      "polling" => plain_config_value(pipeline.polling),
      "workspace" => plain_config_value(pipeline.workspace),
      "agent" => plain_config_value(pipeline.agent),
      "codex" => plain_config_value(pipeline.codex),
      "hooks" => plain_config_value(pipeline.hooks),
      "observability" => plain_config_value(pipeline.observability),
      "server" => plain_config_value(pipeline.server)
    }
  end

  defp plain_config_value(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> plain_config_value()
  end

  defp plain_config_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      Map.put(acc, to_string(key), plain_config_value(nested))
    end)
  end

  defp plain_config_value(value) when is_list(value), do: Enum.map(value, &plain_config_value/1)
  defp plain_config_value(value), do: value

  defp validate_editor_tracker_kind(config) when is_map(config) do
    if get_in(config, ["tracker", "kind"]) == "memory" do
      {:error, :unsupported_memory_tracker_kind}
    else
      :ok
    end
  end

  defp render_pipeline_config_yaml(%Pipeline{} = pipeline, config) when is_map(config) do
    config
    |> Map.put("id", pipeline.id)
    |> Map.put("enabled", pipeline.enabled)
    |> Workflow.render_content("")
    |> extract_front_matter_yaml()
  end

  defp extract_front_matter_yaml(rendered_body) when is_binary(rendered_body) do
    case String.split(rendered_body, ~r/\R/u, trim: false) do
      ["---" | rest] ->
        rest
        |> Enum.split_while(&(&1 != "---"))
        |> elem(0)
        |> Enum.join("\n")
        |> String.trim_trailing()
        |> Kernel.<>("\n")

      _ ->
        ""
    end
  end

  defp prompt_file_content(prompt_template) when is_binary(prompt_template) do
    prompt_template
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp new_pipeline_form_defaults do
    %{
      "id" => "",
      "tracker_project_slug" => "",
      "prompt_template" => "",
      "enabled" => "true"
    }
  end

  defp merge_new_pipeline_form(params) when is_map(params) do
    Map.merge(new_pipeline_form_defaults(), Map.take(params, Map.keys(new_pipeline_form_defaults())))
  end

  defp merge_new_pipeline_form(_params), do: new_pipeline_form_defaults()

  defp truthy_param?(value) when value in [true, "true", "on", "1"], do: true
  defp truthy_param?(_value), do: false

  defp scaffold_pipeline(pipeline_root_path, form) when is_binary(pipeline_root_path) and is_map(form) do
    with :ok <- validate_pipeline_root_path(pipeline_root_path),
         {:ok, attrs} <- normalize_new_pipeline_attrs(form),
         pipeline_dir = Path.join(pipeline_root_path, attrs.id),
         :ok <- validate_new_pipeline_dir(pipeline_dir),
         config = new_pipeline_config(attrs),
         rendered_body = Workflow.render_content(config, attrs.prompt_template),
         :ok <- File.mkdir_p(pipeline_dir),
         :ok <-
           File.write(
             Path.join(pipeline_dir, "pipeline.yaml"),
             extract_front_matter_yaml(rendered_body)
           ),
         :ok <- File.write(Path.join(pipeline_dir, "WORKFLOW.md"), prompt_file_content(attrs.prompt_template)) do
      StatusDashboard.notify_update()
      {:ok, attrs.id}
    end
  end

  defp validate_pipeline_root_path(pipeline_root_path) when is_binary(pipeline_root_path) do
    if File.dir?(pipeline_root_path) do
      :ok
    else
      {:error, :pipeline_root_unavailable}
    end
  end

  defp normalize_new_pipeline_attrs(form) when is_map(form) do
    with {:ok, id} <- validate_new_pipeline_id(form["id"]),
         {:ok, tracker_project_slug} <-
           validate_required_text(form["tracker_project_slug"], :missing_pipeline_project_slug),
         {:ok, prompt_template} <-
           validate_required_text(form["prompt_template"], :missing_pipeline_prompt_template) do
      {:ok,
       %{
         id: id,
         tracker_project_slug: tracker_project_slug,
         prompt_template: prompt_template,
         enabled: truthy_param?(form["enabled"])
       }}
    end
  end

  defp validate_new_pipeline_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :missing_pipeline_id}

      Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, trimmed) ->
        {:ok, trimmed}

      true ->
        {:error, :invalid_pipeline_id}
    end
  end

  defp validate_new_pipeline_id(_value), do: {:error, :missing_pipeline_id}

  defp validate_required_text(value, reason) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, reason}, else: {:ok, trimmed}
  end

  defp validate_required_text(_value, reason), do: {:error, reason}

  defp validate_new_pipeline_dir(pipeline_dir) when is_binary(pipeline_dir) do
    if File.exists?(pipeline_dir) do
      {:error, {:pipeline_already_exists, Path.basename(pipeline_dir)}}
    else
      :ok
    end
  end

  defp new_pipeline_config(attrs) when is_map(attrs) do
    %{
      "id" => attrs.id,
      "enabled" => attrs.enabled,
      "tracker" => %{
        "kind" => "linear",
        "project_slug" => attrs.tracker_project_slug
      }
    }
  end

  defp pipeline_editor_target?(%{mode: :pipeline}), do: true
  defp pipeline_editor_target?(_target), do: false

  defp workflow_editor_title(%{mode: :pipeline}, pipelines) when is_list(pipelines) and length(pipelines) > 1,
    do: "Pipeline 配置台"

  defp workflow_editor_title(%{mode: :pipeline, pipeline: %Pipeline{id: pipeline_id}}, _pipelines),
    do: "#{pipeline_id} 配置台"

  defp workflow_editor_title(_target, _pipelines), do: "WORKFLOW.md 编辑台"

  defp workflow_editor_copy(%{mode: :pipeline}) do
    "结构化和 YAML 共用一个编辑台，但保存时会拆分写回 `pipeline.yaml` 和 `WORKFLOW.md`。"
  end

  defp workflow_editor_copy(_target) do
    "结构化和 YAML 放进同一个工作区，用 tab 切换视图；保存和重载动作固定放在外层操作条。"
  end

  defp pipeline_switcher_copy(%Pipeline{} = pipeline) do
    if is_binary(pipeline.tracker.project_slug) and String.trim(pipeline.tracker.project_slug) != "" do
      pipeline.tracker.project_slug
    else
      "未设置 project slug"
    end
  end

  defp config_pipeline_button_class(selected_pipeline_id, pipeline_id) do
    base = "pipeline-card"
    if selected_pipeline_id == pipeline_id, do: "#{base} pipeline-card-active", else: base
  end

  defp enabled_pipeline_count(pipelines) when is_list(pipelines) do
    Enum.count(pipelines, &match?(%Pipeline{enabled: true}, &1))
  end

  defp enabled_pipeline_count(_pipelines), do: 0

  defp pipeline_payload_entry(payload, pipeline_id) when is_map(payload) and is_binary(pipeline_id) do
    payload
    |> Map.get(:pipelines, [])
    |> Enum.find(fn
      %{id: id} -> id == pipeline_id
      _ -> false
    end)
  end

  defp pipeline_payload_entry(_payload, _pipeline_id), do: nil

  defp config_pipeline_status(payload, %Pipeline{id: pipeline_id, enabled: enabled}) do
    case pipeline_payload_entry(payload, pipeline_id) do
      %{} = pipeline_payload ->
        dashboard_pipeline_status(pipeline_payload)

      _ ->
        if enabled, do: "待接管", else: "未启用"
    end
  end

  defp pipeline_payload_count(payload, pipeline_id, key)
       when is_map(payload) and is_binary(pipeline_id) and is_atom(key) do
    case pipeline_payload_entry(payload, pipeline_id) do
      %{} = pipeline_payload -> Map.get(pipeline_payload, key, 0)
      _ -> 0
    end
  end

  defp pipeline_payload_count(_payload, _pipeline_id, _key), do: 0

  defp pipeline_payload_next_poll(payload, pipeline_id) when is_map(payload) and is_binary(pipeline_id) do
    case pipeline_payload_entry(payload, pipeline_id) do
      %{} = pipeline_payload -> pipeline_next_poll(pipeline_payload)
      _ -> "n/a"
    end
  end

  defp pipeline_payload_next_poll(_payload, _pipeline_id), do: "n/a"

  defp selected_pipeline_status(payload, %{mode: :pipeline, pipeline: %Pipeline{} = pipeline}),
    do: config_pipeline_status(payload, pipeline)

  defp selected_pipeline_status(_payload, _workflow_target), do: "legacy"

  defp selected_pipeline_count(payload, %{mode: :pipeline, pipeline: %Pipeline{id: pipeline_id}}, key),
    do: pipeline_payload_count(payload, pipeline_id, key)

  defp selected_pipeline_count(_payload, _workflow_target, _key), do: 0

  defp selected_pipeline_next_poll(payload, %{mode: :pipeline, pipeline: %Pipeline{id: pipeline_id}}),
    do: pipeline_payload_next_poll(payload, pipeline_id)

  defp selected_pipeline_next_poll(_payload, _workflow_target), do: "n/a"

  defp save_button_label(%{mode: :pipeline}), do: "保存当前 pipeline"
  defp save_button_label(_target), do: "保存 WORKFLOW.md"

  defp workflow_summary_title(%{mode: :pipeline}), do: "当前选中 pipeline"
  defp workflow_summary_title(_target), do: "当前装载配置"

  defp workflow_summary_copy(%{mode: :pipeline}) do
    "这里展示当前选中 pipeline 的关键字段，保存后可以立刻核对磁盘上的目标配置。"
  end

  defp workflow_summary_copy(_target) do
    "这里展示当前运行时已经吃进去的关键字段，方便保存后立刻核对。"
  end

  defp workflow_notes_copy(%{mode: :pipeline}) do
    "结构化 tab 负责按 pipeline 管理高频字段，YAML tab 负责查看和改写合成后的完整草稿。"
  end

  defp workflow_notes_copy(_target) do
    "结构化 tab 负责高频字段，YAML tab 负责完整原文和高级改写。"
  end

  defp workflow_notes_text(%{mode: :pipeline}) do
    """
    1. 保存前会先校验合成草稿里的 YAML front matter 是否可解析。
    2. 校验通过后，结构化配置写回 pipeline.yaml，prompt 写回 WORKFLOW.md。
    3. 运行中的 pipeline 会在下一轮 tick / snapshot 时重新从磁盘加载配置。
    4. 若你在别处改了文件，可点“从磁盘重载”刷新编辑器。
    """
  end

  defp workflow_notes_text(_target) do
    """
    1. 保存前会先校验 YAML front matter 是否可解析。
    2. 校验通过才会写回 WORKFLOW.md。
    3. 写回后会立即触发 WorkflowStore reload。
    4. 若你在别处改了文件，可点“从磁盘重载”刷新编辑器。
    """
  end

  defp reload_feedback_message(%{mode: :pipeline}), do: "已从磁盘重新载入当前 pipeline 配置。"
  defp reload_feedback_message(_target), do: "已从磁盘重新载入 WORKFLOW.md。"

  defp save_feedback_message(%{mode: :pipeline}), do: "已保存并重新加载当前 pipeline 配置。"
  defp save_feedback_message(_target), do: "已保存并重新加载运行配置。"

  defp workflow_change_manifest(loaded_form, workflow_form) do
    manifest_fields = [
      {"tracker_project_slug", "项目 slug"},
      {"tracker_endpoint", "Linear endpoint"},
      {"tracker_active_states", "活跃状态"},
      {"tracker_terminal_states", "终止状态"},
      {"workspace_root", "工作区根目录"},
      {"polling_interval_ms", "轮询间隔"},
      {"agent_max_concurrent_agents", "最大并发"},
      {"agent_max_turns", "单次最大回合"},
      {"codex_command", "Codex 命令"},
      {"codex_thread_sandbox", "线程沙箱"},
      {"codex_stall_timeout_ms", "停滞超时"},
      {"prompt_template", "任务模版"}
    ]

    Enum.flat_map(manifest_fields, fn {field, label} ->
      current = normalize_manifest_value(Map.get(workflow_form, field))
      loaded = normalize_manifest_value(Map.get(loaded_form, field))

      if current == loaded do
        []
      else
        [%{label: label, before: loaded, after: current}]
      end
    end)
  end

  defp normalize_manifest_value(nil), do: "未设置"
  defp normalize_manifest_value(""), do: "未设置"
  defp normalize_manifest_value(value) when is_binary(value), do: value
  defp normalize_manifest_value(value), do: to_string(value)

  defp workflow_confirm_message(change_manifest, workflow_dirty, workflow_target)
       when is_list(change_manifest) do
    header =
      case workflow_target do
        %{mode: :pipeline, pipeline: %Pipeline{id: pipeline_id}} ->
          "即将保存 pipeline `#{pipeline_id}`。"

        _ ->
          "即将保存 WORKFLOW.md。"
      end

    scope =
      case change_manifest do
        [] ->
          if workflow_dirty do
            "本次未识别到结构化字段差异，但会写回当前编辑器草稿。"
          else
            "当前草稿和已装载配置一致。"
          end

        items ->
          items
          |> Enum.take(8)
          |> Enum.map_join("\n", fn item ->
            "- " <> workflow_change_item_summary(item)
          end)
          |> confirm_scope_from_lines(items)
      end

    [header, scope, "确认保存并触发热重载？"]
    |> Enum.join("\n\n")
  end

  defp workflow_change_item_summary(%{label: label, before: before_value, after: after_value}) do
    cond do
      label == "任务模版" ->
        "任务模版内容已修改"

      before_value == "未设置" ->
        "#{label}: 新增为 #{truncate_confirm_value(after_value)}"

      after_value == "未设置" ->
        "#{label}: 已清空（原值 #{truncate_confirm_value(before_value)}）"

      true ->
        "#{label}: #{truncate_confirm_value(before_value)} -> #{truncate_confirm_value(after_value)}"
    end
  end

  defp truncate_confirm_value(value) when is_binary(value) do
    if String.length(value) > 48, do: String.slice(value, 0, 45) <> "...", else: value
  end

  defp truncate_confirm_value(value), do: value |> to_string() |> truncate_confirm_value()

  defp normalize_display_value(value, _labels) when value in ["", "nil"], do: "未返回"
  defp normalize_display_value(value, labels), do: Map.get(labels, value, value)

  defp tracker_workflow_form(config) do
    %{
      "tracker_kind" => get_in(config, ["tracker", "kind"]) || "",
      "tracker_project_slug" => get_in(config, ["tracker", "project_slug"]) || "",
      "tracker_api_key" => get_in(config, ["tracker", "api_key"]) || "",
      "tracker_endpoint" => get_in(config, ["tracker", "endpoint"]) || "",
      "tracker_active_states" => joined_state_list(get_in(config, ["tracker", "active_states"])),
      "tracker_terminal_states" => joined_state_list(get_in(config, ["tracker", "terminal_states"]))
    }
  end

  defp runtime_workflow_form(config) do
    %{
      "workspace_root" => get_in(config, ["workspace", "root"]) || "",
      "polling_interval_ms" => integer_string(get_in(config, ["polling", "interval_ms"])),
      "agent_max_concurrent_agents" => integer_string(get_in(config, ["agent", "max_concurrent_agents"])),
      "agent_max_turns" => integer_string(get_in(config, ["agent", "max_turns"])),
      "agent_max_retry_backoff_ms" => integer_string(get_in(config, ["agent", "max_retry_backoff_ms"]))
    }
  end

  defp codex_workflow_form(config) do
    %{
      "codex_command" => get_in(config, ["codex", "command"]) || "",
      "codex_thread_sandbox" => get_in(config, ["codex", "thread_sandbox"]) || "",
      "codex_stall_timeout_ms" => integer_string(get_in(config, ["codex", "stall_timeout_ms"]))
    }
  end

  defp hooks_workflow_form(config) do
    %{
      "hooks_after_create" => get_in(config, ["hooks", "after_create"]) || "",
      "hooks_before_run" => get_in(config, ["hooks", "before_run"]) || "",
      "hooks_after_run" => get_in(config, ["hooks", "after_run"]) || "",
      "hooks_before_remove" => get_in(config, ["hooks", "before_remove"]) || "",
      "hooks_timeout_ms" => integer_string(get_in(config, ["hooks", "timeout_ms"]))
    }
  end

  defp confirm_scope_from_lines(lines, items) do
    hidden_count = max(length(items) - 8, 0)
    hidden_suffix = if hidden_count == 0, do: "", else: "\n- 以及另外 #{hidden_count} 项改动"
    "修改范围：\n" <> lines <> hidden_suffix
  end

  defp structured_option_class(current, value) do
    base = "structured-choice"
    if current == value, do: "#{base} structured-choice-active", else: base
  end

  defp state_chip_values(csv), do: csv_to_list(csv) || []

  defp format_workflow_reason(reason, workflow_target)

  defp format_workflow_reason(:unsupported_memory_tracker_kind, _workflow_target),
    do: "配置区不支持 `tracker.kind: memory`，请改为 `linear`。"

  defp format_workflow_reason({:workflow_parse_error, reason}, %{mode: :pipeline}),
    do: "pipeline 草稿解析失败: #{inspect(reason)}"

  defp format_workflow_reason({:workflow_parse_error, reason}, _workflow_target),
    do: "WORKFLOW.md 解析失败: #{inspect(reason)}"

  defp format_workflow_reason({:missing_workflow_file, path, reason}, %{mode: :pipeline}),
    do: "找不到 pipeline 的 WORKFLOW.md: #{path} (#{inspect(reason)})"

  defp format_workflow_reason({:missing_workflow_file, path, reason}, _workflow_target),
    do: "找不到 WORKFLOW.md: #{path} (#{inspect(reason)})"

  defp format_workflow_reason(:workflow_front_matter_not_a_map, %{mode: :pipeline}),
    do: "合成草稿的 front matter 必须是 YAML map。"

  defp format_workflow_reason(:workflow_front_matter_not_a_map, _workflow_target),
    do: "front matter 必须是 YAML map。"

  defp format_workflow_reason(:missing_pipeline_editor_content, %{mode: :pipeline}),
    do: "未能读取当前 pipeline 的磁盘配置。"

  defp format_workflow_reason(other, %{mode: :pipeline}),
    do: "无法保存当前 pipeline 配置: #{inspect(other)}"

  defp format_workflow_reason(other, _workflow_target),
    do: "无法保存 WORKFLOW.md: #{inspect(other)}"

  defp format_new_pipeline_reason(:pipeline_root_unavailable),
    do: "当前没有可写的 pipeline 根目录；请先用 pipeline 根目录启动 Symphony。"

  defp format_new_pipeline_reason(:missing_pipeline_id),
    do: "请输入 pipeline id。"

  defp format_new_pipeline_reason(:invalid_pipeline_id),
    do: "pipeline id 只能包含小写字母、数字、`-` 和 `_`，并且必须以字母或数字开头。"

  defp format_new_pipeline_reason(:missing_pipeline_project_slug),
    do: "请输入 project slug。"

  defp format_new_pipeline_reason(:missing_pipeline_prompt_template),
    do: "请输入 prompt template。"

  defp format_new_pipeline_reason({:pipeline_already_exists, pipeline_id}),
    do: "pipeline `#{pipeline_id}` 已存在，请换一个 id。"

  defp format_new_pipeline_reason(other),
    do: "无法创建新的 pipeline: #{inspect(other)}"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
