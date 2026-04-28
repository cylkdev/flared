defmodule Mix.Tasks.Flared.Tunnel.Local.Create do
  @shortdoc "Create a local-mode Cloudflare tunnel and write its config files"

  @moduledoc """
  Creates a Cloudflare tunnel + DNS records and writes the local
  `cloudflared` files (`config.yml` and `<UUID>.json` credentials)
  needed to run `cloudflared --config <path> tunnel run`.

  This is the **local** counterpart to `mix flared.tunnel.remote.create`:
  ingress lives on disk in `config.yml` instead of being pushed to the
  Cloudflare API.

  ## Configuration

  Reads Cloudflare credentials/defaults from `Flared.Config` (application env).

  ## Usage

  ```bash
  mix flared.tunnel.local.create \\
    --tunnel-name test \\
    --cloudflared-dir .cloudflared/test \\
    --route chat.example.com=http://localhost:4000
  ```

  ## Flags

  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--tunnel-name <name>`: tunnel name (required)
  - `--cloudflared-dir <path>`: directory for `config.yml` and credentials (required)
  - `--route <hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`: repeatable, required
  - `--concurrency <n>`: DNS upsert concurrency (default: schedulers_online)
  - `--dry-run`: print planned changes; do not call mutation endpoints; do not write files
  - `--json`: emit a single JSON object describing the result
  """

  use Mix.Task

  alias Flared.Provisioner.{Common, Local}

  @switches [
    account_id: :string,
    tunnel_name: :string,
    cloudflared_dir: :string,
    route: :keep,
    concurrency: :integer,
    dry_run: :boolean,
    json: :boolean
  ]

  @aliases [
    a: :account_id,
    n: :tunnel_name,
    r: :route,
    c: :concurrency,
    d: :dry_run,
    j: :json
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
    case parsed[:tunnel_name] do
      name when is_binary(name) and name !== "" ->
        opts =
          []
          |> maybe_put(:account_id, parsed[:account_id])
          |> maybe_put(:cloudflared_dir, parsed[:cloudflared_dir])
          |> Keyword.put(:concurrency, parsed[:concurrency] || System.schedulers_online())
          |> Keyword.put(:dry_run?, parsed[:dry_run] || false)

        Local.provision(name, routes, opts)

      _ ->
        {:error, :missing_tunnel_name}
    end
  end

  defp parse_routes([]), do: {:error, :missing_routes}

  defp parse_routes(routes) do
    routes
    |> Enum.reduce_while({:ok, []}, fn route, {:ok, acc} ->
      case Common.parse_route(route) do
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
          "config_path" => result.config_path,
          "credentials_path" => result.credentials_path,
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
        Mix.shell().info("DNS: #{dns.hostname} => #{dns.status}")
      end)

      Mix.shell().info("Config:      #{result.config_path}")
      Mix.shell().info("Credentials: #{result.credentials_path}")

      if result.dry_run? do
        Mix.shell().info("Dry run: no changes applied")
      end
    end
  end

  defp stringify_route(route) do
    Enum.into(route, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_dns(%{desired: desired} = dns) when is_map(desired) do
    dns
    |> Map.put(:desired, desired)
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_dns(dns) do
    Enum.into(dns, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error(:missing_routes), do: "Missing required --route flags"

  defp format_error(:missing_tunnel_name), do: "Missing required --tunnel-name"

  defp format_error(:missing_api_token),
    do: "Missing Cloudflare API token (:api_token)"

  defp format_error(:missing_account_id),
    do: "Missing Cloudflare account id (--account-id or :account_id)"

  defp format_error(:missing_token),
    do: "Cloudflare did not return a tunnel token; cannot write credentials"

  defp format_error(:missing_tunnel_id), do: "Tunnel has no id; cannot write credentials"

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
