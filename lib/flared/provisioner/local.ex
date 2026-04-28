defmodule Flared.Provisioner.Local do
  @moduledoc """
  Provisions Cloudflare tunnels in **local mode** with on-disk
  `cloudflared` config.

  In local mode, ingress rules are written to a `config.yml` file on
  disk and the connector token is rewritten as a `<UUID>.json`
  credentials file. `cloudflared` is launched with
  `--config <path> tunnel run` and reads both files itself.

  See `Flared.Provisioner.Remote` for the API-pushed counterpart.

  ## Configuration

  Secrets and defaults are read from `Flared.Config` (application env).
  Required: `:api_token`, `:account_id`. DNS records are always
  created/updated with `proxied: true`. The directory the local files
  are written to is resolved by `Flared.Config.cloudflared_dir/0`.

  ## Route format

  Each route is a map like:

    - `:hostname` (required) — e.g. `"chat.example.com"`
    - `:service` (required) — e.g. `"http://localhost:4000"`
    - `:ttl` (optional) — integer TTL (`1` is "auto" in Cloudflare)
    - `:zone_id` (optional) — override zone resolution
  """

  alias Flared.{Config, ConfigYML, Credentials, Zones}
  alias Flared.Provisioner.Common

  @type route :: %{
          required(:hostname) => String.t(),
          required(:service) => String.t(),
          optional(:ttl) => non_neg_integer(),
          optional(:zone_id) => String.t()
        }

  @type result :: %{
          required(:tunnel_id) => String.t() | nil,
          required(:tunnel_name) => String.t(),
          required(:config_path) => Path.t() | nil,
          required(:credentials_path) => Path.t() | nil,
          required(:routes) => list(route()),
          required(:dns) => list(map()),
          required(:dry_run?) => boolean()
        }

  @type file_result :: %{
          required(:path) => Path.t(),
          required(:status) => :deleted | :noop | :dry_run | :error,
          optional(:reason) => term()
        }

  @type deprovision_result :: %{
          required(:tunnel_id) => String.t() | nil,
          required(:tunnel_name) => String.t(),
          required(:dns) => list(map()),
          required(:tunnel) => map(),
          required(:files) => list(file_result()),
          required(:dry_run?) => boolean()
        }

  @doc """
  Provisions a tunnel + DNS records and writes the local `cloudflared`
  artifacts (`config.yml` and `<UUID>.json` credentials).

  Unlike `Flared.Provisioner.Remote.provision/3`, this does **not**
  push ingress rules to the Cloudflare API. Instead it writes a local
  `config.yml` so that `cloudflared --config <path> tunnel run` can
  read the ingress configuration directly.

  The config directory is resolved via `Flared.Config.cloudflared_dir/0` —
  it is created if it does not exist.

  When `dry_run?: true`, no Cloudflare mutation endpoints are called
  and no files are written. The returned result contains the planned
  `:config_path` and `:credentials_path` so callers can preview them.

  ## Options

      - `:account_id` - Cloudflare account ID (overrides env/config)
      - `:concurrency` - DNS upsert concurrency (default: `System.schedulers_online/0`)
      - `:cloudflared_dir` - directory for local `cloudflared` files (resolved via `Flared.Config.cloudflared_dir/0`)
      - `:dry_run?` - if true, do not mutate
      - `:token` - Cloudflare API token (overrides app config)
  """
  @spec provision(String.t(), list(route()), keyword()) ::
          {:ok, result()} | {:error, term()}
  def provision(tunnel_name, routes, opts \\ [])
      when is_binary(tunnel_name) and tunnel_name !== "" and is_list(routes) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    cloudflared_dir = opts[:cloudflared_dir] || Config.cloudflared_dir()

    with {:ok, account_id} <- fetch_account_id(opts),
         :ok <- validate_routes(routes),
         {:ok, tunnel} <- Common.find_or_create_tunnel(account_id, tunnel_name, dry_run?, opts),
         {:ok, zones} <- Zones.list_zones(account_id, opts),
         {:ok, dns_results} <-
           Common.ensure_dns(zones, tunnel, routes, concurrency, dry_run?, opts),
         {:ok, token} <- Common.fetch_token(account_id, tunnel, dry_run?, opts),
         {:ok, config_path, credentials_path} <-
           write_local_files(cloudflared_dir, tunnel, tunnel_name, routes, token, dry_run?) do
      {:ok,
       %{
         tunnel_id: tunnel.id,
         tunnel_name: tunnel_name,
         config_path: config_path,
         credentials_path: credentials_path,
         routes: routes,
         dns: dns_results,
         dry_run?: dry_run?
       }}
    end
  end

  @doc """
  Mirror of `Flared.Provisioner.Remote.deprovision/3` for local-mode
  tunnels.

  In addition to deleting the Cloudflare tunnel and DNS records, this
  best-effort deletes the local `config.yml` and `<UUID>.json` files
  written by `provision/3`. File outcomes are returned in the
  `:files` list with per-file `:status`.

  The config directory is resolved via `Flared.Config.cloudflared_dir/0`.

  ## Options

      - `:account_id` - Cloudflare account ID (overrides env/config)
      - `:concurrency` - DNS delete concurrency (default: `System.schedulers_online/0`)
      - `:cloudflared_dir` - directory containing the local `cloudflared` files (resolved via `Flared.Config.cloudflared_dir/0`)
      - `:dry_run?` - if true, do not mutate
      - `:delete_dns?` - default true; set false to keep DNS
      - `:delete_tunnel?` - default true; set false to keep tunnel
      - `:delete_files?` - default true; set false to keep local files
      - `:token` - Cloudflare API token (overrides app config)
  """
  @spec deprovision(String.t(), list(route()), keyword()) ::
          {:ok, deprovision_result()} | {:error, term()}
  def deprovision(tunnel_name, routes, opts \\ [])
      when is_binary(tunnel_name) and tunnel_name !== "" and is_list(routes) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    delete_dns? = Keyword.get(opts, :delete_dns?, true)
    delete_tunnel? = Keyword.get(opts, :delete_tunnel?, true)
    delete_files? = Keyword.get(opts, :delete_files?, true)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    cloudflared_dir = opts[:cloudflared_dir] || Config.cloudflared_dir()

    with {:ok, account_id} <- fetch_account_id(opts),
         :ok <- validate_routes(routes),
         {:ok, tunnel} <- Common.find_existing_tunnel(account_id, tunnel_name, opts),
         {:ok, zones} <- Zones.list_zones(account_id, opts),
         {:ok, dns_results} <-
           Common.maybe_delete_dns(
             zones,
             tunnel,
             routes,
             concurrency,
             dry_run?,
             delete_dns?,
             opts
           ),
         {:ok, tunnel_result} <-
           Common.maybe_delete_tunnel(account_id, tunnel, dry_run?, delete_tunnel?, opts) do
      file_results = maybe_delete_local_files(cloudflared_dir, tunnel, dry_run?, delete_files?)

      {:ok,
       %{
         tunnel_id: tunnel.id,
         tunnel_name: tunnel_name,
         dns: dns_results,
         tunnel: tunnel_result,
         files: file_results,
         dry_run?: dry_run?
       }}
    end
  end

  defp fetch_account_id(opts) do
    account_id = opts[:account_id] || Config.account_id()

    if is_binary(account_id) and account_id != "" do
      {:ok, account_id}
    else
      {:error, :missing_account_id}
    end
  end

  defp validate_routes([]), do: {:error, :missing_routes}

  defp validate_routes(routes) do
    Enum.reduce_while(routes, :ok, fn route, :ok ->
      case validate_route(route) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_route(%{hostname: hostname, service: service} = route)
       when is_binary(service) do
    with :ok <- validate_hostname(hostname),
         :ok <- validate_service(service),
         :ok <- validate_ttl(route) do
      :ok
    end
  end

  defp validate_route(other), do: {:error, {:invalid_route_shape, other}}

  defp validate_hostname(hostname) when is_binary(hostname) do
    cond do
      hostname == "" -> {:error, :empty_hostname}
      String.contains?(hostname, " ") -> {:error, {:invalid_hostname, hostname}}
      not String.contains?(hostname, ".") -> {:error, {:invalid_hostname, hostname}}
      true -> :ok
    end
  end

  defp validate_hostname(other), do: {:error, {:invalid_hostname, other}}

  defp validate_service(service) when is_binary(service) do
    uri = URI.parse(service)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      :ok
    else
      {:error, {:invalid_service, service}}
    end
  end

  defp validate_service(other), do: {:error, {:invalid_service, other}}

  defp validate_ttl(%{ttl: ttl}) when is_integer(ttl) and ttl >= 1, do: :ok
  defp validate_ttl(%{ttl: ttl}), do: {:error, {:invalid_ttl, ttl}}
  defp validate_ttl(_), do: :ok

  defp write_local_files(cloudflared_dir, tunnel, _tunnel_name, _routes, _token, true = _dry_run?) do
    tunnel_id = tunnel.id
    expanded_dir = Path.expand(cloudflared_dir)

    config_path = Path.join(expanded_dir, "config.yml")

    credentials_path =
      if is_binary(tunnel_id) and tunnel_id !== "" do
        Credentials.path(tunnel_id, cloudflared_dir: expanded_dir)
      end

    {:ok, config_path, credentials_path}
  end

  defp write_local_files(cloudflared_dir, tunnel, tunnel_name, routes, token, false = _dry_run?) do
    tunnel_id = tunnel.id
    expanded_dir = Path.expand(cloudflared_dir)

    with :ok <- ensure_local_inputs(tunnel_id, token),
         credentials_path = Credentials.path(tunnel_id, cloudflared_dir: expanded_dir),
         {:ok, config_path} <-
           ConfigYML.generate_config_yml(expanded_dir, routes, tunnel_id, credentials_path),
         {:ok, ^credentials_path} <-
           Credentials.write(tunnel_id, tunnel_name, token, cloudflared_dir: expanded_dir) do
      {:ok, config_path, credentials_path}
    end
  end

  defp ensure_local_inputs(tunnel_id, token) do
    cond do
      not (is_binary(tunnel_id) and tunnel_id !== "") -> {:error, :missing_tunnel_id}
      not (is_binary(token) and token !== "") -> {:error, :missing_token}
      true -> :ok
    end
  end

  defp maybe_delete_local_files(_cloudflared_dir, _tunnel, _dry_run?, false = _delete_files?),
    do: []

  defp maybe_delete_local_files(cloudflared_dir, tunnel, dry_run?, true = _delete_files?) do
    paths =
      [Path.join(cloudflared_dir, "config.yml")]
      |> maybe_append_credentials_path(cloudflared_dir, tunnel.id)

    Enum.map(paths, fn path -> delete_file(path, dry_run?) end)
  end

  defp maybe_append_credentials_path(paths, _cloudflared_dir, nil), do: paths

  defp maybe_append_credentials_path(paths, cloudflared_dir, tunnel_id) when is_binary(tunnel_id),
    do: paths ++ [Credentials.path(tunnel_id, cloudflared_dir: cloudflared_dir)]

  defp delete_file(path, true = _dry_run?) do
    if File.exists?(path) do
      %{path: path, status: :dry_run}
    else
      %{path: path, status: :noop}
    end
  end

  defp delete_file(path, false = _dry_run?) do
    case File.rm(path) do
      :ok -> %{path: path, status: :deleted}
      {:error, :enoent} -> %{path: path, status: :noop}
      {:error, reason} -> %{path: path, status: :error, reason: reason}
    end
  end
end
