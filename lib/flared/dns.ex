defmodule Flared.DNS do
  @moduledoc """
  Cloudflare DNS operations used for tunnel provisioning.

  This module is used by `Flared.Provisioner` to upsert DNS records for
  the public hostnames routed into a tunnel.

  DNS records are always created/updated with `proxied: true`.
  """

  alias Flared.Client

  @doc """
  Ensures a CNAME record exists for `hostname` pointing to the tunnel target.

  Returns `:noop` if an existing record already matches the desired content.
  """
  @spec ensure_cname(Client.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{status: :created | :updated | :noop, record_id: String.t() | nil}}
          | {:error, term()}
  def ensure_cname(%Client{} = client, zone_id, hostname, tunnel_id, opts \\ [])
      when is_binary(zone_id) and is_binary(hostname) and is_binary(tunnel_id) and is_list(opts) do
    desired = desired_record(hostname, tunnel_id, opts)

    with {:ok, existing} <- get_cname_record(client, zone_id, hostname) do
      case existing do
        nil ->
          create_record(client, zone_id, desired)

        record ->
          if record_matches?(record, desired) do
            {:ok, %{status: :noop, record_id: record["id"]}}
          else
            update_record(client, zone_id, record, desired)
          end
      end
    end
  end

  @doc """
  Finds the existing CNAME record for `hostname` in the zone, if any.

  Returns `{:ok, nil}` when missing.
  """
  @spec find_cname(Client.t(), String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_cname(%Client{} = client, zone_id, hostname)
      when is_binary(zone_id) and is_binary(hostname) do
    get_cname_record(client, zone_id, hostname)
  end

  @doc """
  Deletes a DNS record by id.
  """
  @spec delete_record(Client.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def delete_record(%Client{} = client, zone_id, record_id)
      when is_binary(zone_id) and is_binary(record_id) do
    Client.delete(client, "/zones/#{zone_id}/dns_records/#{record_id}")
  end

  @doc """
  Builds the desired CNAME record body for a tunnel hostname.

  Options:

  - `:ttl` (default `1` / "auto")
  """
  @spec desired_record(String.t(), String.t(), keyword()) :: map()
  def desired_record(hostname, tunnel_id, opts \\ [])
      when is_binary(hostname) and is_binary(tunnel_id) do
    ttl = Keyword.get(opts, :ttl, 1)

    %{
      "type" => "CNAME",
      "name" => hostname,
      "content" => "#{tunnel_id}.cfargotunnel.com",
      "proxied" => true,
      "ttl" => ttl
    }
  end

  defp get_cname_record(%Client{} = client, zone_id, hostname) do
    params = %{"type" => "CNAME", "name" => hostname}

    case Client.get(client, "/zones/#{zone_id}/dns_records", params) do
      {:ok, records} when is_list(records) ->
        pick_single_record(records)

      {:ok, %{"dns_records" => records}} when is_list(records) ->
        pick_single_record(records)

      {:ok, other} ->
        {:error, {:unexpected_dns_list_shape, other}}

      {:error, _} = error ->
        error
    end
  end

  defp pick_single_record([]), do: {:ok, nil}
  defp pick_single_record([record]), do: {:ok, record}

  defp pick_single_record(records),
    do: {:error, {:ambiguous_dns_records, Enum.map(records, & &1["id"])}}

  defp create_record(%Client{} = client, zone_id, desired) do
    case Client.post(client, "/zones/#{zone_id}/dns_records", desired) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, %{status: :created, record_id: id}}
      {:ok, _} -> {:ok, %{status: :created, record_id: nil}}
      {:error, _} = error -> error
    end
  end

  defp update_record(%Client{} = client, zone_id, record, desired) do
    record_id = record["id"]

    if is_binary(record_id) do
      case Client.patch(client, "/zones/#{zone_id}/dns_records/#{record_id}", desired) do
        {:ok, _} -> {:ok, %{status: :updated, record_id: record_id}}
        {:error, _} = error -> error
      end
    else
      {:error, {:missing_record_id, record}}
    end
  end

  defp record_matches?(record, desired) do
    Map.get(record, "type") == desired["type"] and
      Map.get(record, "name") == desired["name"] and
      Map.get(record, "content") == desired["content"] and
      Map.get(record, "proxied") == desired["proxied"] and
      Map.get(record, "ttl") == desired["ttl"]
  end
end
