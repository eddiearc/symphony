defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

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
        <title>Symphony · 编排席</title>
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

                this.submitHandler = function (event) {
                  var message = self.el.dataset.confirmMessage || "确认保存当前配置吗？";

                  if (!window.confirm(message)) {
                    event.preventDefault();
                    event.stopImmediatePropagation();
                  }
                };

                this.keydownHandler = function (event) {
                  var isSaveShortcut =
                    (event.metaKey || event.ctrlKey) &&
                      !event.shiftKey &&
                      !event.altKey &&
                      String(event.key || "").toLowerCase() === "s";

                  if (!isSaveShortcut) return;

                  event.preventDefault();

                  if (typeof self.el.requestSubmit === "function") {
                    self.el.requestSubmit();
                  } else {
                    self.el.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}));
                  }
                };

                this.el.addEventListener("submit", this.submitHandler, true);
                window.addEventListener("keydown", this.keydownHandler);
              },

              destroyed: function () {
                if (this.submitHandler) {
                  this.el.removeEventListener("submit", this.submitHandler, true);
                }

                if (this.keydownHandler) {
                  window.removeEventListener("keydown", this.keydownHandler);
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
        <link rel="stylesheet" href="/dashboard.css" />
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
