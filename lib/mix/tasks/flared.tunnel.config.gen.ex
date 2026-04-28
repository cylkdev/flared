defmodule Mix.Tasks.Flared.Tunnel.Config.Gen do
  @shortdoc "Generate a cloudflared config for token-based runs"

  @moduledoc """
  Generates a `cloudflared` config file for token-based tunnel runs.

  This task writes `config.yml` using the provided routes and prints the
  recommended run command that uses a token.
  """

  use Mix.Task

  alias Flared.Provisioner.Common
  alias Flared.ConfigYML

  @switches [
    tunnel_id: :string,
    route: :keep,
    dest: :string,
    filename: :string,
    overwrite: :boolean
  ]

  @aliases [
    t: :tunnel_id,
    r: :route,
    d: :dest,
    f: :filename,
    o: :overwrite
  ]

  @doc """
  Generates a config file from CLI arguments.

  Returns `{:ok, output_path}` on success or halts on error.

  ### Examples

  ```bash
  mix flared.tunnel.config.gen \\
    --tunnel-id tunnel-id \\
    --route chat.example.com=http://localhost:4000 \\
    --dest .cloudflared
  ```
  """
  @spec run([String.t()]) :: {:ok, Path.t()}
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

    with {:ok, tunnel_id} <- validate_tunnel_id(parsed[:tunnel_id]),
         {:ok, parsed_routes} <- parse_routes(routes),
         {:ok, output_path} <- write_config(parsed_routes, tunnel_id, parsed) do
      print_run_command(output_path)
      {:ok, output_path}
    else
      {:error, reason} ->
        Mix.shell().error(format_error(reason))
        System.halt(1)
    end
  end

  defp validate_tunnel_id(tunnel_id) when is_binary(tunnel_id) and tunnel_id != "" do
    {:ok, tunnel_id}
  end

  defp validate_tunnel_id(_tunnel_id), do: {:error, :missing_tunnel_id}

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

  defp write_config(routes, tunnel_id, parsed) do
    dest_dir = parsed[:dest] || ".cloudflared"
    overwrite? = Keyword.get(parsed, :overwrite, true)

    opts =
      []
      |> maybe_put(:filename, parsed[:filename])
      |> maybe_put(:overwrite?, overwrite?)

    ConfigYML.generate(dest_dir, routes, tunnel_id, opts)
  end

  defp print_run_command(output_path) do
    Mix.shell().info("cloudflared tunnel --config #{output_path} run --token $CLOUDFLARED_TOKEN")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error(:missing_tunnel_id), do: "Missing required --tunnel-id"
  defp format_error(:missing_routes), do: "Missing required --route flags"
  defp format_error({:invalid_route, value}), do: "Invalid --route value: #{inspect(value)}"

  defp format_error({:invalid_route_head, value}),
    do: "Invalid --route value (expected <hostname>=<service>): #{value}"

  defp format_error({:invalid_route_option, value}), do: "Invalid --route option: #{value}"
  defp format_error({:invalid_ttl, value}), do: "Invalid ttl value: #{inspect(value)}"
  defp format_error({:invalid_service, value}), do: "Invalid service URL: #{inspect(value)}"
  defp format_error({:invalid_hostname, value}), do: "Invalid hostname: #{inspect(value)}"
  defp format_error(other), do: inspect(other)
end
