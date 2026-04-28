defmodule Mix.Tasks.Flared.Tunnel.Status do
  @shortdoc "Print whether a Cloudflare tunnel exists by name"

  @moduledoc """
  Prints whether a tunnel by name exists in Cloudflare. Cloudflare's
  API is the source of truth — there is no local state to query.

  ## Usage

  ```bash
  mix flared.tunnel.status --name flare
  mix flared.tunnel.status --name flare --json
  ```

  ## Flags

  - `--name <name>`: Cloudflare tunnel name (required)
  - `--json`: emit a JSON object `{"name": "...", "exists": ..., "tunnel_id": "..."}`
  """

  use Mix.Task

  alias Flared.TunnelCLI

  @switches [
    name: :string,
    json: :boolean
  ]

  @aliases [j: :json]

  @spec run([String.t()]) :: :ok
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: :ok
  def run(argv, _runtime_opts) do
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
    json? = parsed[:json] || false

    case fetch_name(parsed) do
      {:ok, name} -> dispatch_status(name, json?)
      {:error, reason} -> abort(reason, nil)
    end
  end

  defp dispatch_status(name, json?) do
    case TunnelCLI.status(name) do
      {:ok, info} ->
        print_status(info, json?)
        :ok

      {:error, reason} ->
        abort(reason, name)
    end
  end

  defp abort(reason, name) do
    Mix.shell().error(format_error(reason, name))
    System.halt(1)
  end

  defp report_invalid(invalid) do
    invalid
    |> Enum.map(fn {flag, _val} -> flag end)
    |> Enum.uniq()
    |> Enum.each(fn flag ->
      Mix.shell().error("Unknown option: #{flag}")
    end)
  end

  defp fetch_name(parsed) do
    case parsed[:name] do
      name when is_binary(name) and name !== "" -> {:ok, name}
      _ -> {:error, :missing_name}
    end
  end

  defp print_status(%{name: name, exists: exists, tunnel_id: tunnel_id}, true) do
    json =
      Jason.encode!(%{
        "name" => name,
        "exists" => exists,
        "tunnel_id" => tunnel_id
      })

    Mix.shell().info(json)
    :ok
  end

  defp print_status(%{name: name, exists: true, tunnel_id: tunnel_id}, false) do
    Mix.shell().info("#{name}: present (id=#{tunnel_id})")
    :ok
  end

  defp print_status(%{name: name, exists: false}, false) do
    Mix.shell().info("#{name}: absent")
    :ok
  end

  defp format_error(:missing_name, _name), do: "Missing required --name"

  defp format_error(:missing_api_token, _name),
    do: "Missing Cloudflare API token (:api_token)"

  defp format_error(:missing_account_id, _name),
    do: "Missing Cloudflare account id (:account_id)"

  defp format_error({:ambiguous_tunnel_name, tunnel_name, ids}, _name),
    do: "Multiple tunnels match name #{tunnel_name} (matches: #{Enum.join(ids, ", ")})"

  defp format_error(other, _name), do: inspect(other)
end
