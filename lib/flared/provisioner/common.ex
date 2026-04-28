defmodule Flared.Provisioner.Common do
  @moduledoc """
  Cloudflare API request helpers and mode-agnostic route parsing shared
  by `Flared.Provisioner.Local` and `Flared.Provisioner.Remote`.

  Both provisioners follow the same shape for the Cloudflare-touching parts
  of their `provision/3` and `deprovision/3` flows: find or create the
  tunnel, ensure DNS CNAMEs, fetch the connector token, delete DNS, delete
  the tunnel. Those steps live here. The mode-specific bits (writing local
  config files for `Local`, pushing ingress via the API for `Remote`) stay
  in their respective modules.

  Route parsing (`parse_route/1`) is identical in both modes, so it lives
  here as well. Per-mode validation and config reads remain in the caller
  modules.
  """

  alias Flared.{Config, DNS, Tunnels, Zones}

  @type route :: %{
          required(:hostname) => String.t(),
          required(:service) => String.t(),
          optional(:ttl) => non_neg_integer(),
          optional(:zone_id) => String.t()
        }

  @type tunnel :: %{
          required(:id) => String.t() | nil,
          required(:name) => String.t(),
          optional(:token) => String.t() | nil
        }

  @doc """
  Returns a tunnel struct (`%{id, name, token}`) for the given name.

  In dry-run mode, looks up the tunnel without creating it; a missing
  tunnel returns `%{id: nil, ...}` so downstream steps can produce a
  meaningful preview. In live mode, delegates to
  `Flared.Tunnels.find_or_create_tunnel/3`.
  """
  @spec find_or_create_tunnel(String.t(), String.t(), boolean(), keyword()) ::
          {:ok, tunnel()} | {:error, term()}
  def find_or_create_tunnel(account_id, tunnel_name, true = _dry_run?, opts) do
    case Tunnels.find_tunnel(account_id, tunnel_name, opts) do
      {:ok, %{"id" => id, "name" => name}} -> {:ok, %{id: id, name: name, token: nil}}
      {:ok, nil} -> {:ok, %{id: nil, name: tunnel_name, token: nil}}
      {:error, _} = error -> error
    end
  end

  def find_or_create_tunnel(account_id, tunnel_name, false = _dry_run?, opts) do
    Tunnels.find_or_create_tunnel(account_id, tunnel_name, opts)
  end

  @doc """
  Looks up an existing tunnel by name without creating it.

  A missing tunnel is reported as `%{id: nil, ...}` rather than an error so
  callers can still produce DNS/file deletion plans against the planned
  name during deprovision.
  """
  @spec find_existing_tunnel(String.t(), String.t(), keyword()) ::
          {:ok, tunnel()} | {:error, term()}
  def find_existing_tunnel(account_id, tunnel_name, opts) do
    case Tunnels.find_tunnel(account_id, tunnel_name, opts) do
      {:ok, %{"id" => id, "name" => name}} -> {:ok, %{id: id, name: name, token: nil}}
      {:ok, nil} -> {:ok, %{id: nil, name: tunnel_name, token: nil}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Ensures a CNAME record exists for each route, pointing at the tunnel.

  Routes are processed concurrently (`max_concurrency: concurrency`).
  In dry-run mode the desired record shape is returned without writes.
  """
  @spec ensure_dns(list(map()), tunnel(), list(route()), pos_integer(), boolean(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def ensure_dns(zones, tunnel, routes, concurrency, dry_run?, opts) do
    tunnel_id = tunnel.id || "<tunnel_uuid>"

    routes
    |> Task.async_stream(
      fn route -> ensure_dns_for_route(zones, tunnel_id, route, dry_run?, opts) end,
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

  @doc """
  Returns the connector token for a tunnel.

  Dry-runs short-circuit to `{:ok, nil}`. If the tunnel struct already
  carries a non-empty token (set by `Tunnels.find_or_create_tunnel/3` on
  newly created tunnels) it is reused; otherwise the token is fetched
  via `Flared.Tunnels.get_token/3`.
  """
  @spec fetch_token(String.t(), tunnel(), boolean(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def fetch_token(_account_id, _tunnel, true = _dry_run?, _opts), do: {:ok, nil}

  def fetch_token(account_id, tunnel, false = _dry_run?, opts) do
    case tunnel[:token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> Tunnels.get_token(account_id, tunnel.id, opts)
    end
  end

  @doc """
  Deletes DNS records for the given routes when they point at the tunnel.

  When `delete_dns?` is `false`, returns `:skipped` results without
  touching Cloudflare. Only records whose `content` matches
  `<tunnel_uuid>.cfargotunnel.com` are removed; mismatches and
  unexpected shapes are reported as `:skipped` with a reason.
  """
  @spec maybe_delete_dns(
          list(map()),
          tunnel(),
          list(route()),
          pos_integer(),
          boolean(),
          boolean(),
          keyword()
        ) :: {:ok, list(map())} | {:error, term()}
  def maybe_delete_dns(_zones, _tunnel, routes, _concurrency, _dry_run?, false, _opts) do
    results =
      Enum.map(routes, fn route ->
        %{hostname: route.hostname, zone_id: route[:zone_id], status: :skipped, reason: :dns_kept}
      end)

    {:ok, results}
  end

  def maybe_delete_dns(zones, tunnel, routes, concurrency, dry_run?, true, opts) do
    tunnel_id = tunnel.id

    routes
    |> Task.async_stream(
      fn route -> delete_dns_for_route(zones, tunnel_id, route, dry_run?, opts) end,
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

  @doc """
  Deletes the Cloudflare tunnel when `delete_tunnel?` is true.

  A `nil` tunnel id (tunnel was never found) reports `:noop`. Dry-runs
  with a present id report `:dry_run` without calling the API.
  """
  @spec maybe_delete_tunnel(String.t(), tunnel(), boolean(), boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def maybe_delete_tunnel(_account_id, _tunnel, _dry_run?, false = _delete_tunnel?, _opts) do
    {:ok, %{status: :skipped, reason: :tunnel_kept}}
  end

  def maybe_delete_tunnel(_account_id, %{id: nil}, _dry_run?, true = _delete_tunnel?, _opts) do
    {:ok, %{status: :noop}}
  end

  def maybe_delete_tunnel(
        _account_id,
        %{id: tunnel_id},
        true = _dry_run?,
        true = _delete_tunnel?,
        _opts
      )
      when is_binary(tunnel_id) do
    {:ok, %{status: :dry_run}}
  end

  def maybe_delete_tunnel(
        account_id,
        %{id: tunnel_id},
        false = _dry_run?,
        true = _delete_tunnel?,
        opts
      )
      when is_binary(tunnel_id) do
    case Tunnels.delete_tunnel(account_id, tunnel_id, opts) do
      {:ok, _} -> {:ok, %{status: :deleted}}
      {:error, _} = error -> error
    end
  end

  defp ensure_dns_for_route(zones, tunnel_id, route, dry_run?, opts) do
    with {:ok, zone_id} <- route_zone_id(route, zones),
         {:ok, result} <- upsert_cname(zone_id, tunnel_id, route, dry_run?, opts) do
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

  defp upsert_cname(_zone_id, tunnel_id, route, true = _dry_run?, _opts) do
    record_opts = [ttl: Map.get(route, :ttl, dns_default_ttl())]
    desired = DNS.desired_record(route.hostname, tunnel_id, record_opts)
    {:ok, %{hostname: route.hostname, desired: desired, status: :dry_run}}
  end

  defp upsert_cname(zone_id, tunnel_id, route, false = _dry_run?, opts) do
    ensure_opts = Keyword.put(opts, :ttl, Map.get(route, :ttl, dns_default_ttl()))

    case DNS.upsert_cname(zone_id, route.hostname, tunnel_id, ensure_opts) do
      {:ok, %{status: status, record_id: record_id}} ->
        {:ok, %{hostname: route.hostname, status: status, record_id: record_id}}

      {:error, _} = error ->
        error
    end
  end

  defp delete_dns_for_route(zones, tunnel_id, route, dry_run?, opts) do
    with {:ok, zone_id} <- route_zone_id(route, zones) do
      delete_dns_record(zone_id, route.hostname, tunnel_id, dry_run?, opts)
    end
  end

  defp delete_dns_record(zone_id, hostname, nil, _dry_run?, _opts) do
    {:ok, %{hostname: hostname, zone_id: zone_id, status: :skipped, reason: :tunnel_not_found}}
  end

  defp delete_dns_record(zone_id, hostname, tunnel_id, true = _dry_run?, opts) do
    target = "#{tunnel_id}.cfargotunnel.com"

    case DNS.find_cname(zone_id, hostname, opts) do
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

  defp delete_dns_record(zone_id, hostname, tunnel_id, false = _dry_run?, opts) do
    target = "#{tunnel_id}.cfargotunnel.com"

    case DNS.find_cname(zone_id, hostname, opts) do
      {:ok, nil} ->
        {:ok, %{hostname: hostname, zone_id: zone_id, status: :noop}}

      {:ok, %{"id" => record_id, "content" => ^target}} ->
        case DNS.delete_record(zone_id, record_id, opts) do
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

  defp dns_default_ttl do
    defaults = Config.dns()
    ttl = Map.get(defaults, :ttl) || Map.get(defaults, "ttl") || 1
    if is_integer(ttl) and ttl >= 1, do: ttl, else: 1
  end

  @doc """
  Parses a single `--route` flag value into a route map.

  Format: `<hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`. The
  parsed shape is identical for `Flared.Provisioner.Local` and
  `Flared.Provisioner.Remote`.

  ## Examples

      iex> Flared.Provisioner.Common.parse_route("chat.example.com=http://localhost:4000")
      {:ok, %{hostname: "chat.example.com", service: "http://localhost:4000"}}

      iex> Flared.Provisioner.Common.parse_route("chat.example.com=http://localhost:4000,ttl=60,zone_id=abc")
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
