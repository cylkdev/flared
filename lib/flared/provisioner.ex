defmodule Flared.Provisioner do
  @moduledoc """
  Provisions Cloudflare Tunnel resources via the Cloudflare API.

  This module is the primary library entrypoint for provisioning:

  - Ensures a tunnel exists (create or reuse by name)
  - Pushes the tunnel ingress rules (hostname → service)
  - Upserts DNS CNAME records pointing at the tunnel target

  **Stateless Guarantee**

  Flared does not write any `cloudflared` config files or credentials JSON to disk.
  The mix task prints a `cloudflared tunnel run --token ...` command, and the token
  can be emitted as JSON for piping into a secret store.

  ## Configuration

  Secrets and defaults are read from `Flared.Config` (application env).
  Your config environment can source these from OS env vars if desired
  (typically in `config/runtime.exs`).

  Required:

  - `:cloudflare_api_token`
  - `:cloudflare_account_id`

  Optional:

  - `:cloudflare_tunnel_name` (defaults to `"flare"`)

  DNS defaults (non-secret):

  ```elixir
  config :flared,
    cloudflare_dns_defaults: %{ttl: 1}
  ```

  Note: DNS records are always created/updated with `proxied: true`.

  ## Required Cloudflare API Permissions

  Your cloudflare api key must have the following permissions:

    - `Account -> Cloudflare Tunnel -> Edit`
    - `Account -> Cloudflare Tunnel -> Read`
    - `Account -> Cloudflare Tunnel -> Edit`
    - `Account -> Cloudflare Tunnel -> Read`
    - `Zone -> DNS -> Edit`
    - `Zone -> Zone -> Read`

  Next, add the following scopes:

    - `Include -> Specific zone -> yourdomain.com`

  ## Route format

  Each route is a map like:

  - `:hostname` (required) — e.g. `"chat.example.com"`
  - `:service` (required) — e.g. `"http://localhost:4000"`
  - `:ttl` (optional) — integer TTL (`1` is "auto" in Cloudflare)
  - `:zone_id` (optional) — override zone resolution
  """

  alias Flared.{Client, DNS, Tunnels, Zones}
  alias Flared.Config

  @type route :: %{
          required(:hostname) => String.t(),
          required(:service) => String.t(),
          optional(:ttl) => non_neg_integer(),
          optional(:zone_id) => String.t()
        }

  @type result :: %{
          tunnel_id: String.t() | nil,
          tunnel_name: String.t(),
          tunnel_token: String.t() | nil,
          routes: list(route()),
          dns: list(map()),
          dry_run?: boolean(),
          token_present?: boolean()
        }

  @type deprovision_dns_result :: %{
          required(:hostname) => String.t(),
          required(:zone_id) => String.t() | nil,
          required(:status) => :deleted | :noop | :skipped | :dry_run,
          optional(:record_id) => String.t(),
          optional(:reason) => term()
        }

  @type deprovision_result :: %{
          required(:tunnel_id) => String.t() | nil,
          required(:tunnel_name) => String.t(),
          required(:dns) => list(deprovision_dns_result()),
          required(:tunnel) => %{
            required(:status) => :deleted | :noop | :skipped | :dry_run,
            optional(:reason) => term()
          },
          required(:dry_run?) => boolean()
        }

  @doc """
  Provisions a tunnel, ingress, and DNS records for the given routes.

  When `dry_run?: true`, no mutation endpoints are called. The returned result
  will contain `tunnel_id: nil` if the named tunnel doesn't already exist, and
  DNS results will be returned as `status: :dry_run` with the desired record body.

  ## Options

      - `:account_id` - Cloudflare account ID (overrides env/config)
      - `:tunnel_name` - tunnel name (overrides env/config)
      - `:concurrency` - DNS upsert concurrency (default: `System.schedulers_online/0`)
      - `:dry_run?` - if true, do not mutate
      - `:token` - Cloudflare API token (overrides app config)
  """
  @spec provision(list(route()), keyword()) :: {:ok, result()} | {:error, term()}
  def provision(routes, opts \\ []) when is_list(routes) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    with {:ok, account_id} <- fetch_account_id(opts),
         tunnel_name <- fetch_tunnel_name(opts),
         :ok <- validate_routes(routes),
         {:ok, client} <- Client.new(opts),
         {:ok, tunnel} <- ensure_tunnel(client, account_id, tunnel_name, dry_run?),
         :ok <- put_config(client, account_id, tunnel, routes, dry_run?),
         {:ok, zones} <- Zones.list_zones(client, account_id),
         {:ok, dns_results} <- ensure_dns(client, zones, tunnel, routes, concurrency, dry_run?),
         {:ok, token} <- fetch_token(client, account_id, tunnel, dry_run?) do
      tunnel_id = tunnel[:id]

      {:ok,
       %{
         tunnel_id: tunnel_id,
         tunnel_name: tunnel_name,
         tunnel_token: token,
         routes: routes,
         dns: dns_results,
         dry_run?: dry_run?,
         token_present?: is_binary(token) and token != ""
       }}
    end
  end

  @doc """
  Deprovisions (deletes) DNS records and/or the tunnel.

  DNS safety:

  - DNS records are only deleted when they match the tunnel target
    (`<tunnel_uuid>.cfargotunnel.com`). This avoids deleting unrelated CNAMEs.
  - If the tunnel cannot be found by name, DNS deletion is skipped (no tunnel id to verify).

  ## Options

      - `:account_id` - Cloudflare account ID (overrides env/config)
      - `:tunnel_name` - tunnel name (overrides env/config)
      - `:concurrency` - DNS delete concurrency (default: `System.schedulers_online/0`)
      - `:dry_run?` - if true, do not mutate
      - `:delete_dns?` - default true; set false to keep DNS
      - `:delete_tunnel?` - default true; set false to keep tunnel
      - `:token` - Cloudflare API token (overrides app config)
  """
  @spec deprovision(list(route()), keyword()) :: {:ok, deprovision_result()} | {:error, term()}
  def deprovision(routes, opts \\ []) when is_list(routes) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)
    delete_dns? = Keyword.get(opts, :delete_dns?, true)
    delete_tunnel? = Keyword.get(opts, :delete_tunnel?, true)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    with {:ok, account_id} <- fetch_account_id(opts),
         tunnel_name <- fetch_tunnel_name(opts),
         :ok <- validate_routes(routes),
         {:ok, client} <- Client.new(opts),
         {:ok, tunnel} <- ensure_deprovision_tunnel(client, account_id, tunnel_name),
         {:ok, zones} <- Zones.list_zones(client, account_id),
         {:ok, dns_results} <-
           maybe_delete_dns(client, zones, tunnel, routes, concurrency, dry_run?, delete_dns?),
         {:ok, tunnel_result} <-
           maybe_delete_tunnel(client, account_id, tunnel, dry_run?, delete_tunnel?) do
      {:ok,
       %{
         tunnel_id: tunnel[:id],
         tunnel_name: tunnel_name,
         dns: dns_results,
         tunnel: tunnel_result,
         dry_run?: dry_run?
       }}
    end
  end

  @doc """
  Parses a single `--route` flag value into a route map.

  Format:

  - `<hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`

  ## Examples

      iex> Flared.Provisioner.parse_route("chat.example.com=http://localhost:4000")
      {:ok, %{hostname: "chat.example.com", service: "http://localhost:4000"}}

      iex> Flared.Provisioner.parse_route("chat.example.com=http://localhost:4000,ttl=60,zone_id=abc")
      {:ok, %{hostname: "chat.example.com", service: "http://localhost:4000", ttl: 60, zone_id: "abc"}}
  """
  @spec parse_route(String.t()) :: {:ok, route()} | {:error, term()}
  def parse_route(value) when is_binary(value) do
    [head | rest] = String.split(value, ",", trim: true)

    with {:ok, hostname, service} <- parse_route_head(head),
         {:ok, opts} <- parse_route_kvs(rest) do
      route =
        %{hostname: hostname, service: service}
        |> maybe_put(:zone_id, opts[:zone_id])
        |> maybe_put(:ttl, opts[:ttl])

      {:ok, route}
    end
  rescue
    _ -> {:error, {:invalid_route, value}}
  end

  defp fetch_account_id(opts) do
    account_id = opts[:account_id] || Config.cloudflare_account_id()

    if is_binary(account_id) and account_id != "" do
      {:ok, account_id}
    else
      {:error, :missing_account_id}
    end
  end

  defp fetch_tunnel_name(opts) do
    name = opts[:tunnel_name] || Config.cloudflare_tunnel_name() || "flare"
    if is_binary(name) and name != "", do: name, else: "flare"
  end

  defp validate_routes([]), do: {:error, :missing_routes}

  defp validate_routes(routes) do
    routes
    |> Enum.reduce_while(:ok, fn route, :ok ->
      case validate_route(route) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_route(%{hostname: hostname, service: service} = route) do
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

  defp ensure_tunnel(%Client{} = client, account_id, tunnel_name, true = _dry_run?) do
    case Tunnels.find_tunnel(client, account_id, tunnel_name) do
      {:ok, %{"id" => id, "name" => name}} -> {:ok, %{id: id, name: name, token: nil}}
      {:ok, nil} -> {:ok, %{id: nil, name: tunnel_name, token: nil}}
      {:error, _} = error -> error
    end
  end

  defp ensure_tunnel(%Client{} = client, account_id, tunnel_name, false = _dry_run?) do
    Tunnels.ensure_tunnel(client, account_id, tunnel_name)
  end

  defp ensure_deprovision_tunnel(%Client{} = client, account_id, tunnel_name) do
    case Tunnels.find_tunnel(client, account_id, tunnel_name) do
      {:ok, %{"id" => id, "name" => name}} -> {:ok, %{id: id, name: name, token: nil}}
      {:ok, nil} -> {:ok, %{id: nil, name: tunnel_name, token: nil}}
      {:error, _} = error -> error
    end
  end

  defp put_config(_client, _account_id, _tunnel, _routes, true = _dry_run?), do: :ok

  defp put_config(%Client{} = client, account_id, tunnel, routes, false = _dry_run?) do
    Tunnels.put_config(client, account_id, tunnel[:id], routes)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp ensure_dns(%Client{} = client, zones, tunnel, routes, concurrency, dry_run?)
       when is_list(zones) and is_list(routes) and is_integer(concurrency) and concurrency >= 1 do
    tunnel_id = tunnel[:id] || "<tunnel_uuid>"

    routes
    |> Task.async_stream(
      fn route ->
        ensure_dns_for_route(client, zones, tunnel_id, route, dry_run?)
      end,
      max_concurrency: concurrency,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, result}}, {:ok, acc} -> {:cont, {:ok, [result | acc]}}
      {:ok, {:error, reason}}, _ -> {:halt, {:error, reason}}
      {:exit, reason}, _ -> {:halt, {:error, {:dns_task_exit, reason}}}
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp ensure_dns_for_route(%Client{} = client, zones, tunnel_id, route, dry_run?) do
    with {:ok, zone_id} <- route_zone_id(route, zones),
         {:ok, result} <- ensure_cname(client, zone_id, tunnel_id, route, dry_run?) do
      {:ok, Map.put(result, :zone_id, zone_id)}
    end
  end

  defp route_zone_id(%{zone_id: zone_id} = _route, _zones)
       when is_binary(zone_id) and zone_id != "",
       do: {:ok, zone_id}

  defp route_zone_id(%{hostname: hostname}, zones) when is_binary(hostname) do
    case Zones.resolve_zone_id(hostname, zones) do
      {:ok, zone_id} ->
        {:ok, zone_id}

      {:error, :zone_not_found} ->
        {:error, {:zone_not_found, hostname}}

      {:error, {:ambiguous_zone_match, _, ids}} ->
        {:error, {:ambiguous_zone_match, hostname, ids}}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_cname(%Client{} = _client, _zone_id, tunnel_id, route, true = _dry_run?) do
    opts = [ttl: Map.get(route, :ttl, dns_default_ttl())]
    desired = DNS.desired_record(route.hostname, tunnel_id, opts)
    {:ok, %{hostname: route.hostname, desired: desired, status: :dry_run}}
  end

  defp ensure_cname(%Client{} = client, zone_id, tunnel_id, route, false = _dry_run?) do
    opts = [ttl: Map.get(route, :ttl, dns_default_ttl())]

    case DNS.ensure_cname(client, zone_id, route.hostname, tunnel_id, opts) do
      {:ok, %{status: status, record_id: record_id}} ->
        {:ok, %{hostname: route.hostname, status: status, record_id: record_id}}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_token(_client, _account_id, _tunnel, true = _dry_run?), do: {:ok, nil}

  defp fetch_token(%Client{} = client, account_id, tunnel, false = _dry_run?) do
    case tunnel[:token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> Tunnels.get_token(client, account_id, tunnel[:id])
    end
  end

  defp dns_default_ttl do
    defaults = Config.cloudflare_dns_defaults()
    ttl = Map.get(defaults, :ttl) || Map.get(defaults, "ttl") || 1
    if is_integer(ttl) and ttl >= 1, do: ttl, else: 1
  end

  defp maybe_delete_dns(
         _client,
         _zones,
         _tunnel,
         routes,
         _concurrency,
         _dry_run?,
         false = _delete_dns?
       ) do
    results =
      Enum.map(routes, fn route ->
        %{hostname: route.hostname, zone_id: route[:zone_id], status: :skipped, reason: :dns_kept}
      end)

    {:ok, results}
  end

  defp maybe_delete_dns(
         %Client{} = client,
         zones,
         tunnel,
         routes,
         concurrency,
         dry_run?,
         true = _delete_dns?
       ) do
    tunnel_id = tunnel[:id]

    routes
    |> Task.async_stream(
      fn route ->
        delete_dns_for_route(client, zones, tunnel_id, route, dry_run?)
      end,
      max_concurrency: concurrency,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, result}}, {:ok, acc} -> {:cont, {:ok, [result | acc]}}
      {:ok, {:error, reason}}, _ -> {:halt, {:error, reason}}
      {:exit, reason}, _ -> {:halt, {:error, {:dns_task_exit, reason}}}
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp delete_dns_for_route(%Client{} = client, zones, tunnel_id, route, dry_run?) do
    with {:ok, zone_id} <- route_zone_id(route, zones) do
      delete_dns_record(client, zone_id, route.hostname, tunnel_id, dry_run?)
    end
  end

  defp delete_dns_record(%Client{} = _client, zone_id, hostname, nil, _dry_run?) do
    {:ok, %{hostname: hostname, zone_id: zone_id, status: :skipped, reason: :tunnel_not_found}}
  end

  defp delete_dns_record(%Client{} = client, zone_id, hostname, tunnel_id, true = _dry_run?) do
    target = "#{tunnel_id}.cfargotunnel.com"

    case DNS.find_cname(client, zone_id, hostname) do
      {:ok, nil} ->
        {:ok, %{hostname: hostname, zone_id: zone_id, status: :noop}}

      {:ok, %{"id" => record_id, "content" => ^target}} ->
        {:ok, %{hostname: hostname, zone_id: zone_id, status: :dry_run, record_id: record_id}}

      {:ok, %{"content" => other}} ->
        {:ok,
         %{
           hostname: hostname,
           zone_id: zone_id,
           status: :skipped,
           reason: {:different_target, other}
         }}

      {:ok, record} ->
        {:ok,
         %{
           hostname: hostname,
           zone_id: zone_id,
           status: :skipped,
           reason: {:unexpected_record_shape, record}
         }}

      {:error, _} = error ->
        error
    end
  end

  defp delete_dns_record(%Client{} = client, zone_id, hostname, tunnel_id, false = _dry_run?) do
    target = "#{tunnel_id}.cfargotunnel.com"

    case DNS.find_cname(client, zone_id, hostname) do
      {:ok, nil} ->
        {:ok, %{hostname: hostname, zone_id: zone_id, status: :noop}}

      {:ok, %{"id" => record_id, "content" => ^target}} ->
        case DNS.delete_record(client, zone_id, record_id) do
          {:ok, _} ->
            {:ok, %{hostname: hostname, zone_id: zone_id, status: :deleted, record_id: record_id}}

          {:error, _} = error ->
            error
        end

      {:ok, %{"content" => other}} ->
        {:ok,
         %{
           hostname: hostname,
           zone_id: zone_id,
           status: :skipped,
           reason: {:different_target, other}
         }}

      {:ok, record} ->
        {:ok,
         %{
           hostname: hostname,
           zone_id: zone_id,
           status: :skipped,
           reason: {:unexpected_record_shape, record}
         }}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_delete_tunnel(_client, _account_id, _tunnel, _dry_run?, false = _delete_tunnel?) do
    {:ok, %{status: :skipped, reason: :tunnel_kept}}
  end

  defp maybe_delete_tunnel(_client, _account_id, %{id: nil}, _dry_run?, true = _delete_tunnel?) do
    {:ok, %{status: :noop}}
  end

  defp maybe_delete_tunnel(
         _client,
         _account_id,
         %{id: tunnel_id},
         true = _dry_run?,
         true = _delete_tunnel?
       )
       when is_binary(tunnel_id) do
    {:ok, %{status: :dry_run}}
  end

  defp maybe_delete_tunnel(
         %Client{} = client,
         account_id,
         %{id: tunnel_id},
         false = _dry_run?,
         true = _delete_tunnel?
       )
       when is_binary(tunnel_id) do
    case Tunnels.delete_tunnel(client, account_id, tunnel_id) do
      {:ok, _} -> {:ok, %{status: :deleted}}
      {:error, _} = error -> error
    end
  end

  defp parse_route_head(value) do
    case String.split(value, "=", parts: 2) do
      [hostname, service] when hostname != "" and service != "" ->
        {:ok, String.trim(hostname), String.trim(service)}

      _ ->
        {:error, {:invalid_route_head, value}}
    end
  end

  defp parse_route_kvs(kvs) do
    kvs
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        ["zone_id", value] when value != "" ->
          {:cont, {:ok, Keyword.put(acc, :zone_id, value)}}

        ["ttl", value] ->
          case Integer.parse(value) do
            {ttl, ""} -> {:cont, {:ok, Keyword.put(acc, :ttl, ttl)}}
            _ -> {:halt, {:error, {:invalid_ttl, value}}}
          end

        _ ->
          {:halt, {:error, {:invalid_route_option, part}}}
      end
    end)
    |> case do
      {:ok, opts} -> {:ok, opts}
      {:error, _} = error -> error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
