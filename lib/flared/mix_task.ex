defmodule Flared.MixTask do
  @moduledoc """
  Stateless, high-level API for managing a Cloudflare tunnel via the
  command line.

  Cloudflare's API is the source of truth — this module does not track
  tunnel state locally. Each function makes the API calls (and, where
  relevant, runs `cloudflared`) needed to satisfy a single request and
  returns.

  Every public function takes the Cloudflare tunnel `name` as its first
  positional argument; it is required and must be a non-empty string.

  ## Two ways to run a tunnel

    - **Remote** — ingress rules are pushed to the Cloudflare API and
      `cloudflared` runs with `--token <TOKEN>`. See `open_remote/3`,
      `close_remote/3`, `run_remote/3`.
    - **Local** — ingress rules are written to a local `config.yml` and
      credentials to `<UUID>.json`; `cloudflared` runs with
      `--config <path> tunnel run`. See `open_local/3`, `close_local/3`,
      `run_local/3`.

  ## Functions

    * `open_remote/3`, `open_local/3` — provision the tunnel + DNS in
      Cloudflare. No `cloudflared` is started.
    * `close_remote/3`, `close_local/3` — deprovision the tunnel + DNS
      (and, for local mode, delete the on-disk config + credentials).
    * `status/2` — query Cloudflare for whether a tunnel by name exists.
    * `run_remote/3`, `run_local/3` — provision, run `cloudflared` in
      the foreground, and deprovision when `cloudflared` exits.

  ## Example

      routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
      Flared.MixTask.run_remote("site-a", routes)
  """

  require Logger

  alias Flared.Config
  alias Flared.PidFile
  alias Flared.Provisioner
  alias Flared.Tunnels

  @type name :: String.t()
  @type route :: Provisioner.Remote.route()
  @type status_info :: %{
          required(:name) => name(),
          required(:exists) => boolean(),
          required(:tunnel_id) => String.t() | nil
        }
  @type list_entry :: %{
          required(:name) => name(),
          required(:tunnel_id) => String.t(),
          required(:created_at) => String.t() | nil,
          required(:deleted_at) => String.t() | nil
        }
  @type up_mode :: {:remote, String.t()} | {:config, String.t()}
  @type down_mode :: :graceful | :force | :dry_run
  @type down_outcome ::
          :stopped | :killed | :escalated | :stale | :would_stop | :invalid_pid
  @type down_entry :: %{
          required(:name) => name(),
          required(:pid) => pos_integer() | term(),
          required(:outcome) => down_outcome()
        }

  @down_default_timeout_ms 10_000
  @down_poll_interval_ms 100

  @doc """
  Provisions a remote-mode tunnel via the Cloudflare API.

  Pushes ingress rules to Cloudflare, ensures DNS records, and fetches
  the connector token. Does not start `cloudflared`.

  Returns the result map from `Flared.Provisioner.Remote.provision/3`.

  ## Options

  Options are forwarded to `Flared.Provisioner.Remote.provision/3`
  (e.g. `:account_id`, `:concurrency`, `:dry_run?`, `:token`).
  """
  @spec open_remote(name(), [route()], keyword()) ::
          {:ok, Provisioner.Remote.result()} | {:error, term()}
  def open_remote(name, routes, opts \\ [])
      when is_binary(name) and name !== "" and is_list(routes) and is_list(opts) do
    Provisioner.Remote.provision(name, routes, opts)
  end

  @doc """
  Provisions a local-mode tunnel via the Cloudflare API and writes
  the on-disk `config.yml` and `<UUID>.json` credentials.

  Returns the result map from `Flared.Provisioner.Local.provision/3`.

  ## Options

    * `:cloudflared_dir` — directory for local files (resolved via
      `Flared.Config.cloudflared_dir/0`).
    * Other options are forwarded to
      `Flared.Provisioner.Local.provision/3`.
  """
  @spec open_local(name(), [route()], keyword()) ::
          {:ok, Provisioner.Local.result()} | {:error, term()}
  def open_local(name, routes, opts \\ [])
      when is_binary(name) and name !== "" and is_list(routes) and is_list(opts) do
    Provisioner.Local.provision(name, routes, opts)
  end

  @doc """
  Deprovisions a remote-mode tunnel via the Cloudflare API.

  Deletes matching DNS records and the tunnel itself. Does not stop a
  running `cloudflared` process — that is the caller's responsibility
  (or it will exit on its own once the tunnel disappears server-side).

  See `Flared.Provisioner.Remote.deprovision/3` for option details
  (`:delete_dns?`, `:delete_tunnel?`, `:dry_run?`, etc.).
  """
  @spec close_remote(name(), [route()], keyword()) ::
          {:ok, Provisioner.Remote.deprovision_result()} | {:error, term()}
  def close_remote(name, routes, opts \\ [])
      when is_binary(name) and name !== "" and is_list(routes) and is_list(opts) do
    Provisioner.Remote.deprovision(name, routes, opts)
  end

  @doc """
  Deprovisions a local-mode tunnel via the Cloudflare API and deletes
  the on-disk `config.yml` + `<UUID>.json` credentials.

  See `Flared.Provisioner.Local.deprovision/3` for option details
  (`:delete_dns?`, `:delete_tunnel?`, `:delete_files?`, `:dry_run?`,
  etc.).
  """
  @spec close_local(name(), [route()], keyword()) ::
          {:ok, Provisioner.Local.deprovision_result()} | {:error, term()}
  def close_local(name, routes, opts \\ [])
      when is_binary(name) and name !== "" and is_list(routes) and is_list(opts) do
    Provisioner.Local.deprovision(name, routes, opts)
  end

  @doc """
  Queries the Cloudflare API for a tunnel by name.

  ## Options

    * `:account_id` — overrides `Flared.Config.account_id/0`.
    * `:token` — overrides the API token.
  """
  @spec status(name(), keyword()) :: {:ok, status_info()} | {:error, term()}
  def status(name, opts \\ []) when is_binary(name) and name !== "" and is_list(opts) do
    with {:ok, account_id} <- fetch_account_id(opts),
         {:ok, tunnel} <- Tunnels.find_tunnel(account_id, name, opts) do
      case tunnel do
        nil -> {:ok, %{name: name, exists: false, tunnel_id: nil}}
        %{"id" => id} -> {:ok, %{name: name, exists: true, tunnel_id: id}}
      end
    end
  end

  @doc """
  Lists all Cloudflare tunnels in the configured account.

  Returns entries in the order Cloudflare returned them. Cloudflare's
  default behavior of including or excluding deleted tunnels is preserved;
  callers can detect deleted entries via `:deleted_at`.

  ## Options

    * `:account_id` — overrides `Flared.Config.account_id/0`.
    * `:token` — overrides the API token.
  """
  @spec list(keyword()) :: {:ok, [list_entry()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    with {:ok, account_id} <- fetch_account_id(opts),
         {:ok, tunnels} <- Tunnels.list_tunnels(account_id, opts) do
      {:ok, Enum.map(tunnels, &normalize_list_entry/1)}
    end
  end

  @doc """
  Searches Cloudflare tunnels in the configured account by substring.

  At least one of `:name_contains` or `:id_contains` must be a non-empty
  string. When both are provided, an entry must match both filters.
  Comparisons are case-insensitive. Returns matching entries in the order
  Cloudflare returned them, with the same shape as `list/1`.

  ## Options

    * `:name_contains` — substring match against the tunnel name.
    * `:id_contains` — substring match against the tunnel id.
    * `:account_id` — overrides `Flared.Config.account_id/0`.
    * `:token` — overrides the API token.
  """
  @spec find(keyword()) :: {:ok, [list_entry()]} | {:error, term()}
  def find(opts) when is_list(opts) do
    name_q = normalize_query(opts[:name_contains])
    id_q = normalize_query(opts[:id_contains])

    if name_q === nil and id_q === nil do
      {:error, :missing_query}
    else
      with {:ok, entries} <- list(opts) do
        {:ok, Enum.filter(entries, &matches?(&1, name_q, id_q))}
      end
    end
  end

  defp normalize_list_entry(%{"id" => id, "name" => name} = tunnel) do
    %{
      name: name,
      tunnel_id: id,
      created_at: Map.get(tunnel, "created_at"),
      deleted_at: Map.get(tunnel, "deleted_at")
    }
  end

  defp normalize_query(value) when is_binary(value) and value !== "",
    do: String.downcase(value)

  defp normalize_query(_), do: nil

  defp matches?(entry, name_q, id_q) do
    name_match?(entry.name, name_q) and id_match?(entry.tunnel_id, id_q)
  end

  defp name_match?(_name, nil), do: true

  defp name_match?(name, query) when is_binary(name),
    do: name |> String.downcase() |> String.contains?(query)

  defp id_match?(_id, nil), do: true

  defp id_match?(id, query) when is_binary(id),
    do: id |> String.downcase() |> String.contains?(query)

  @doc """
  Provisions a remote-mode tunnel, runs `cloudflared --token <TOKEN>`
  in the foreground, and deprovisions when `cloudflared` exits.

  Blocks the calling process until `cloudflared` exits or `:timeout`
  elapses. Traps exits so deprovision runs even on Ctrl-C interrupts of
  the BEAM (provided the runtime gives us a chance to clean up).

  Returns `:ok` if `cloudflared` ran and exited; `{:error, reason}` if
  provisioning or spawning failed (in which case any partial Cloudflare
  state is best-effort deprovisioned before returning).

  ## Options

    * `:timeout` — max ms to keep `cloudflared` running before stopping
      it (default `:infinity`).
    * `:executable` — overrides `Flared.Config.executable/0`.
    * Other options are forwarded to `open_remote/3` and `close_remote/3`.
  """
  @spec run_remote(name(), [route()], keyword()) :: :ok | {:error, term()}
  def run_remote(name, routes, opts \\ [])
      when is_binary(name) and name !== "" and is_list(routes) and is_list(opts) do
    Process.flag(:trap_exit, true)
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)
    {executable, opts} = pop_executable(opts)

    case open_remote(name, routes, opts) do
      {:ok, %{tunnel_token: token} = info} when is_binary(token) and token !== "" ->
        run_with_spawn(
          fn -> spawn_with_token(executable, token) end,
          timeout,
          fn -> close_remote(name, routes, opts) end,
          info
        )

      {:ok, _info} ->
        _ = close_remote(name, routes, opts)
        {:error, :missing_token}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Provisions a local-mode tunnel, runs `cloudflared --config <path>
  tunnel run` in the foreground, and deprovisions when `cloudflared`
  exits.

  See `run_remote/3` for blocking/exit behavior.

  ## Options

    * `:cloudflared_dir` — directory for local files.
    * `:timeout` — max ms to keep `cloudflared` running (default
      `:infinity`).
    * `:executable` — overrides `Flared.Config.executable/0`.
    * Other options are forwarded to `open_local/3` and `close_local/3`.
  """
  @spec run_local(name(), [route()], keyword()) :: :ok | {:error, term()}
  def run_local(name, routes, opts \\ [])
      when is_binary(name) and name !== "" and is_list(routes) and is_list(opts) do
    Process.flag(:trap_exit, true)
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)
    {executable, opts} = pop_executable(opts)

    case open_local(name, routes, opts) do
      {:ok, %{config_path: path} = info} when is_binary(path) and path !== "" ->
        run_with_spawn(
          fn -> spawn_with_config(executable, path) end,
          timeout,
          fn -> close_local(name, routes, opts) end,
          info
        )

      {:ok, _info} ->
        _ = close_local(name, routes, opts)
        {:error, :missing_local_files}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Runs `cloudflared` against artifacts that already exist and blocks
  until the OS process exits or `:timeout` ms elapses.

  Unlike `run_remote/3` and `run_local/3`, this function does not
  create or destroy any Cloudflare-side resources. It does manage one
  piece of local state: a PID file at `priv/tmp/<name>.pid` (under the
  `:flared` app's priv dir) so that `down/1` can find and stop the
  running process. The PID file is written immediately after spawn and
  removed on clean exit. If a PID file already exists for `name` and
  the recorded PID is still alive, the call is rejected to avoid
  accidental dual-run. Stale PID files (recorded PID no longer alive)
  are silently overwritten.

  Two run modes:

    * **Remote** (`:token` option, or the `TUNNEL_TOKEN` env var):
      authenticates with a tunnel token. The token is forwarded to
      `cloudflared` via the `TUNNEL_TOKEN` environment variable so it
      never appears in argv.
    * **Local** (`:config` option): runs against an existing local
      config file. Spawns `cloudflared --config <path> tunnel run`.

  Exactly one mode must be selected.

  ## Options

    * `:token` — connector token; selects remote mode. Mutually
      exclusive with `:config`.
    * `:config` — path to a cloudflared config file; selects local
      mode. Mutually exclusive with `:token`.
    * `:executable` — overrides `Flared.Config.executable/0`.
    * `:timeout` — max ms to block waiting for cloudflared to exit
      (default `:infinity`).

  When neither `:token` nor `:config` is supplied, the `TUNNEL_TOKEN`
  environment variable is used as a fallback for remote mode. An
  ambient `TUNNEL_TOKEN` combined with an explicit `:config` is not a
  conflict — the explicit option wins.
  """
  @spec up(name(), keyword()) :: :ok | {:error, term()}
  def up(name, opts \\ [])
      when is_binary(name) and name !== "" and is_list(opts) do
    executable = opts[:executable] || Config.executable()
    timeout = Keyword.get(opts, :timeout, :infinity)
    env_token = System.get_env("TUNNEL_TOKEN")

    with :ok <- ensure_no_live_pid_file(name),
         {:ok, mode} <- validate_up_mode(opts, env_token),
         command = build_up_command(executable, mode),
         env = build_up_env(mode),
         {:ok, exec_pid, os_pid} <- spawn_up(command, env) do
      ref = Process.monitor(exec_pid)
      PidFile.write(name, os_pid)
      result = wait_for_up_exit(exec_pid, ref, timeout)
      PidFile.delete(name)
      result
    end
  end

  @doc """
  Stops `cloudflared` processes that were started by `up/2`.

  Reads PID files from `priv/tmp/<name>.pid` (under the `:flared` app's
  priv dir) and signals each matching tunnel process. Removes the PID
  file once the process exits.

  This is a local-machine operation only: it does not touch
  Cloudflare-side resources. To deprovision, use `close_remote/3` or
  `close_local/3`. Stale entries (PID file present but PID not alive)
  are cleaned up without signalling.

  Returns `{:ok, entries}` where each entry records the `name`, `pid`,
  and `outcome` of one matched tunnel.

  ## Options

    * `:name` — stop only this tunnel. When omitted, every PID file in
      the resolved directory is matched.
    * `:timeout` — TERM grace period in ms before SIGKILL (default
      `10_000`). Ignored in `:force` and `:dry_run` modes.
    * `:force` — skip TERM, send SIGKILL immediately. Mutually
      exclusive with `:dry_run`.
    * `:dry_run` — list matched tunnels without signalling. Mutually
      exclusive with `:force`.
  """
  @spec down(keyword()) :: {:ok, [down_entry()]} | {:error, :conflicting_actions}
  def down(opts \\ []) when is_list(opts) do
    with {:ok, mode} <- validate_down_flags(opts) do
      timeout = opts[:timeout] || @down_default_timeout_ms
      entries = PidFile.list() |> filter_entries_by_name(opts[:name])
      {:ok, Enum.map(entries, fn {name, pid} -> stop_one(mode, name, pid, timeout) end)}
    end
  end

  @doc false
  @spec validate_up_mode(keyword(), String.t() | nil) ::
          {:ok, up_mode()} | {:error, :missing_mode | :conflicting_modes}
  def validate_up_mode(opts, env_token \\ nil) do
    flag_token = present(opts[:token])
    config = present(opts[:config])
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
  @spec build_up_command(String.t(), up_mode()) :: String.t()
  def build_up_command(executable, {:remote, _token}) do
    "#{executable} tunnel run"
  end

  def build_up_command(executable, {:config, path}) do
    "#{executable} --config #{path} tunnel run"
  end

  @doc false
  @spec build_up_env(up_mode()) :: [{charlist(), charlist()}]
  def build_up_env({:remote, token}),
    do: [{~c"TUNNEL_TOKEN", String.to_charlist(token)}]

  def build_up_env({:config, _path}), do: []

  @doc false
  @spec validate_down_flags(keyword()) ::
          {:ok, down_mode()} | {:error, :conflicting_actions}
  def validate_down_flags(opts) do
    case {opts[:dry_run], opts[:force]} do
      {true, true} -> {:error, :conflicting_actions}
      {true, _} -> {:ok, :dry_run}
      {_, true} -> {:ok, :force}
      _ -> {:ok, :graceful}
    end
  end

  @doc false
  @spec filter_entries_by_name([{name(), pos_integer()}], name() | nil) ::
          [{name(), pos_integer()}]
  def filter_entries_by_name(entries, nil), do: entries

  def filter_entries_by_name(entries, name) when is_binary(name) do
    Enum.filter(entries, fn {n, _pid} -> n === name end)
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

  defp spawn_up(command, env) do
    case Exexec.run_link(command, env: env, stdout: :print, stderr: :print) do
      {:ok, _exec_pid, _os_pid} = ok -> ok
      {:error, reason} -> {:error, {:spawn_failed, reason}}
    end
  end

  defp wait_for_up_exit(exec_pid, ref, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^exec_pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^exec_pid, reason} ->
        {:error, {:cloudflared_exited, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        _ = stop_cloudflared(exec_pid)
        {:error, :cloudflared_timed_out}
    end
  end

  defp stop_one(_mode, name, pid, _timeout) when not is_integer(pid) do
    PidFile.delete(name)
    %{name: name, pid: pid, outcome: :invalid_pid}
  end

  defp stop_one(:dry_run, name, pid, _timeout) do
    outcome = if pid_alive?(pid), do: :would_stop, else: :stale
    %{name: name, pid: pid, outcome: outcome}
  end

  defp stop_one(mode, name, pid, timeout) do
    outcome =
      if pid_alive?(pid) do
        signal_alive(mode, pid, timeout)
      else
        :stale
      end

    PidFile.delete(name)
    %{name: name, pid: pid, outcome: outcome}
  end

  defp signal_alive(:force, pid, _timeout) do
    send_signal(pid, "KILL")
    :killed
  end

  defp signal_alive(:graceful, pid, timeout) do
    send_signal(pid, "TERM")

    if poll_until_dead(pid, System.monotonic_time(:millisecond) + timeout) do
      :stopped
    else
      send_signal(pid, "KILL")
      :escalated
    end
  end

  defp poll_until_dead(pid, deadline) do
    cond do
      not pid_alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@down_poll_interval_ms)
        poll_until_dead(pid, deadline)
    end
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp pid_alive?(_), do: false

  defp send_signal(pid, signal) when is_integer(pid) and pid > 0 do
    System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp present(value) when is_binary(value) and value !== "", do: value
  defp present(_), do: nil

  defp run_with_spawn(spawn_fun, timeout, deprovision_fun, _info) do
    case spawn_fun.() do
      {:ok, exec_pid, _os_pid} ->
        result = wait_for_cloudflared(exec_pid, timeout)
        _ = deprovision_fun.()
        result

      {:error, _} = error ->
        _ = deprovision_fun.()
        error
    end
  end

  defp wait_for_cloudflared(exec_pid, timeout) do
    receive do
      {:EXIT, ^exec_pid, :normal} ->
        :ok

      {:EXIT, ^exec_pid, reason} ->
        Logger.warning("cloudflared exited: #{inspect(reason)}")
        :ok
    after
      timeout ->
        _ = stop_cloudflared(exec_pid)
        :ok
    end
  end

  defp spawn_with_token(executable, token) do
    command = "#{executable} tunnel run"
    env = [{~c"TUNNEL_TOKEN", String.to_charlist(token)}]

    case Exexec.run_link(command, env: env, stdout: :print, stderr: :print) do
      {:ok, _exec_pid, _os_pid} = ok -> ok
      {:error, reason} -> {:error, {:spawn_failed, reason}}
    end
  end

  defp spawn_with_config(executable, config_path) do
    case Exexec.run_link("#{executable} --config #{config_path} tunnel run",
           stdout: :print,
           stderr: :print
         ) do
      {:ok, _exec_pid, _os_pid} = ok -> ok
      {:error, reason} -> {:error, {:spawn_failed, reason}}
    end
  end

  defp stop_cloudflared(pid) do
    case Exexec.stop(pid) do
      :ok -> :ok
      {:error, :no_process} -> :ok
      other -> other
    end
  end

  defp pop_executable(opts) do
    case Keyword.pop(opts, :executable) do
      {path, rest} when is_binary(path) and path !== "" -> {path, rest}
      {_, rest} -> {Config.executable(), rest}
    end
  end

  defp fetch_account_id(opts) do
    account_id = opts[:account_id] || Config.account_id()

    if is_binary(account_id) and account_id !== "" do
      {:ok, account_id}
    else
      {:error, :missing_account_id}
    end
  end
end
