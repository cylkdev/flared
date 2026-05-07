defmodule Flared.Tunnels do
  @moduledoc """
  Cloudflare Tunnel API operations.

  This module is used by `Flared.Provisioner.Remote` and
  `Flared.Provisioner.Local` and is not typically called directly by
  end users.

  Every public function accepts a final `opts` keyword list, forwarded to
  `Flared.Client` (notably `:token`).
  """

  alias Flared.Client

  @doc """
  Ensures a tunnel exists by exact name.

  If no tunnel exists, creates an API-managed tunnel (`config_src: "cloudflare"`).
  """
  @spec find_or_create_tunnel(String.t(), String.t(), keyword()) ::
          {:ok, %{id: String.t(), name: String.t(), token: String.t() | nil}}
          | {:error, term()}
  def find_or_create_tunnel(account_id, tunnel_name, opts \\ [])
      when is_binary(account_id) and is_binary(tunnel_name) and is_list(opts) do
    case find_tunnel(account_id, tunnel_name, opts) do
      {:ok, nil} -> create_tunnel(account_id, tunnel_name, opts)
      {:ok, tunnel} -> {:ok, %{id: tunnel["id"], name: tunnel["name"], token: nil}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns the list of Cloudflare tunnels in the given account.

  ## Parameters

    - `account_id` - `String.t()`. The Cloudflare account whose tunnels are being
      listed. Must be a non-empty string.
    - `opts` - `keyword()`. Forwarded to `Flared.Client` (notably `:token` to
      override the API token).

  ## Returns

  `{:ok, [map()]}` on success, where each element is a raw tunnel map from the
  Cloudflare API with string keys (e.g. `"id"`, `"name"`, `"created_at"`). The
  list may be empty when the account has no tunnels. Element order matches the
  Cloudflare API response and is not normalized by this function.

  `{:error, {:unexpected_tunnel_list_shape, value}}` is returned when the
  response body is neither a JSON list nor a map containing a `"tunnels"` list.

  `{:error, term()}` is propagated unchanged from `Flared.Client.get/2` for
  HTTP, transport, or auth errors.

  Performs a single HTTP `GET /accounts/<account_id>/cfd_tunnel`. Read-only and
  idempotent.

  ## Examples

      # Successful listing
      iex> Flared.Tunnels.list_tunnels("acc_123", token: "...")
      {:ok, [%{"id" => "...", "name" => "site-a"}, ...]}

      # Empty account
      iex> Flared.Tunnels.list_tunnels("acc_456", token: "...")
      {:ok, []}

  """
  @spec list_tunnels(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_tunnels(account_id, opts) when is_binary(account_id) do
    case Client.get("/accounts/#{account_id}/cfd_tunnel", opts) do
      {:ok, tunnels} when is_list(tunnels) -> {:ok, tunnels}
      {:ok, %{"tunnels" => tunnels}} when is_list(tunnels) -> {:ok, tunnels}
      {:ok, other} -> {:error, {:unexpected_tunnel_list_shape, other}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Creates a new API-managed Cloudflare tunnel and returns its identifying fields.

  ## Parameters

    - `account_id` - `String.t()`. The Cloudflare account in which the tunnel is
      created. Must be a non-empty string.
    - `tunnel_name` - `String.t()`. The exact name to assign to the new tunnel.
      Cloudflare allows duplicate names — this function does not deduplicate, so
      callers that need uniqueness should use `find_or_create_tunnel/3` instead.
    - `opts` - `keyword()`. Forwarded to `Flared.Client` (notably `:token` to
      override the API token).

  ## Returns

  `{:ok, %{id: String.t(), name: String.t(), token: String.t() | nil}}` on
  success. The `:id` is the new tunnel's UUID. The `:name` echoes the value
  Cloudflare stored. The `:token` is the connector run-token if Cloudflare
  returned one inline on create, otherwise `nil` — callers that always need the
  token should use `get_token/3`.

  `{:error, {:unexpected_create_tunnel_shape, value}}` is returned when the
  response is missing either the `"id"` or `"name"` key.

  `{:error, term()}` is propagated unchanged from `Flared.Client.post/3` for
  HTTP, transport, validation, or auth errors.

  Performs a single HTTP `POST /accounts/<account_id>/cfd_tunnel` with body
  `%{"name" => tunnel_name, "config_src" => "cloudflare"}`. **Not idempotent:**
  each successful call creates a new tunnel, even if a tunnel by the same name
  already exists. Use `find_or_create_tunnel/3` for find-or-create semantics.

  ## Examples

      # Creates a brand-new tunnel
      iex> Flared.Tunnels.create_tunnel("acc_123", "site-a", token: "...")
      {:ok, %{id: "8f2...", name: "site-a", token: "eyJh..."}}

  """
  @spec create_tunnel(String.t(), String.t(), keyword()) ::
          {:ok, %{id: String.t(), name: String.t(), token: String.t() | nil}}
          | {:error, term()}
  def create_tunnel(account_id, tunnel_name, opts)
      when is_binary(account_id) and is_binary(tunnel_name) do
    body = %{"name" => tunnel_name, "config_src" => "cloudflare"}

    case Client.post("/accounts/#{account_id}/cfd_tunnel", body, opts) do
      {:ok, %{"id" => id, "name" => name} = tunnel} ->
        {:ok, %{id: id, name: name, token: Map.get(tunnel, "token")}}

      {:ok, other} ->
        {:error, {:unexpected_create_tunnel_shape, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Finds a tunnel by exact name.

  Returns `{:ok, nil}` when no tunnel matches.
  """
  @spec find_tunnel(String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def find_tunnel(account_id, tunnel_name, opts \\ [])
      when is_binary(account_id) and is_binary(tunnel_name) and is_list(opts) do
    with {:ok, tunnels} <- list_tunnels(account_id, opts) do
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
  @spec get_token(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_token(account_id, tunnel_id, opts \\ [])
      when is_binary(account_id) and is_binary(tunnel_id) and is_list(opts) do
    case Client.get("/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/token", opts) do
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
  @spec delete_tunnel(String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def delete_tunnel(account_id, tunnel_id, opts \\ [])
      when is_binary(account_id) and is_binary(tunnel_id) and is_list(opts) do
    Client.delete("/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}", opts)
  end

  @doc """
  Replaces the tunnel's ingress rules (API-managed configuration).

  Always appends the mandatory catch-all `http_status:404` rule.
  """
  @spec put_config(String.t(), String.t(), list(map()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def put_config(account_id, tunnel_id, routes, opts \\ [])
      when is_binary(account_id) and is_binary(tunnel_id) and is_list(routes) and is_list(opts) do
    ingress = build_ingress(routes)
    body = %{"config" => %{"ingress" => ingress}}
    Client.put("/accounts/#{account_id}/cfd_tunnel/#{tunnel_id}/configurations", body, opts)
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
end
