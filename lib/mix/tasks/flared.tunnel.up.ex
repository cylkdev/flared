defmodule Mix.Tasks.Flared.Tunnel.Up do
  @shortdoc "Bring up cloudflared against an existing tunnel and block"

  @moduledoc """
  Runs the `cloudflared` binary against artifacts that already exist and
  blocks until the OS process exits or `--timeout` elapses.

  Unlike `mix flared.tunnel.remote.run` and `mix flared.tunnel.local.run`, this
  task does not create or destroy any Cloudflare-side resources. It does
  manage one piece of local state: a PID file at
  `priv/tmp/<name>.pid` (under the `:flared` app's priv dir) so that
  `mix flared.tunnel.down` can find and stop the running process. The
  PID file is written immediately after spawn and removed on clean exit.
  If a PID file already exists for `<name>` and the recorded PID is
  still alive, the task refuses to start to avoid accidental dual-run.
  Stale PID files (recorded PID no longer alive) are silently
  overwritten.

  Two run modes:

  - **Remote mode** (`--token` or `TUNNEL_TOKEN` env var): authenticates
    with a tunnel token. The token is read from `--token` if supplied,
    otherwise from the `TUNNEL_TOKEN` environment variable. It is
    forwarded to `cloudflared` via `TUNNEL_TOKEN` so it never appears in
    argv. Prefer the env var: a token passed as `--token` ends up in the
    parent shell's history and in `ps` output.
  - **Local mode** (`--config`): runs against an existing local config
    file. Spawns `cloudflared --config <path> tunnel run`.

  Exactly one mode must be selected: provide a token (via `--token` or
  the `TUNNEL_TOKEN` env var) **or** `--config`. If both an explicit
  `--token` and `--config` are supplied, the call is rejected as a
  conflict; an ambient `TUNNEL_TOKEN` env var combined with an explicit
  `--config` is *not* a conflict (the explicit flag wins).

  ## Usage

  Remote (token via env var, recommended):

  ```bash
  export TUNNEL_TOKEN="your-token-here"
  mix flared.tunnel.up --name api
  ```

  Local (config file produced by `mix flared.tunnel.local.run`):

  ```bash
  mix flared.tunnel.up --name api --config .cloudflared/api/config.yml
  ```

  ## Flags

  - `--name <name>` / `-n`: tunnel name (required); used as the PID file
    basename so `mix flared.tunnel.down` can find this process
  - `--token <token>` / `-t`: tunnel token (optional; falls back to the
    `TUNNEL_TOKEN` env var; mutually exclusive with `--config`)
  - `--config <path>` / `-c`: path to a cloudflared config file
    (mutually exclusive with `--token`)
  - `--cloudflared-path <path>` / `-p`: path to the cloudflared binary
    (defaults to `Flared.Config.executable/0`)
  - `--timeout <ms>`: how long to block after spawning (default: forever)
  """

  use Mix.Task

  alias Flared.Config
  alias Flared.PidFile

  @switches [
    name: :string,
    token: :string,
    config: :string,
    executable: :string,
    timeout: :integer
  ]

  @aliases [
    n: :name,
    t: :token,
    c: :config,
    p: :executable
  ]

  @type mode :: {:remote, String.t()} | {:config, String.t()}

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
  @spec fetch_name(keyword()) :: {:ok, String.t()} | {:error, :missing_name}
  def fetch_name(parsed) do
    case present(parsed[:name]) do
      name when is_binary(name) -> {:ok, name}
      _ -> {:error, :missing_name}
    end
  end

  @doc false
  @spec validate_mode(keyword(), String.t() | nil) ::
          {:ok, mode()} | {:error, :missing_mode | :conflicting_modes}
  def validate_mode(parsed, env_token \\ nil) do
    flag_token = present(parsed[:token])
    config = present(parsed[:config])
    env = present(env_token)

    cond do
      is_binary(flag_token) and is_binary(config) -> {:error, :conflicting_modes}
      is_binary(flag_token) -> {:ok, {:remote, flag_token}}
      is_binary(config) -> {:ok, {:config, config}}
      is_binary(env) -> {:ok, {:remote, env}}
      true -> {:error, :missing_mode}
    end
  end

  @doc false
  @spec build_command(String.t(), mode()) :: charlist()
  def build_command(executable, {:remote, _token}) do
    ~c"#{executable} tunnel run"
  end

  def build_command(executable, {:config, path}) do
    ~c"#{executable} --config #{path} tunnel run"
  end

  @doc false
  @spec build_env(mode()) :: [{charlist(), charlist()}]
  def build_env({:remote, token}),
    do: [{~c"TUNNEL_TOKEN", String.to_charlist(token)}]

  def build_env({:config, _path}), do: []

  defp do_run(parsed) do
    executable = parsed[:executable] || Config.executable()
    timeout = Keyword.get(parsed, :timeout, :infinity)
    env_token = System.get_env("TUNNEL_TOKEN")

    with {:ok, name} <- fetch_name(parsed),
         :ok <- ensure_no_live_pid_file(name),
         {:ok, mode} <- validate_mode(parsed, env_token),
         command = build_command(executable, mode),
         env = build_env(mode),
         {:ok, exec_pid, os_pid} <- spawn_cloudflared(command, env) do
      PidFile.write(name, os_pid)
      Mix.shell().info("cloudflared started (#{name}, pid #{os_pid})")
      result = wait_for_exit(exec_pid, timeout)
      PidFile.delete(name)
      handle_result(result)
    else
      {:error, reason} ->
        reason |> format_error() |> Mix.shell().error()
        System.halt(1)
    end
  end

  defp ensure_no_live_pid_file(name) do
    case PidFile.read(name) do
      {:ok, pid} ->
        if pid_alive?(pid) do
          {:error, {:already_running, name, pid}}
        else
          PidFile.delete(name)
          :ok
        end

      {:error, :not_found} ->
        :ok

      {:error, :corrupt} ->
        PidFile.delete(name)
        :ok
    end
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp spawn_cloudflared(command, env) do
    case Exexec.run_link(command, env: env) do
      {:ok, _exec_pid, _os_pid} = ok -> ok
      {:error, reason} -> {:error, {:spawn_failed, reason}}
    end
  end

  defp present(value) when is_binary(value) and value !== "", do: value
  defp present(_), do: nil

  defp wait_for_exit(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:cloudflared_exited, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :cloudflared_timed_out}
    end
  end

  defp handle_result(:ok), do: :ok

  defp handle_result({:error, reason}) do
    reason |> format_error() |> Mix.shell().error()
    System.halt(1)
  end

  defp report_invalid(invalid) do
    invalid
    |> Enum.map(fn {flag, _val} -> flag end)
    |> Enum.uniq()
    |> Enum.each(fn flag ->
      Mix.shell().error("Unknown option: #{flag}")
    end)
  end

  defp format_error(:missing_name), do: "Missing required --name"

  defp format_error(:missing_mode),
    do: "Missing --token (or TUNNEL_TOKEN env var) or --config"

  defp format_error(:conflicting_modes), do: "Cannot use --token and --config together"
  defp format_error(:cloudflared_timed_out), do: "cloudflared timed out"

  defp format_error({:already_running, name, pid}),
    do: "Tunnel #{inspect(name)} already running (pid #{pid})"

  defp format_error({:cloudflared_exited, reason}),
    do: "cloudflared exited: #{inspect(reason)}"

  defp format_error({:spawn_failed, reason}),
    do: "Failed to spawn cloudflared: #{inspect(reason)}"

  defp format_error(other), do: inspect(other)
end
