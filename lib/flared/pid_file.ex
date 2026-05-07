defmodule Flared.PidFile do
  @moduledoc """
  Read/write PID files for tunnels brought up by `mix flared.tunnel.up`.

  Each tunnel name maps to a `<name>.pid` text file. The file contents
  are the OS PID of the running `cloudflared` process and nothing else.

  All public functions accept an optional `opts` keyword. The directory
  the PID files live in is resolved by the first match in this chain:

  1. `opts[:dir]` — explicit override (used by tests)
  2. `Flared.Config.tmp_dir/0` — application configuration
  3. The compiled-in default (`priv/tmp/` of the `:flared` app)

  Callers therefore do not need to pass a directory in normal use.
  """

  alias Flared.Config

  @type name :: String.t()
  @type pid_int :: pos_integer()
  @type opts :: [dir: String.t()]

  @spec default_dir() :: String.t()
  def default_dir do
    :flared |> :code.priv_dir() |> to_string() |> Path.join("tmp")
  end

  @doc "Path to the PID file for `name`, using the resolved directory."
  @spec path(name(), opts()) :: String.t()
  def path(name, opts \\ []) when is_binary(name) do
    Path.join(resolve_dir(opts), "#{name}.pid")
  end

  @doc """
  Write `pid` to the PID file for `name`. Creates the directory if needed.

  Overwrites any existing file. Caller is responsible for checking
  whether a previous PID is still alive.
  """
  @spec write(name(), pid_int(), opts()) :: :ok
  def write(name, pid, opts \\ []) when is_integer(pid) and pid > 0 do
    dir = resolve_dir(opts)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.pid"), Integer.to_string(pid))
    :ok
  end

  @doc """
  Read the PID for `name`.

  Returns `{:error, :not_found}` if the file is absent and
  `{:error, :corrupt}` if the contents do not parse as a positive
  integer.
  """
  @spec read(name(), opts()) :: {:ok, pid_int()} | {:error, :not_found | :corrupt}
  def read(name, opts \\ []) do
    case File.read(path(name, opts)) do
      {:ok, contents} ->
        case Integer.parse(String.trim(contents)) do
          {pid, ""} when pid > 0 -> {:ok, pid}
          _ -> {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:error, :not_found}
    end
  end

  @doc "Delete the PID file for `name`. No-op if missing."
  @spec delete(name(), opts()) :: :ok
  def delete(name, opts \\ []) do
    _ = File.rm(path(name, opts))
    :ok
  end

  @doc """
  List `{name, pid}` pairs for every readable `.pid` file in the
  resolved directory.

  Files that fail to parse are silently skipped. Returns `[]` if the
  directory does not exist.
  """
  @spec list(opts()) :: [{name(), pid_int()}]
  def list(opts \\ []) do
    dir = resolve_dir(opts)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".pid"))
        |> Enum.flat_map(fn entry ->
          name = Path.rootname(entry, ".pid")

          case read(name, dir: dir) do
            {:ok, pid} -> [{name, pid}]
            _ -> []
          end
        end)

      {:error, :enoent} ->
        []
    end
  end

  defp resolve_dir(opts) do
    Keyword.get(opts, :dir) || Config.tmp_dir() || default_dir()
  end
end
