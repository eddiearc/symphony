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
          source_paths: [Path.t()],
          lines: [String.t()],
          truncated: boolean()
        }
  def recent_log_view(opts \\ []) do
    path = configured_log_file()
    line_limit = Keyword.get(opts, :line_limit, 80)
    byte_limit = Keyword.get(opts, :byte_limit, 64 * 1024)

    case resolve_log_sources(path) do
      {_total_size, []} ->
        %{
          path: path,
          available: false,
          source_paths: [],
          lines: [],
          truncated: false
        }

      {total_size, source_paths} ->
        data = read_tail_bytes_from_sources(source_paths, byte_limit)
        {lines, truncated} = tail_lines(data, total_size, line_limit, byte_limit)

        %{
          path: path,
          available: true,
          source_paths: source_paths,
          lines: lines,
          truncated: truncated
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

  defp resolve_log_sources(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        {size, [path]}

      {:error, _reason} ->
        wrapped_log_sources(path)
    end
  end

  defp wrapped_log_sources(path) do
    source_paths =
      path
      |> discover_wrapped_log_paths()
      |> Enum.sort_by(&log_path_mtime/1, :asc)

    total_size =
      Enum.reduce(source_paths, 0, fn source_path, total ->
        case File.stat(source_path) do
          {:ok, %File.Stat{size: size}} -> total + size
          {:error, _reason} -> total
        end
      end)

    {total_size, source_paths}
  end

  defp discover_wrapped_log_paths(path) do
    wildcard = path <> ".*"

    Path.wildcard(wildcard)
    |> Enum.filter(&numeric_log_suffix?(&1, path))
  end

  defp numeric_log_suffix?(candidate, path) do
    prefix = path <> "."

    String.starts_with?(candidate, prefix) and
      case String.replace_prefix(candidate, prefix, "") do
        suffix when suffix != "" -> String.match?(suffix, ~r/^\d+$/)
        _ -> false
      end
  end

  defp log_path_mtime(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        NaiveDateTime.from_erl!(mtime)

      {:error, _reason} ->
        ~N[1970-01-01 00:00:00]
    end
  end

  defp read_tail_bytes_from_sources(source_paths, byte_limit) do
    {chunks, _remaining} =
      Enum.reduce(Enum.reverse(source_paths), {[], byte_limit}, fn source_path, {chunks, remaining} ->
        if remaining <= 0 do
          {chunks, remaining}
        else
          chunk = read_source_tail_chunk(source_path, remaining)

          {[chunk | chunks], max(remaining - byte_size(chunk), 0)}
        end
      end)

    IO.iodata_to_binary(chunks)
  end

  defp read_source_tail_chunk(source_path, remaining)
       when is_binary(source_path) and is_integer(remaining) do
    case File.stat(source_path) do
      {:ok, %File.Stat{size: source_size}} when source_size > 0 ->
        read_tail_bytes(source_path, source_size, remaining)

      _ ->
        ""
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

  defp drop_partial_first_line(lines, size, byte_limit)
       when size > byte_limit and length(lines) > 1 do
    tl(lines)
  end

  defp drop_partial_first_line(lines, _size, _byte_limit), do: lines
end
