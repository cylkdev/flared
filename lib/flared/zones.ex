defmodule Flared.Zones do
  @moduledoc """
  Cloudflare Zones helpers.

  Used by `Flared.Provisioner` to map a hostname (e.g. `chat.example.com`)
  to the correct zone id in the configured account.

  Zone resolution uses a "longest suffix match" strategy:

  - `a.sub.example.com` matches `sub.example.com` over `example.com`
  """

  alias Flared.Client

  @per_page 50

  @doc """
  Lists active zones for the account (paginates).
  """
  @spec list_zones(Client.t(), String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_zones(%Client{} = client, account_id) when is_binary(account_id) do
    list_zones_page(client, account_id, 1, [])
  end

  @doc """
  Resolves a zone id for a hostname from a previously listed zone set.

  Returns:

  - `{:ok, zone_id}` on a single best match
  - `{:error, :zone_not_found}` when nothing matches
  - `{:error, {:ambiguous_zone_match, length, ids}}` when multiple zones tie
  """
  @spec resolve_zone_id(String.t(), list(map())) :: {:ok, String.t()} | {:error, term()}
  def resolve_zone_id(hostname, zones) when is_binary(hostname) and is_list(zones) do
    candidates =
      zones
      |> Enum.filter(fn zone ->
        zone_name = zone["name"]
        is_binary(zone_name) and hostname_matches_zone?(hostname, zone_name)
      end)

    case pick_best_zone(candidates) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, zone} -> {:error, {:unexpected_zone_shape, zone}}
      {:error, _} = error -> error
    end
  end

  defp list_zones_page(%Client{} = client, account_id, page, acc) do
    params = %{
      "account.id" => account_id,
      "status" => "active",
      "per_page" => @per_page,
      "page" => page
    }

    case Client.request_envelope(client, :get, "/zones", params: params) do
      {:ok, %{result: zones, result_info: info}} when is_list(zones) ->
        total_pages =
          case info do
            %{"total_pages" => total_pages} -> total_pages
            %{:total_pages => total_pages} -> total_pages
            _ -> 1
          end

        if is_integer(total_pages) and page < total_pages do
          list_zones_page(client, account_id, page + 1, Enum.reverse(zones, acc))
        else
          {:ok, Enum.reverse(acc, zones)}
        end

      {:ok, other} ->
        {:error, {:unexpected_zones_list_shape, other}}

      {:error, _} = error ->
        error
    end
  end

  defp hostname_matches_zone?(hostname, zone_name) do
    hostname == zone_name or String.ends_with?(hostname, "." <> zone_name)
  end

  defp pick_best_zone([]), do: {:error, :zone_not_found}

  defp pick_best_zone(candidates) do
    candidates
    |> Enum.group_by(&String.length(&1["name"] || ""))
    |> Enum.sort_by(fn {len, _} -> len end, :desc)
    |> case do
      [] ->
        {:error, :zone_not_found}

      [{_len, [zone]} | _] ->
        {:ok, zone}

      [{len, zones} | _] ->
        {:error, {:ambiguous_zone_match, len, Enum.map(zones, & &1["id"])}}
    end
  end
end
