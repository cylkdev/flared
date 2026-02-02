defmodule Flared.Config do
  @moduledoc """
  Centralized application configuration access for Flared.

  This module exists so other modules don't directly call `System.get_env/1`.
  If you want to source values from OS environment variables, do it in your
  config environment (typically `config/runtime.exs`).

  ## Example (`config/runtime.exs`)

  ```elixir
  config :flared,
    cloudflare_api_token: System.get_env("CLOUDFLARE_API_TOKEN"),
    cloudflare_account_id: System.get_env("CLOUDFLARE_ACCOUNT_ID"),
    cloudflare_tunnel_name: System.get_env("TUNNEL_NAME") || "flare",
    cloudflare_dns_defaults: %{ttl: 1}
  ```
  """

  @app :flared

  @spec cloudflare_api_token() :: String.t() | nil
  def cloudflare_api_token do
    Application.get_env(@app, :cloudflare_api_token)
  end

  @spec cloudflare_account_id() :: String.t() | nil
  def cloudflare_account_id do
    Application.get_env(@app, :cloudflare_account_id)
  end

  @spec cloudflare_tunnel_name() :: String.t() | nil
  def cloudflare_tunnel_name do
    Application.get_env(@app, :cloudflare_tunnel_name)
  end

  @spec cloudflare_dns_defaults() :: %{optional(atom()) => term()}
  def cloudflare_dns_defaults do
    Application.get_env(@app, :cloudflare_dns_defaults) || %{ttl: 1}
  end
end
