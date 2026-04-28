defmodule Flared.Config do
  @moduledoc """
  Centralized application configuration access for Flared.

  This module exists so other modules don't directly call `System.get_env/1`.
  If you want to source values from OS environment variables, do it in your
  config environment (typically `config/runtime.exs`).

  `:api_token` must be a **User API Token** created under
  **My Profile → API Tokens**
  (https://dash.cloudflare.com/profile/api-tokens). Account-owned API
  Tokens (created under *Manage Account → Account API Tokens*) and the
  legacy Global API Key are not supported. See `Flared.Tokens` for the
  reason and the exact error you will see if the wrong type is used.

  ## Example (`config/runtime.exs`)

  ```elixir
  config :flared,
    api_token: System.get_env("CLOUDFLARE_API_TOKEN"),
    account_id: System.get_env("CLOUDFLARE_ACCOUNT_ID"),
    dns: %{ttl: 1}
  ```
  """

  @app :flared
  @default_cloudflared_dir ".cloudflared"

  @spec api_token() :: String.t() | nil
  def api_token do
    @app |> Application.get_env(:api_token) |> lookup(nil)
  end

  @spec account_id() :: String.t() | nil
  def account_id do
    @app |> Application.get_env(:account_id) |> lookup(nil)
  end

  @spec dns() :: %{optional(atom()) => term()}
  def dns do
    Application.get_env(@app, :dns) || %{ttl: 1}
  end

  @doc """
  Resolves the directory used for local `cloudflared` files.

  Falls back to the default `#{@default_cloudflared_dir}` when no value
  is configured.
  """
  @spec cloudflared_dir() :: Path.t()
  def cloudflared_dir do
    @app |> Application.get_env(:cloudflared_dir) |> lookup(@default_cloudflared_dir)
  end

  @doc """
  Resolves the directory used for tunnel PID files.

  Returns `nil` when no value is configured so callers (e.g.
  `Flared.PidFile`) can fall back to their own default.
  """
  @spec tmp_dir() :: Path.t() | nil
  def tmp_dir do
    @app |> Application.get_env(:tmp_dir) |> lookup(nil)
  end

  @spec executable() :: String.t()
  def executable do
    @app |> Application.get_env(:executable) |> lookup("cloudflared")
  end

  defp lookup(items, default) do
    items
    |> List.wrap()
    |> Enum.reduce_while(default, fn
      {:system, key}, acc ->
        case System.get_env(key) do
          nil -> {:cont, acc}
          value -> {:halt, value}
        end

      value, _acc when is_binary(value) ->
        {:halt, value}

      _value, acc ->
        {:cont, acc}
    end)
    |> maybe_trim_string()
  end

  defp maybe_trim_string(value) when is_binary(value) do
    String.trim(value)
  end

  defp maybe_trim_string(value), do: value
end
