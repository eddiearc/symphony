defmodule Symphonyctl.Notifier do
  @moduledoc """
  Sends local and optional Telegram notifications for `syctl`.
  """

  @type deps :: %{
          optional(:deliver_telegram) => (String.t(), String.t(), String.t() -> :ok | {:error, term()}),
          optional(:puts) => (String.t() -> :ok | term())
        }

  @spec notify(map(), atom(), String.t(), deps()) :: :ok
  def notify(config, level, message, deps \\ runtime_deps())
      when is_map(config) and is_atom(level) and is_binary(message) and is_map(deps) do
    deps.puts.("[#{level}] #{message}")

    maybe_send_telegram(config, message, deps)
    :ok
  end

  defp maybe_send_telegram(config, message, deps) do
    telegram = get_in(config, [:notify, :telegram]) || %{}

    if telegram[:enabled] && is_binary(telegram[:bot_token]) && is_binary(telegram[:chat_id]) do
      _ = deps.deliver_telegram.(telegram.bot_token, telegram.chat_id, message)
      :ok
    else
      :ok
    end
  end

  defp runtime_deps do
    %{
      deliver_telegram: &deliver_telegram/3,
      puts: fn message ->
        IO.puts(message)
        :ok
      end
    }
  end

  defp deliver_telegram(bot_token, chat_id, message) do
    case Req.post("https://api.telegram.org/bot#{bot_token}/sendMessage",
           json: %{chat_id: chat_id, text: message}
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
