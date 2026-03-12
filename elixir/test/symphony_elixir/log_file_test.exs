defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "recent_log_view/1 returns the latest log lines and configured path" do
    log_root = Path.join(System.tmp_dir!(), "symphony-log-file-test-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, Enum.map_join(1..8, "\n", &"line-#{&1}") <> "\n")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    assert %{
             path: ^log_path,
             available: true,
             source_paths: [^log_path],
             lines: ["line-5", "line-6", "line-7", "line-8"],
             truncated: true
           } = LogFile.recent_log_view(line_limit: 4, byte_limit: 256)
  end

  test "recent_log_view/1 falls back to wrapped log segments when the base file is absent" do
    log_root = Path.join(System.tmp_dir!(), "symphony-log-wrap-test-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")
    wrapped_log_path = log_path <> ".1"
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(wrapped_log_path, "wrapped-1\nwrapped-2\nwrapped-3\n")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    assert %{
             path: ^log_path,
             available: true,
             source_paths: [^wrapped_log_path],
             lines: ["wrapped-2", "wrapped-3"],
             truncated: true
           } = LogFile.recent_log_view(line_limit: 2, byte_limit: 256)
  end

  test "recent_log_view/1 tails across wrapped log segments in modification order" do
    log_root = Path.join(System.tmp_dir!(), "symphony-log-multi-wrap-test-#{System.unique_integer([:positive])}")
    log_path = Path.join(log_root, "log/symphony.log")
    older_path = log_path <> ".1"
    newer_path = log_path <> ".2"
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(older_path, "older-1\nolder-2\n")
    File.write!(newer_path, "newer-1\nnewer-2\n")
    now = System.os_time(:second)
    File.touch!(older_path, now - 5)
    File.touch!(newer_path, now)

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)

    assert %{
             path: ^log_path,
             available: true,
             source_paths: [^older_path, ^newer_path],
             lines: ["older-2", "newer-1", "newer-2"],
             truncated: true
           } = LogFile.recent_log_view(line_limit: 3, byte_limit: 256)
  end
end
