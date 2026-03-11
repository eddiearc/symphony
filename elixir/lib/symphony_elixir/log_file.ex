defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures OTP's built-in rotating disk log handler for application logs.
  """

  require Logger

  @handler_id :symphony_disk_log
  @default_log_relative_path "log/symphony.log"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec configured_log_file() :: Path.t()
  def configured_log_file do
    :symphony_elixir
    |> Application.get_env(:log_file, default_log_file())
    |> Path.expand()
  end

  @spec recent_log_view(keyword()) :: %{
          path: Path.t(),
          available: boolean(),
          lines: [String.t()],
          truncated: boolean()
        }
  def recent_log_view(opts \\ []) do
    path = configured_log_file()
    line_limit = Keyword.get(opts, :line_limit, 80)
    byte_limit = Keyword.get(opts, :byte_limit, 64 * 1024)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        data = read_tail_bytes(path, size, byte_limit)
        {lines, truncated} = tail_lines(data, size, line_limit, byte_limit)

        %{
          path: path,
          available: true,
          lines: lines,
          truncated: truncated
        }

      {:error, _reason} ->
        %{
          path: path,
          available: false,
          lines: [],
          truncated: false
        }
    end
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())
    max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    setup_disk_handler(log_file, max_bytes, max_files)
  end

  defp setup_disk_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_existing_handler()

    case :logger.add_handler(
           @handler_id,
           :logger_disk_log_h,
           disk_log_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure rotating log file handler: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_existing_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp disk_log_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end

  defp read_tail_bytes(path, size, byte_limit) do
    offset = max(size - byte_limit, 0)
    read_size = size - offset

    {:ok, device} = :file.open(String.to_charlist(path), [:read, :binary])

    try do
      case :file.pread(device, offset, read_size) do
        {:ok, data} -> data
        :eof -> ""
      end
    after
      :ok = :file.close(device)
    end
  end

  defp tail_lines(data, size, line_limit, byte_limit) do
    lines =
      data
      |> String.split(~r/\R/u, trim: false)
      |> drop_partial_first_line(size, byte_limit)
      |> Enum.reject(&(&1 == ""))

    total_count = length(lines)

    {
      Enum.take(lines, -line_limit),
      size > byte_limit or total_count > line_limit
    }
  end

  defp drop_partial_first_line(lines, size, byte_limit) when size > byte_limit and length(lines) > 1 do
    tl(lines)
  end

  defp drop_partial_first_line(lines, _size, _byte_limit), do: lines
end
