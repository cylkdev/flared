defmodule Flared.TokensTest do
  use ExUnit.Case, async: true

  alias Flared.Tokens

  test "verify_user_api_token/1 GETs /user/tokens/verify and returns the unwrapped token result" do
    token_result = %{
      "id" => "ed17574386854bf78a67040be0a770b0",
      "status" => "active",
      "not_before" => "2018-07-01T05:20:00Z",
      "expires_on" => "2020-01-01T00:00:00Z"
    }

    parent = self()

    adapter = fn request ->
      send(parent, {:request, request.method, URI.to_string(request.url)})

      response = %Req.Response{
        status: 200,
        body: %{
          "success" => true,
          "errors" => [],
          "messages" => [],
          "result" => token_result
        }
      }

      {request, response}
    end

    assert {:ok, ^token_result} = Tokens.verify_user_api_token(stub_opts(adapter))
    assert_received {:request, :get, url}
    assert url =~ "/user/tokens/verify"
  end

  test "verify_user_api_token/1 returns a Cloudflare error tuple when the envelope reports failure" do
    adapter = fn request ->
      response = %Req.Response{
        status: 401,
        body: %{
          "success" => false,
          "errors" => [%{"code" => 1000, "message" => "Invalid API Token"}],
          "messages" => [],
          "result" => nil
        }
      }

      {request, response}
    end

    assert {:error, {:cloudflare, 401, errors, _body}} =
             Tokens.verify_user_api_token(stub_opts(adapter))

    assert [%{"code" => 1000, "message" => "Invalid API Token"}] = errors
  end

  test "verify_account_api_token/2 GETs /accounts/{account_id}/tokens/verify and returns the unwrapped token result" do
    account_id = "a67e14daa5f8dceeb91fe5449ba496ea"

    token_result = %{
      "id" => "ed17574386854bf78a67040be0a770b0",
      "status" => "active",
      "not_before" => "2018-07-01T05:20:00Z",
      "expires_on" => "2020-01-01T00:00:00Z"
    }

    parent = self()

    adapter = fn request ->
      send(parent, {:request, request.method, URI.to_string(request.url)})

      response = %Req.Response{
        status: 200,
        body: %{
          "success" => true,
          "errors" => [],
          "messages" => [],
          "result" => token_result
        }
      }

      {request, response}
    end

    assert {:ok, ^token_result} =
             Tokens.verify_account_api_token(account_id, stub_opts(adapter))

    assert_received {:request, :get, url}
    assert url =~ "/accounts/#{account_id}/tokens/verify"
  end

  test "verify_account_api_token/2 returns a Cloudflare error tuple when the envelope reports failure" do
    account_id = "a67e14daa5f8dceeb91fe5449ba496ea"

    adapter = fn request ->
      response = %Req.Response{
        status: 403,
        body: %{
          "success" => false,
          "errors" => [%{"code" => 10_000, "message" => "Authentication error"}],
          "messages" => [],
          "result" => nil
        }
      }

      {request, response}
    end

    assert {:error, {:cloudflare, 403, errors, _body}} =
             Tokens.verify_account_api_token(account_id, stub_opts(adapter))

    assert [%{"code" => 10_000, "message" => "Authentication error"}] = errors
  end

  defp stub_opts(adapter), do: [token: "test-token", adapter: adapter]
end
