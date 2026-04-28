defmodule Flared.Client do
  @moduledoc """
  Cloudflare API client wrapper around `Req`.

  This module is an internal building block for `Flared.Provisioner.Remote`
  and `Flared.Provisioner.Local`. Most callers should use those modules
  or `mix flared.tunnel.remote.create` / `mix flared.tunnel.local.create`
  instead of calling this module directly.

  ## Options

  Every public function accepts an `opts` keyword list:

  - `:token` - Cloudflare User API Token. Falls back to
    `Flared.Config.api_token/0` when not provided.
  - `:adapter` - `Req` adapter override (test-only).
  - `:params` - query string parameters (GET).
  - any other key supported by `Req.request/2` is forwarded.

  The token must be a Cloudflare **User API Token** created under
  **My Profile → API Tokens** — not an Account-owned API Token and not the
  legacy Global API Key. See `Flared.Tokens` for details.

  ## Response handling

  Cloudflare API responses are normalized from the standard envelope:

  - `{:ok, result}` when `"success": true`
  - `{:error, {:cloudflare, status, errors, body}}` when `"success": false`
  """

  alias Flared.Config

  @base_url "https://api.cloudflare.com/client/v4"

  @doc "Issues a GET request and returns the Cloudflare `result` on success."
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(path, opts \\ []) when is_binary(path) and is_list(opts) do
    request(:get, path, opts)
  end

  @doc "Issues a POST request and returns the Cloudflare `result` on success."
  @spec post(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def post(path, body, opts \\ []) when is_binary(path) and is_map(body) and is_list(opts) do
    request(:post, path, Keyword.put(opts, :json, body))
  end

  @doc "Issues a PUT request and returns the Cloudflare `result` on success."
  @spec put(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def put(path, body, opts \\ []) when is_binary(path) and is_map(body) and is_list(opts) do
    request(:put, path, Keyword.put(opts, :json, body))
  end

  @doc "Issues a PATCH request and returns the Cloudflare `result` on success."
  @spec patch(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def patch(path, body, opts \\ []) when is_binary(path) and is_map(body) and is_list(opts) do
    request(:patch, path, Keyword.put(opts, :json, body))
  end

  @doc "Issues a DELETE request and returns the Cloudflare `result` on success."
  @spec delete(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def delete(path, opts \\ []) when is_binary(path) and is_list(opts) do
    request(:delete, path, opts)
  end

  @doc """
  Issues a request and normalizes Cloudflare's response envelope.
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(method, path, opts \\ [])
      when is_atom(method) and is_binary(path) and is_list(opts) do
    with {:ok, req} <- build_req(opts) do
      case Req.request(req, build_req_opts(method, path, opts)) do
        {:ok, %Req.Response{status: status, body: body}} ->
          normalize_cloudflare_envelope(status, body)

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  @doc """
  Issues a request and returns the full Cloudflare envelope components.

  Useful when pagination info is required (e.g. zones listing).
  """
  @spec request_envelope(atom(), String.t(), keyword()) ::
          {:ok,
           %{status: non_neg_integer(), result: term(), result_info: term() | nil, body: map()}}
          | {:error, term()}
  def request_envelope(method, path, opts \\ [])
      when is_atom(method) and is_binary(path) and is_list(opts) do
    with {:ok, req} <- build_req(opts) do
      case Req.request(req, build_req_opts(method, path, opts)) do
        {:ok, %Req.Response{status: status, body: %{"success" => true} = body}} ->
          {:ok,
           %{
             status: status,
             result: Map.get(body, "result"),
             result_info: Map.get(body, "result_info"),
             body: body
           }}

        {:ok, %Req.Response{status: status, body: %{"success" => false} = body}} ->
          errors = Map.get(body, "errors", [])
          {:error, {:cloudflare, status, errors, body}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:unexpected_response, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp build_req(opts) do
    token = opts[:token] || Config.api_token()

    if is_binary(token) and token != "" do
      base = [
        base_url: @base_url,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"content-type", "application/json"}
        ]
      ]

      base =
        case opts[:adapter] do
          nil -> base
          adapter -> Keyword.put(base, :adapter, adapter)
        end

      {:ok, Req.new(base)}
    else
      {:error, :missing_api_token}
    end
  end

  defp build_req_opts(method, path, opts) do
    opts
    |> Keyword.drop([:token, :adapter])
    |> Keyword.put(:method, method)
    |> Keyword.put(:url, path)
  end

  defp normalize_cloudflare_envelope(_status, %{"success" => true, "result" => result}),
    do: {:ok, result}

  defp normalize_cloudflare_envelope(_status, %{"success" => true} = body),
    do: {:ok, Map.get(body, "result")}

  defp normalize_cloudflare_envelope(status, %{"success" => false} = body) do
    errors = Map.get(body, "errors", [])
    {:error, {:cloudflare, status, errors, body}}
  end

  defp normalize_cloudflare_envelope(status, body),
    do: {:error, {:unexpected_response, status, body}}
end
