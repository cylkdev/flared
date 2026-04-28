defmodule Flared.Tokens do
  @moduledoc """
  Cloudflare API token verification helpers.

  Cloudflare exposes two distinct verify endpoints, one for each kind of
  API token. They are not interchangeable, and using the wrong endpoint
  for a given token returns 403 with Cloudflare error code `10000`
  ("Authentication error"):

      {:error, {:cloudflare, 403,
        [%{"code" => 10000, "message" => "Authentication error"}], _body}}

  ## Token types

  - `verify_user_api_token/1` calls `GET /user/tokens/verify`. It only
    works with **User API Tokens** created under
    **My Profile → API Tokens**
    (https://dash.cloudflare.com/profile/api-tokens). These tokens are
    user-scoped and tied to your Cloudflare login.

  - `verify_account_api_token/2` calls
    `GET /accounts/{account_id}/tokens/verify`. It only works with
    **Account-owned API Tokens** created under
    *Manage Account → Account API Tokens*. These tokens are account-scoped
    and have no `/user/...` identity.

  Crossing token type and endpoint (a User API Token sent to the account
  endpoint, or an Account-owned API Token sent to the user endpoint)
  returns the 403 / code `10000` error shown above.

  Neither endpoint accepts the legacy **Global API Key**, which uses
  `X-Auth-Email` + `X-Auth-Key` headers rather than `Authorization: Bearer`.
  """

  alias Flared.Client

  @doc """
  Verifies a **User API Token**.

  Issues `GET /user/tokens/verify` and returns the Cloudflare-unwrapped
  `result` map describing the token. The result has the shape:

      %{
        "id" => "ed17574386854bf78a67040be0a770b0",
        "status" => "active",
        "not_before" => "2018-07-01T05:20:00Z",
        "expires_on" => "2020-01-01T00:00:00Z"
      }

  Only accepts User API Tokens (My Profile → API Tokens). Account-owned
  API Tokens sent to this endpoint return a 403 with Cloudflare error
  code `10000`.

  ## Options

  See `Flared.Client` for the supported options (notably `:token`).
  """
  @spec verify_user_api_token(keyword()) :: {:ok, map()} | {:error, term()}
  def verify_user_api_token(opts \\ []) when is_list(opts) do
    Client.get("/user/tokens/verify", opts)
  end

  @doc """
  Verifies an **Account-owned API Token** against the given `account_id`.

  Issues `GET /accounts/{account_id}/tokens/verify` and returns the
  Cloudflare-unwrapped `result` map describing the token. The result has
  the same shape as `verify_user_api_token/1`:

      %{
        "id" => "ed17574386854bf78a67040be0a770b0",
        "status" => "active",
        "not_before" => "2018-07-01T05:20:00Z",
        "expires_on" => "2020-01-01T00:00:00Z"
      }

  Only accepts Account-owned API Tokens (Manage Account → Account API
  Tokens). User API Tokens sent to this endpoint return a 403 with
  Cloudflare error code `10000`.

  ## Options

  See `Flared.Client` for the supported options (notably `:token`).
  """
  @spec verify_account_api_token(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_account_api_token(account_id, opts \\ [])
      when is_binary(account_id) and is_list(opts) do
    Client.get("/accounts/#{account_id}/tokens/verify", opts)
  end
end
