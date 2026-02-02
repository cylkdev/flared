defmodule Mix.Tasks.Flared.Provision do
  @shortdoc "Provision a Cloudflare Tunnel (stateless) via the Cloudflare API"

  @moduledoc """
  Provisions a Cloudflare Tunnel, ingress rules, and DNS for one or more routes.

  This task is **stateless**: it does not write `cloudflared` config files or
  credentials JSON to disk. It uses the Cloudflare API (via `Req`) to configure
  the tunnel and DNS, then prints a `cloudflared tunnel run --token ...` command.

  ## Configuration

  This task reads Cloudflare credentials/defaults from `Flared.Config` (application env).
  If you want to source values from OS env vars, do it in your application's config
  environment (typically `config/runtime.exs`).

  ## Usage

  ```bash
  mix flared.provision \
    --tunnel-name test \
    --route chat.example.com=http://localhost:4000 \
    --route api.example.com=http://localhost:4001
  ```

  ## Flags

  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--tunnel-name <name>`: tunnel name (overrides app config)
  - `--route <hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`: repeatable, required
  - `--concurrency <n>`: DNS upsert concurrency (default: schedulers_online)
  - `--dry-run`: print planned changes; do not call mutation endpoints
  - `--json`: emit a single JSON object (includes token unless `--dry-run`)
  - `--quiet`: do not print the `cloudflared ... --token ...` line

  DNS records are always created/updated with `proxied: true`.
  """

  use Mix.Task

  alias Flared.Provisioner

  @switches [
    account_id: :string,
    tunnel_name: :string,
    route: :keep,
    concurrency: :integer,
    dry_run: :boolean,
    json: :boolean,
    quiet: :boolean
  ]

  @aliases [
    a: :account_id,
    n: :tunnel_name,
    r: :route,
    c: :concurrency,
    d: :dry_run,
    j: :json,
    q: :quiet
  ]

  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {parsed, _rest, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if invalid != [] do
      invalid
      |> Enum.map(fn {flag, _val} -> flag end)
      |> Enum.uniq()
      |> Enum.each(fn flag ->
        Mix.shell().error("Unknown option: #{flag}")
      end)

      System.halt(1)
    end

    routes =
      parsed
      |> Keyword.get_values(:route)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with {:ok, parsed_routes} <- parse_routes(routes),
         {:ok, result} <- do_provision(parsed, parsed_routes) do
      print_result(result, parsed)
      :ok
    else
      {:error, reason} ->
        Mix.shell().error(format_error(reason))
        System.halt(1)
    end
  end

  defp do_provision(parsed, routes) do
    opts =
      []
      |> maybe_put(:account_id, parsed[:account_id])
      |> maybe_put(:tunnel_name, parsed[:tunnel_name])
      |> Keyword.put(:concurrency, parsed[:concurrency] || System.schedulers_online())
      |> Keyword.put(:dry_run?, parsed[:dry_run] || false)

    Provisioner.provision(routes, opts)
  end

  defp parse_routes([]), do: {:error, :missing_routes}

  defp parse_routes(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn route, {:ok, acc} ->
      case Provisioner.parse_route(route) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = error -> error
    end
  end

  defp print_result(result, parsed) do
    if parsed[:json] do
      json =
        %{
          "tunnel_id" => result.tunnel_id,
          "tunnel_name" => result.tunnel_name,
          "tunnel_token" => result.tunnel_token,
          "token_present?" => result.token_present?,
          "dry_run?" => result.dry_run?,
          "routes" => Enum.map(result.routes, &stringify_route/1),
          "dns" => Enum.map(result.dns, &stringify_dns/1)
        }
        |> Jason.encode!()

      Mix.shell().info(json)
    else
      tunnel_id_display =
        case result.tunnel_id do
          nil -> "(will be created)"
          id -> "(#{id})"
        end

      Mix.shell().info("Tunnel: #{result.tunnel_name} #{tunnel_id_display}")
      Mix.shell().info("Routes: #{length(result.routes)}")

      Enum.each(result.dns, fn dns ->
        hostname = dns.hostname
        status = dns.status

        Mix.shell().info("DNS: #{hostname} => #{status}")
      end)

      if result.dry_run? do
        Mix.shell().info("Dry run: no changes applied")
      end

      unless parsed[:quiet] do
        case result.tunnel_token do
          token when is_binary(token) and token != "" ->
            Mix.shell().info("cloudflared tunnel run --token #{token}")

          _ ->
            :ok
        end
      end
    end
  end

  defp stringify_route(route) do
    route
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_dns(%{desired: desired} = dns) when is_map(desired) do
    dns
    |> Map.put(:desired, desired)
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_dns(dns) do
    dns
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error(:missing_routes), do: "Missing required --route flags"

  defp format_error(:missing_cloudflare_api_token),
    do: "Missing Cloudflare API token (:cloudflare_api_token)"

  defp format_error(:missing_account_id),
    do: "Missing Cloudflare account id (--account-id or :cloudflare_account_id)"

  defp format_error(:zone_not_found), do: "No matching Cloudflare zone found for hostname"

  defp format_error({:zone_not_found, hostname}),
    do: "No matching Cloudflare zone found for hostname: #{hostname}"

  defp format_error({:ambiguous_zone_match, hostname, ids}),
    do:
      "Multiple zones match hostname #{hostname}; pass zone_id=... (matches: #{Enum.join(ids, ", ")})"

  defp format_error({:ambiguous_tunnel_name, tunnel_name, ids}),
    do: "Multiple tunnels match name #{tunnel_name} (matches: #{Enum.join(ids, ", ")})"

  defp format_error({:invalid_route_head, value}),
    do: "Invalid --route value (expected <hostname>=<service>): #{value}"

  defp format_error({:invalid_route_option, value}), do: "Invalid --route option: #{value}"
  defp format_error({:invalid_ttl, value}), do: "Invalid ttl value: #{inspect(value)}"
  defp format_error({:invalid_service, value}), do: "Invalid service URL: #{inspect(value)}"
  defp format_error({:invalid_hostname, value}), do: "Invalid hostname: #{inspect(value)}"
  defp format_error(other), do: inspect(other)
end
