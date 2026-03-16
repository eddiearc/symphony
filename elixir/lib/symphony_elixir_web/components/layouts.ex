defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony · Control Center</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var hooks = {};

            hooks.WorkflowEditor = {
              mounted: function () {
                var self = this;

                this.keydownHandler = function (event) {
                  var isSaveShortcut =
                    (event.metaKey || event.ctrlKey) &&
                      !event.shiftKey &&
                      !event.altKey &&
                      String(event.key || "").toLowerCase() === "s";

                  if (!isSaveShortcut) return;

                  event.preventDefault();
                  self.pushEvent("open_save_workflow_modal", {});
                };

                window.addEventListener("keydown", this.keydownHandler);
              },

              destroyed: function () {
                if (this.keydownHandler) {
                  window.removeEventListener("keydown", this.keydownHandler);
                }
              }
            };

            hooks.MarkdownScrollSync = {
              mounted: function () {
                this.editorPane = this.el.querySelector("[data-scroll-sync-source='editor']");
                this.previewPane = this.el.querySelector("[data-scroll-sync-source='preview']");

                if (!this.editorPane || !this.previewPane) return;

                this.activeSource = null;
                this.releaseTimer = null;

                this.syncScroll = (sourcePane, targetPane, sourceName) => {
                  var sourceScrollable = sourcePane.scrollHeight - sourcePane.clientHeight;
                  var targetScrollable = targetPane.scrollHeight - targetPane.clientHeight;

                  if (sourceScrollable <= 0 || targetScrollable <= 0) {
                    targetPane.scrollTop = 0;
                    return;
                  }

                  this.activeSource = sourceName;
                  targetPane.scrollTop = (sourcePane.scrollTop / sourceScrollable) * targetScrollable;

                  window.clearTimeout(this.releaseTimer);
                  this.releaseTimer = window.setTimeout(() => {
                    this.activeSource = null;
                  }, 80);
                };

                this.handleEditorScroll = () => {
                  if (this.activeSource && this.activeSource !== "editor") return;
                  this.syncScroll(this.editorPane, this.previewPane, "editor");
                };

                this.handlePreviewScroll = () => {
                  if (this.activeSource && this.activeSource !== "preview") return;
                  this.syncScroll(this.previewPane, this.editorPane, "preview");
                };

                this.editorPane.addEventListener("scroll", this.handleEditorScroll, {passive: true});
                this.previewPane.addEventListener("scroll", this.handlePreviewScroll, {passive: true});
              },

              updated: function () {
                if (!this.editorPane || !this.previewPane) return;

                if (this.activeSource === "editor") {
                  this.syncScroll(this.editorPane, this.previewPane, "editor");
                } else if (this.activeSource === "preview") {
                  this.syncScroll(this.previewPane, this.editorPane, "preview");
                }
              },

              destroyed: function () {
                if (this.editorPane && this.handleEditorScroll) {
                  this.editorPane.removeEventListener("scroll", this.handleEditorScroll);
                }

                if (this.previewPane && this.handlePreviewScroll) {
                  this.previewPane.removeEventListener("scroll", this.handlePreviewScroll);
                }

                if (this.releaseTimer) {
                  window.clearTimeout(this.releaseTimer);
                }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={"/dashboard.css?v=#{StaticAssets.version("/dashboard.css")}"} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
