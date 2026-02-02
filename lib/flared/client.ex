defmodule Flared.Client do
  @moduledoc """
  Cloudflare API client wrapper around `Req`.

  This module is an internal building block for `Flared.Provisioner`.
  Most callers should use `Flared.Provisioner` or `mix flared.provision`
  instead of calling this module directly.

  ## Response handling

  Cloudflare API responses are normalized from the standard envelope:

  - `{:ok, result}` when `"success": true`
  - `{:error, {:cloudflare, status, errors, body}}` when `"success": false`
  """

  alias Flared.Config

  @base_url "https://api.cloudflare.com/client/v4"

  @type t :: %__MODULE__{
          req: Req.Request.t(),
          token: String.t()
        }

  defstruct [:req, :token]

  @doc """
  Builds a client using `Flared.Config.cloudflare_api_token/0` by default.

  Pass `token: "..."` to override for tests/callers.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    token = opts[:token] || Config.cloudflare_api_token()

    if is_binary(token) and token != "" do
      req =
        Req.new(
          base_url: @base_url,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/json"}
          ]
        )

      {:ok, %__MODULE__{req: req, token: token}}
    else
      {:error, :missing_cloudflare_api_token}
    end
  end

  @doc "Issues a GET request and returns the Cloudflare `result` on success."
  @spec get(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def get(%__MODULE__{} = client, path, params \\ %{}) when is_binary(path) and is_map(params) do
    request(client, :get, path, params: params)
  end

  @doc "Issues a POST request and returns the Cloudflare `result` on success."
  @spec post(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def post(%__MODULE__{} = client, path, body) when is_binary(path) and is_map(body) do
    request(client, :post, path, json: body)
  end

  @doc "Issues a PUT request and returns the Cloudflare `result` on success."
  @spec put(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def put(%__MODULE__{} = client, path, body) when is_binary(path) and is_map(body) do
    request(client, :put, path, json: body)
  end

  @doc "Issues a PATCH request and returns the Cloudflare `result` on success."
  @spec patch(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def patch(%__MODULE__{} = client, path, body) when is_binary(path) and is_map(body) do
    request(client, :patch, path, json: body)
  end

  @doc "Issues a DELETE request and returns the Cloudflare `result` on success."
  @spec delete(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def delete(%__MODULE__{} = client, path) when is_binary(path) do
    request(client, :delete, path)
  end

  @doc """
  Issues a request and normalizes Cloudflare's response envelope.
  """
  @spec request(t(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(%__MODULE__{} = client, method, path, opts \\ [])
      when is_atom(method) and is_binary(path) and is_list(opts) do
    req_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, path)

    case Req.request(client.req, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        normalize_cloudflare_envelope(status, body)

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Issues a request and returns the full Cloudflare envelope components.

  Useful when pagination info is required (e.g. zones listing).
  """
  @spec request_envelope(t(), atom(), String.t(), keyword()) ::
          {:ok,
           %{status: non_neg_integer(), result: term(), result_info: term() | nil, body: map()}}
          | {:error, term()}
  def request_envelope(%__MODULE__{} = client, method, path, opts \\ [])
      when is_atom(method) and is_binary(path) and is_list(opts) do
    req_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, path)

    case Req.request(client.req, req_opts) do
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
