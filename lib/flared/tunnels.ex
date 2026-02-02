defmodule Flared.Tunnels do
  @moduledoc """
  Cloudflare Tunnel API operations.

  This module is used by `Flared.Provisioner` and is not typically
  called directly by end users.
  """

  alias Flared.Client

  @doc """
  Ensures a tunnel exists by exact name.

  If no tunnel exists, creates an API-managed tunnel (`config_src: "cloudflare"`).
  """
  @spec ensure_tunnel(Client.t(), String.t(), String.t()) ::
          {:ok, %{id: String.t(), name: String.t(), token: String.t() | nil}}
          | {:error, term()}
  def ensure_tunnel(%Client{} = client, account_id, tunnel_name)
      when is_binary(account_id) and is_binary(tunnel_name) do
    case find_tunnel(client, account_id, tunnel_name) do
      {:ok, nil} -> create_tunnel(client, account_id, tunnel_name)
      {:ok, tunnel} -> {:ok, %{id: tunnel["id"], name: tunnel["name"], token: nil}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Finds a tunnel by exact name.

  Returns `{:ok, nil}` when no tunnel matches.
  """
  @spec find_tunnel(Client.t(), String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_tunnel(%Client{} = client, account_id, tunnel_name)
      when is_binary(account_id) and is_binary(tunnel_name) do
    with {:ok, tunnels} <- list_tunnels(client, account_id) do
      case Enum.filter(tunnels, &match?(%{"name" => ^tunnel_name}, &1)) do
        [] -> {:ok, nil}
        [tunnel] -> {:ok, tunnel}
        tunnels -> {:error, {:ambiguous_tunnel_name, tunnel_name, Enum.map(tunnels, & &1["id"])}}
      end
    end
  end

  @doc """
  Fetches a `cloudflared` run token for the given tunnel id.
  """
  @spec get_token(Client.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_token(%Client{} = client, account_id, tunnel_id)
      when is_binary(account_id) and is_binary(tunnel_id) do
    case Client.get(client, "/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/token") do
      {:ok, %{"token" => token}} when is_binary(token) -> {:ok, token}
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, other} -> {:error, {:unexpected_token_shape, other}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Deletes a tunnel by id.

  Note: this does not delete DNS records; DNS cleanup is handled separately.
  """
  @spec delete_tunnel(Client.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def delete_tunnel(%Client{} = client, account_id, tunnel_id)
      when is_binary(account_id) and is_binary(tunnel_id) do
    Client.delete(client, "/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}")
  end

  @doc """
  Replaces the tunnel's ingress rules (API-managed configuration).

  Always appends the mandatory catch-all `http_status:404` rule.
  """
  @spec put_config(Client.t(), String.t(), String.t(), list(map())) ::
          {:ok, term()} | {:error, term()}
  def put_config(%Client{} = client, account_id, tunnel_id, routes)
      when is_binary(account_id) and is_binary(tunnel_id) and is_list(routes) do
    ingress = build_ingress(routes)
    body = %{"config" => %{"ingress" => ingress}}
    Client.put(client, "/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/configurations", body)
  end

  @doc """
  Builds the ingress rules from routes and appends the mandatory catch-all rule.
  """
  @spec build_ingress(list(map())) :: list(map())
  def build_ingress(routes) when is_list(routes) do
    routes
    |> Enum.map(fn %{:hostname => hostname, :service => service} ->
      %{"hostname" => hostname, "service" => service}
    end)
    |> Kernel.++([%{"service" => "http_status:404"}])
  end

  defp list_tunnels(%Client{} = client, account_id) when is_binary(account_id) do
    case Client.get(client, "/accounts/#{account_id}/cfd_tunnel") do
      {:ok, tunnels} when is_list(tunnels) -> {:ok, tunnels}
      {:ok, %{"tunnels" => tunnels}} when is_list(tunnels) -> {:ok, tunnels}
      {:ok, other} -> {:error, {:unexpected_tunnel_list_shape, other}}
      {:error, _} = error -> error
    end
  end

  defp create_tunnel(%Client{} = client, account_id, tunnel_name)
       when is_binary(account_id) and is_binary(tunnel_name) do
    body = %{"name" => tunnel_name, "config_src" => "cloudflare"}

    case Client.post(client, "/accounts/#{account_id}/cfd_tunnel", body) do
      {:ok, %{"id" => id, "name" => name} = tunnel} ->
        {:ok, %{id: id, name: name, token: Map.get(tunnel, "token")}}

      {:ok, other} ->
        {:error, {:unexpected_create_tunnel_shape, other}}

      {:error, _} = error ->
        error
    end
  end
end
