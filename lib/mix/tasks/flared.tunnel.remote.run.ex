defmodule Mix.Tasks.Flared.Tunnel.Remote.Run do
  @shortdoc "Run a remote-mode Cloudflare tunnel and block"

  @moduledoc """
  Runs a remote-mode Cloudflare tunnel by calling
  `Flared.MixTask.run_remote/2` and blocks the BEAM until `cloudflared`
  exits.

  Creates resources via `Flared.Provisioner.Remote.provision/3`,
  extracts the token, and runs `cloudflared tunnel run --token <token>`.
  When `cloudflared` exits (or the BEAM is interrupted with Ctrl-C),
  the matching destroy is invoked to clean up Cloudflare-side
  resources.

  ## Configuration

  Reads Cloudflare credentials/defaults from `Flared.Config` (application env).

  ## Usage

  ```bash
  mix flared.tunnel.remote.run \\
    --name test \\
    --route chat.example.com=http://localhost:4000 \\
    --route api.example.com=http://localhost:4001
  ```

  Press Ctrl-C twice to stop. The tunnel is deprovisioned automatically
  when the BEAM exits cleanly.

  ## Flags

  - `--name <name>`: Cloudflare tunnel name (required)
  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--route <hostname>=<service>[,ttl=<n>][,zone_id=<id>]`: repeatable, required
  - `--concurrency <n>`: DNS upsert concurrency (default: schedulers_online)
  - `--dry-run`: print planned changes; do not call mutation endpoints
  - `--timeout <ms>`: max ms to keep `cloudflared` running (default: forever)
  """

  use Mix.Task

  alias Flared.Provisioner.Common
  alias Flared.MixTask

  @switches [
    name: :string,
    account_id: :string,
    route: :keep,
    concurrency: :integer,
    dry_run: :boolean,
    timeout: :integer
  ]

  @aliases [
    a: :account_id,
    n: :name,
    r: :route,
    c: :concurrency,
    d: :dry_run
  ]

  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {parsed, _rest, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if invalid !== [] do
      report_invalid(invalid)
      System.halt(1)
    else
      do_run(parsed)
    end
  end

  defp do_run(parsed) do
    routes =
      parsed
      |> Keyword.get_values(:route)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 === ""))

    with {:ok, name} <- fetch_name(parsed),
         {:ok, parsed_routes} <- parse_routes(routes) do
      opts = build_open_opts(parsed)
      start_tunnel(name, parsed_routes, opts)
    else
      {:error, reason} ->
        Mix.shell().error(format_error(reason))
        System.halt(1)
    end
  end

  defp start_tunnel(name, parsed_routes, opts) do
    Mix.shell().info("Tunnel #{inspect(name)} starting…")
    Mix.shell().info("Press Ctrl-C twice to stop.")

    case MixTask.run_remote(name, parsed_routes, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().error(format_error(reason))
        System.halt(1)
    end
  end

  defp fetch_name(parsed) do
    case parsed[:name] do
      name when is_binary(name) and name !== "" -> {:ok, name}
      _ -> {:error, :missing_name}
    end
  end

  defp report_invalid(invalid) do
    invalid
    |> Enum.map(fn {flag, _val} -> flag end)
    |> Enum.uniq()
    |> Enum.each(fn flag ->
      Mix.shell().error("Unknown option: #{flag}")
    end)
  end

  defp parse_routes([]), do: {:error, :missing_routes}

  defp parse_routes(routes) do
    result =
      Enum.reduce_while(routes, {:ok, []}, fn route, {:ok, acc} ->
        case Common.parse_route(route) do
          {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = error -> error
    end
  end

  defp build_open_opts(parsed) do
    []
    |> maybe_put(:account_id, parsed[:account_id])
    |> maybe_put(:concurrency, parsed[:concurrency])
    |> maybe_put(:dry_run?, parsed[:dry_run])
    |> maybe_put(:timeout, parsed[:timeout])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error(:missing_name), do: "Missing required --name"

  defp format_error(:missing_routes), do: "Missing required --route flags"

  defp format_error(:missing_token),
    do: "Provisioning succeeded but no connector token was returned"

  defp format_error(:missing_api_token),
    do: "Missing Cloudflare API token (:api_token)"

  defp format_error(:missing_account_id),
    do: "Missing Cloudflare account id (--account-id or :account_id)"

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
  defp format_error({:invalid_route, value}), do: "Invalid --route value: #{inspect(value)}"

  defp format_error({:spawn_failed, reason}),
    do: "Failed to spawn cloudflared: #{inspect(reason)}"

  defp format_error(other), do: inspect(other)
end
