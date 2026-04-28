defmodule Flared.DNS do
  @moduledoc """
  Cloudflare DNS operations used for tunnel provisioning.

  This module is used by `Flared.Provisioner.Remote` and
  `Flared.Provisioner.Local` to upsert DNS records for the public
  hostnames routed into a tunnel.

  DNS records are always created/updated with `proxied: true`.

  Every public function accepts a final `opts` keyword list, forwarded to
  `Flared.Client` (notably `:token`). Function-specific options (e.g.
  `:ttl`) are documented on each function.
  """

  alias Flared.Client

  @doc """
  Ensures a CNAME record exists for `hostname` pointing to the tunnel target.

  Returns `:noop` if an existing record already matches the desired content.

  ## Options

  - `:ttl` (default `1` / "auto")
  - plus any option accepted by `Flared.Client` (notably `:token`)
  """
  @spec upsert_cname(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{status: :created | :updated | :noop, record_id: String.t() | nil}}
          | {:error, term()}
  def upsert_cname(zone_id, hostname, tunnel_id, opts \\ [])
      when is_binary(zone_id) and is_binary(hostname) and is_binary(tunnel_id) and is_list(opts) do
    desired = desired_record(hostname, tunnel_id, opts)
    client_opts = Keyword.drop(opts, [:ttl])

    with {:ok, existing} <- get_cname_record(zone_id, hostname, client_opts) do
      case existing do
        nil ->
          create_record(zone_id, desired, client_opts)

        record ->
          if record_matches?(record, desired) do
            {:ok, %{status: :noop, record_id: record["id"]}}
          else
            update_record(zone_id, record, desired, client_opts)
          end
      end
    end
  end

  @doc """
  Finds the existing CNAME record for `hostname` in the zone, if any.

  Returns `{:ok, nil}` when missing.
  """
  @spec find_cname(String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def find_cname(zone_id, hostname, opts \\ [])
      when is_binary(zone_id) and is_binary(hostname) and is_list(opts) do
    get_cname_record(zone_id, hostname, opts)
  end

  @doc """
  Deletes a DNS record by id.
  """
  @spec delete_record(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def delete_record(zone_id, record_id, opts \\ [])
      when is_binary(zone_id) and is_binary(record_id) and is_list(opts) do
    Client.delete("/zones/#{zone_id}/dns_records/#{record_id}", opts)
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

  defp get_cname_record(zone_id, hostname, opts) do
    params = %{"type" => "CNAME", "name" => hostname}

    case Client.get("/zones/#{zone_id}/dns_records", Keyword.put(opts, :params, params)) do
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

  defp create_record(zone_id, desired, opts) do
    case Client.post("/zones/#{zone_id}/dns_records", desired, opts) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, %{status: :created, record_id: id}}
      {:ok, _} -> {:ok, %{status: :created, record_id: nil}}
      {:error, _} = error -> error
    end
  end

  defp update_record(zone_id, record, desired, opts) do
    record_id = record["id"]

    if is_binary(record_id) do
      case Client.patch("/zones/#{zone_id}/dns_records/#{record_id}", desired, opts) do
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
