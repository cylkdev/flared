defmodule Mix.Tasks.Flared.Tunnel.Local.Destroy do
  @shortdoc "Destroy a local-mode Cloudflare tunnel and clean up its config files"

  @moduledoc """
  Destroys (deletes) Cloudflare tunnel + DNS resources for a
  local-mode tunnel and removes the local `config.yml` and `<UUID>.json`
  credentials files written by `mix flared.tunnel.local.create`.

  This is the **local** counterpart to `mix flared.tunnel.remote.destroy`.

  ## Safety

  Mutations require `--yes` unless `--dry-run` is used.

  ## Usage

  ```bash
  mix flared.tunnel.local.destroy \\
    --tunnel-name test \\
    --cloudflared-dir .cloudflared/test \\
    --route chat.example.com=http://localhost:4000 \\
    --yes
  ```

  ## Flags

  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--tunnel-name <name>`: tunnel name (required)
  - `--cloudflared-dir <path>`: directory containing the local files (required)
  - `--route <hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`: repeatable, required
  - `--keep-dns`: do not delete DNS records
  - `--keep-tunnel`: do not delete the tunnel
  - `--keep-files`: do not delete the local files
  - `--concurrency <n>`: DNS delete concurrency (default: schedulers_online)
  - `--dry-run`: print planned changes; do not call mutation endpoints; do not delete files
  - `--json`: emit a single JSON object
  - `--yes`: required to actually delete
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
    json: :boolean,
    yes: :boolean,
    keep_dns: :boolean,
    keep_tunnel: :boolean,
    keep_files: :boolean
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
        delete_files? = not (parsed[:keep_files] || false)

        opts =
          []
          |> maybe_put(:account_id, parsed[:account_id])
          |> maybe_put(:cloudflared_dir, parsed[:cloudflared_dir])
          |> Keyword.put(:concurrency, parsed[:concurrency] || System.schedulers_online())
          |> Keyword.put(:dry_run?, parsed[:dry_run] || false)
          |> Keyword.put(:delete_dns?, delete_dns?)
          |> Keyword.put(:delete_tunnel?, delete_tunnel?)
          |> Keyword.put(:delete_files?, delete_files?)

        Local.deprovision(name, routes, opts)

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
          "dns" => result.dns,
          "files" => result.files
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
        Mix.shell().info("DNS: #{dns.hostname} => #{dns.status}")
      end)

      Mix.shell().info("Tunnel delete: #{result.tunnel.status}")

      Enum.each(result.files, fn file ->
        Mix.shell().info("File: #{file.path} => #{file.status}")
      end)

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
