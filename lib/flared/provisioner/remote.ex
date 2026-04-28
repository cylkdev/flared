defmodule Flared.Provisioner.Remote do
  @moduledoc """
  Provisions Cloudflare tunnels in **remote mode** via the Cloudflare API.

  In remote mode, ingress rules are pushed to the Cloudflare API
  (`PUT /accounts/{id}/cfd_tunnel/{id}/configurations`) and
  `cloudflared` is launched with `--token <TOKEN>`. Nothing is written
  to disk — the token is everything `cloudflared` needs.

  See `Flared.Provisioner.Local` for the local-config counterpart.

  ## Configuration

  Secrets and defaults are read from `Flared.Config` (application env).
  Required: `:api_token`, `:account_id`. DNS records are always
  created/updated with `proxied: true`.

  The token must be a **User API Token** (My Profile → API Tokens) with
  `Cloudflare Tunnel:Edit`/`Read` and `DNS:Edit`, `Zone:Read` scoped
  to the zones you will route to.

  ## Route format

  Each route is a map like:

    - `:hostname` (required) — e.g. `"chat.example.com"`
    - `:service` (required) — e.g. `"http://localhost:4000"`
    - `:ttl` (optional) — integer TTL (`1` is "auto" in Cloudflare)
    - `:zone_id` (optional) — override zone resolution
  """

  alias Flared.{Config, Tunnels, Zones}
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
          required(:tunnel_token) => String.t() | nil,
          required(:routes) => list(route()),
          required(:dns) => list(map()),
          required(:dry_run?) => boolean(),
          required(:token_present?) => boolean()
        }

  @type deprovision_result :: %{
          required(:tunnel_id) => String.t() | nil,
          required(:tunnel_name) => String.t(),
          required(:dns) => list(map()),
          required(:tunnel) => map(),
          required(:dry_run?) => boolean()
        }

  @doc """
  Provisions a tunnel, ingress, and DNS records for the given routes.

  When `dry_run?: true`, no Cloudflare mutation endpoints are called.

  ## Options

      - `:account_id` - Cloudflare account ID (overrides env/config)
      - `:concurrency` - DNS upsert concurrency (default: `System.schedulers_online/0`)
      - `:dry_run?` - if true, do not mutate
      - `:token` - Cloudflare API token (overrides app config)
  """
  @spec provision(String.t(), list(route()), keyword()) ::
          {:ok, result()} | {:error, term()}
  def provision(tunnel_name, routes, opts \\ [])
      when is_binary(tunnel_name) and tunnel_name !== "" and is_list(routes) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    with {:ok, account_id} <- fetch_account_id(opts),
         :ok <- validate_routes(routes),
         {:ok, tunnel} <- Common.find_or_create_tunnel(account_id, tunnel_name, dry_run?, opts),
         :ok <- put_config(account_id, tunnel, routes, dry_run?, opts),
         {:ok, zones} <- Zones.list_zones(account_id, opts),
         {:ok, dns_results} <-
           Common.ensure_dns(zones, tunnel, routes, concurrency, dry_run?, opts),
         {:ok, token} <- Common.fetch_token(account_id, tunnel, dry_run?, opts) do
      {:ok,
       %{
         tunnel_id: tunnel.id,
         tunnel_name: tunnel_name,
         tunnel_token: token,
         routes: routes,
         dns: dns_results,
         dry_run?: dry_run?,
         token_present?: is_binary(token) and token !== ""
       }}
    end
  end

  @doc """
  Deprovisions (deletes) DNS records and/or the tunnel.

  DNS records are only deleted when they match the tunnel target
  (`<tunnel_uuid>.cfargotunnel.com`). If the tunnel cannot be found by
  name, DNS deletion is skipped.

  ## Options

      - `:account_id` - Cloudflare account ID (overrides env/config)
      - `:concurrency` - DNS delete concurrency (default: `System.schedulers_online/0`)
      - `:dry_run?` - if true, do not mutate
      - `:delete_dns?` - default true; set false to keep DNS
      - `:delete_tunnel?` - default true; set false to keep tunnel
      - `:token` - Cloudflare API token (overrides app config)
  """
  @spec deprovision(String.t(), list(route()), keyword()) ::
          {:ok, deprovision_result()} | {:error, term()}
  def deprovision(tunnel_name, routes, opts \\ [])
      when is_binary(tunnel_name) and tunnel_name !== "" and is_list(routes) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    delete_dns? = Keyword.get(opts, :delete_dns?, true)
    delete_tunnel? = Keyword.get(opts, :delete_tunnel?, true)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

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
      {:ok,
       %{
         tunnel_id: tunnel.id,
         tunnel_name: tunnel_name,
         dns: dns_results,
         tunnel: tunnel_result,
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

  defp put_config(_account_id, _tunnel, _routes, true = _dry_run?, _opts), do: :ok

  defp put_config(account_id, tunnel, routes, false = _dry_run?, opts) do
    case Tunnels.put_config(account_id, tunnel.id, routes, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end
end
