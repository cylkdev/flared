defmodule Mix.Tasks.Flared.Tunnel.List do
  @shortdoc "List Cloudflare tunnels in the configured account"

  @moduledoc """
  Lists tunnels in the configured Cloudflare account.

  Cloudflare's API is the source of truth — there is no local state to
  query. Output order matches Cloudflare's response.

  ## Usage

  ```bash
  mix flared.tunnel.list
  mix flared.tunnel.list --account-id <id>
  mix flared.tunnel.list --json
  ```

  ## Flags

  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--json`: emit a JSON array of `{"name", "tunnel_id", "created_at", "deleted_at"}` objects
  """

  use Mix.Task

  alias Flared.TunnelCLI

  @switches [
    account_id: :string,
    json: :boolean
  ]

  @aliases [a: :account_id, j: :json]

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
    json? = parsed[:json] || false
    opts = build_opts(parsed)

    case TunnelCLI.list(opts) do
      {:ok, entries} ->
        print_entries(entries, json?)
        :ok

      {:error, reason} ->
        reason
        |> format_error()
        |> Mix.shell().error()

        System.halt(1)
    end
  end

  defp build_opts(parsed) do
    case parsed[:account_id] do
      id when is_binary(id) and id !== "" -> [account_id: id]
      _ -> []
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

  defp print_entries(entries, true) do
    json =
      entries
      |> Enum.map(fn entry ->
        %{
          "name" => entry.name,
          "tunnel_id" => entry.tunnel_id,
          "created_at" => entry.created_at,
          "deleted_at" => entry.deleted_at
        }
      end)
      |> Jason.encode!()

    Mix.shell().info(json)
    :ok
  end

  defp print_entries([], false) do
    Mix.shell().info("No tunnels found.")
    :ok
  end

  defp print_entries(entries, false) do
    rows = Enum.map(entries, &format_row/1)
    name_width = column_width(rows, 0, "NAME")
    id_width = column_width(rows, 1, "ID")

    "NAME"
    |> format_line("ID", "CREATED", name_width, id_width)
    |> Mix.shell().info()

    Enum.each(rows, fn [name, id, created] ->
      name
      |> format_line(id, created, name_width, id_width)
      |> Mix.shell().info()
    end)

    :ok
  end

  defp format_row(entry) do
    [
      entry.name,
      entry.tunnel_id,
      entry.created_at || "-"
    ]
  end

  defp column_width(rows, index, header) do
    rows
    |> Enum.map(fn row ->
      row
      |> Enum.at(index)
      |> String.length()
    end)
    |> Enum.max(fn -> 0 end)
    |> max(String.length(header))
  end

  defp format_line(name, id, created, name_width, id_width) do
    Enum.join(
      [
        String.pad_trailing(name, name_width),
        String.pad_trailing(id, id_width),
        created
      ],
      "  "
    )
  end

  defp format_error(:missing_api_token),
    do: "Missing Cloudflare API token (:api_token)"

  defp format_error(:missing_account_id),
    do: "Missing Cloudflare account id (--account-id or :account_id)"

  defp format_error(other), do: inspect(other)
end
