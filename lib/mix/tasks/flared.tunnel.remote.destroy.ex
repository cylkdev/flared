defmodule Mix.Tasks.Flared.Tunnel.Remote.Destroy do
  @shortdoc "Destroy a remote-mode Cloudflare tunnel via the Cloudflare API"

  @moduledoc """
  Destroys (deletes) Cloudflare tunnel + DNS resources for a
  remote-mode tunnel.

  This is the **remote** counterpart to `mix flared.tunnel.local.destroy`.

  This task is intentionally conservative:

  - DNS records are only deleted when they match the tunnel target
    (`<tunnel_uuid>.cfargotunnel.com`).
  - If the tunnel can't be found by name, DNS deletion is skipped (no tunnel id to verify).

  ## Safety

  Mutations require `--yes` unless `--dry-run` is used.

  ## Usage

  ```bash
  mix flared.tunnel.remote.destroy \
    --tunnel-name test \
    --route chat.example.com=http://localhost:4000 \
    --yes
  ```

  ## Flags

  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--tunnel-name <name>`: tunnel name (required)
  - `--route <hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`: repeatable, required
  - `--keep-dns`: do not delete DNS records
  - `--keep-tunnel`: do not delete the tunnel
  - `--concurrency <n>`: DNS delete concurrency (default: schedulers_online)
  - `--dry-run`: print planned changes; do not call mutation endpoints
  - `--json`: emit a single JSON object
  - `--yes`: required to actually delete
  """

  use Mix.Task

  alias Flared.Provisioner.{Common, Remote}

  @switches [
    account_id: :string,
    tunnel_name: :string,
    route: :keep,
    concurrency: :integer,
    dry_run: :boolean,
    json: :boolean,
    yes: :boolean,
    keep_dns: :boolean,
    keep_tunnel: :boolean
  ]

  @aliases [
    a: :account_id,
    n: :tunnel_name,
    r: :route,
    c: :concurrency,
    d: :dry_run,
    j: :json,
    y: :yes
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

    dry_run? = parsed[:dry_run] || false
    yes? = parsed[:yes] || false

    if not dry_run? and not yes? do
      Mix.shell().error("Refusing to delete without --yes (or use --dry-run).")
      System.halt(1)
    end

    routes =
      parsed
      |> Keyword.get_values(:route)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with {:ok, parsed_routes} <- parse_routes(routes),
         {:ok, result} <- do_deprovision(parsed, parsed_routes) do
      print_result(result, parsed)
      :ok
    else
      {:error, reason} ->
        Mix.shell().error(format_error(reason))
        System.halt(1)
    end
  end

  defp do_deprovision(parsed, routes) do
    case parsed[:tunnel_name] do
      name when is_binary(name) and name !== "" ->
        delete_dns? = not (parsed[:keep_dns] || false)
        delete_tunnel? = not (parsed[:keep_tunnel] || false)

        opts =
          []
          |> maybe_put(:account_id, parsed[:account_id])
          |> Keyword.put(:concurrency, parsed[:concurrency] || System.schedulers_online())
          |> Keyword.put(:dry_run?, parsed[:dry_run] || false)
          |> Keyword.put(:delete_dns?, delete_dns?)
          |> Keyword.put(:delete_tunnel?, delete_tunnel?)

        Remote.deprovision(name, routes, opts)

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
          "tunnel" => result.tunnel,
          "dry_run?" => result.dry_run?,
          "dns" => result.dns
        }
        |> Jason.encode!()

      Mix.shell().info(json)
    else
      tunnel_id_display =
        case result.tunnel_id do
          nil -> "(not found)"
          id -> "(#{id})"
        end

      Mix.shell().info("Tunnel: #{result.tunnel_name} #{tunnel_id_display}")

      Enum.each(result.dns, fn dns ->
        hostname = dns.hostname
        status = dns.status
        Mix.shell().info("DNS: #{hostname} => #{status}")
      end)

      Mix.shell().info("Tunnel delete: #{result.tunnel.status}")

      if result.dry_run? do
        Mix.shell().info("Dry run: no changes applied")
      end
    end
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

  defp format_error({:ambiguous_tunnel_name, tunnel_name, ids}),
    do: "Multiple tunnels match name #{tunnel_name} (matches: #{Enum.join(ids, ", ")})"

  defp format_error({:zone_not_found, hostname}),
    do: "No matching Cloudflare zone found for hostname: #{hostname}"

  defp format_error({:ambiguous_zone_match, hostname, ids}),
    do:
      "Multiple zones match hostname #{hostname}; pass zone_id=... (matches: #{Enum.join(ids, ", ")})"

  defp format_error(other), do: inspect(other)
end
