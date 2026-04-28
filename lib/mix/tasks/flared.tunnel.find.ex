defmodule Mix.Tasks.Flared.Tunnel.Find do
  @shortdoc "Find Cloudflare tunnels by name and/or id substring"

  @moduledoc """
  Searches tunnels in the configured Cloudflare account by case-insensitive
  substring match on name and/or id.

  At least one of `--name` or `--id` is required. When both are given,
  results must match both filters. For exact-name lookup use
  `mix flared.tunnel.status`.

  ## Usage

  ```bash
  mix flared.tunnel.find --name chat
  mix flared.tunnel.find --id 8f2e
  mix flared.tunnel.find --name api --id prod --json
  ```

  ## Flags

  - `--name <substring>`: case-insensitive substring of the tunnel name
  - `--id <substring>`: case-insensitive substring of the tunnel id
  - `--account-id <id>`: Cloudflare account id (overrides app config)
  - `--json`: emit a JSON array of `{"name", "tunnel_id", "created_at", "deleted_at"}` objects
  """

  use Mix.Task

  alias Flared.TunnelCLI

  @switches [
    name: :string,
    id: :string,
    account_id: :string,
    json: :boolean
  ]

  @aliases [n: :name, i: :id, a: :account_id, j: :json]

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

    case TunnelCLI.find(opts) do
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
    []
    |> maybe_put(:name_contains, parsed[:name])
    |> maybe_put(:id_contains, parsed[:id])
    |> maybe_put(:account_id, parsed[:account_id])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
    Mix.shell().info("No tunnels matched.")
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

  defp format_error(:missing_query),
    do: "Missing search criteria: pass --name and/or --id"

  defp format_error(:missing_api_token),
    do: "Missing Cloudflare API token (:api_token)"

  defp format_error(:missing_account_id),
    do: "Missing Cloudflare account id (--account-id or :account_id)"

  defp format_error(other), do: inspect(other)
end
