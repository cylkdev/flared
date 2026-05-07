defmodule Mix.Tasks.Flared.Tunnel.Down do
  @shortdoc "Stop tunnels brought up by mix flared.tunnel.up"

  @moduledoc """
  Inverse of `mix flared.tunnel.up`.

  Reads PID files from `priv/tmp/<name>.pid` (under the `:flared` app's
  priv dir) and stops each tunnel process gracefully: SIGTERM, then
  SIGKILL after `--timeout` ms (default `10000`) if the process is
  still alive. PID files are removed once the process exits.

  This is a local-machine operation only. It does not touch
  Cloudflare-side resources. To deprovision, use
  `mix flared.tunnel.remote.destroy` or
  `mix flared.tunnel.local.destroy`.

  Stale entries (PID file present but PID not alive) are cleaned up
  without signalling.

  ## Usage

  Stop all tunnels:

  ```bash
  mix flared.tunnel.down
  ```

  Stop a specific tunnel:

  ```bash
  mix flared.tunnel.down --name api
  ```

  Preview without signalling:

  ```bash
  mix flared.tunnel.down --dry-run
  ```

  ## Flags

  - `--name <name>` / `-n`: stop only this tunnel (otherwise all)
  - `--timeout <ms>` / `-t`: TERM grace period before SIGKILL
    (default: `10000`)
  - `--force` / `-f`: skip TERM, send SIGKILL immediately
  - `--dry-run` / `-d`: list matched tunnels without signalling
  """

  use Mix.Task

  alias Flared.PidFile

  @switches [name: :string, timeout: :integer, force: :boolean, dry_run: :boolean]
  @aliases [n: :name, t: :timeout, f: :force, d: :dry_run]

  @default_timeout_ms 10_000
  @poll_interval_ms 100

  @type mode :: :graceful | :force | :dry_run
  @type entry :: {String.t(), pos_integer()}

  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {parsed, _rest, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if invalid !== [] do
      report_invalid(invalid)
      System.halt(1)
    else
      do_run(parsed)
    end
  end

  @doc false
  @spec validate_flags(keyword()) :: {:ok, mode()} | {:error, :conflicting_actions}
  def validate_flags(parsed) do
    case {parsed[:dry_run], parsed[:force]} do
      {true, true} -> {:error, :conflicting_actions}
      {true, _} -> {:ok, :dry_run}
      {_, true} -> {:ok, :force}
      _ -> {:ok, :graceful}
    end
  end

  @doc false
  @spec filter_by_name([entry()], String.t() | nil) :: [entry()]
  def filter_by_name(entries, nil), do: entries

  def filter_by_name(entries, name) when is_binary(name) do
    Enum.filter(entries, fn {n, _pid} -> n === name end)
  end

  defp do_run(parsed) do
    case validate_flags(parsed) do
      {:ok, mode} ->
        timeout = parsed[:timeout] || @default_timeout_ms
        entries = PidFile.list() |> filter_by_name(parsed[:name])
        execute(mode, entries, timeout)

      {:error, reason} ->
        Mix.shell().error(format_error(reason))
        System.halt(1)
    end
  end

  defp execute(_mode, [], _timeout) do
    Mix.shell().info("No tunnels running.")
    :ok
  end

  defp execute(:dry_run, entries, _timeout) do
    Enum.each(entries, fn {name, pid} ->
      status = if pid_alive?(pid), do: "alive", else: "stale"
      Mix.shell().info("Would stop #{name} (pid #{pid}, #{status})")
    end)

    :ok
  end

  defp execute(mode, entries, timeout) do
    Enum.each(entries, fn {name, pid} -> stop_one(mode, name, pid, timeout) end)
    :ok
  end

  defp stop_one(_mode, name, pid, _timeout) when not is_integer(pid) do
    Mix.shell().info("Skipping #{name}: invalid pid #{inspect(pid)}")
    PidFile.delete(name)
  end

  defp stop_one(mode, name, pid, timeout) do
    if pid_alive?(pid) do
      signal_alive(mode, name, pid, timeout)
    else
      Mix.shell().info("Stale entry: #{name} (pid #{pid})")
    end

    PidFile.delete(name)
  end

  defp signal_alive(:force, name, pid, _timeout) do
    send_signal(pid, "KILL")
    Mix.shell().info("Killed #{name} (pid #{pid})")
  end

  defp signal_alive(:graceful, name, pid, timeout) do
    send_signal(pid, "TERM")
    Mix.shell().info("Stopping #{name} (pid #{pid})")

    if wait_for_exit(pid, timeout) do
      Mix.shell().info("Stopped #{name}")
    else
      send_signal(pid, "KILL")
      Mix.shell().info("Escalated to SIGKILL: #{name}")
    end
  end

  defp wait_for_exit(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until_dead(pid, deadline)
  end

  defp poll_until_dead(pid, deadline) do
    cond do
      not pid_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_interval_ms)
        poll_until_dead(pid, deadline)
    end
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp send_signal(pid, signal) when is_integer(pid) and pid > 0 do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp report_invalid(invalid) do
    invalid
    |> Enum.map(fn {flag, _val} -> flag end)
    |> Enum.uniq()
    |> Enum.each(fn flag ->
      Mix.shell().error("Unknown option: #{flag}")
    end)
  end

  defp format_error(:conflicting_actions),
    do: "Cannot use --dry-run and --force together"

  defp format_error(other), do: inspect(other)
end
