defmodule Flared.CredentialsTest do
  use ExUnit.Case, async: true

  alias Flared.Credentials

  @valid_token Base.encode64(
                 Jason.encode!(%{
                   "a" => "acct-123",
                   "t" => "tunnel-uuid-abc",
                   "s" => "secret-base64=="
                 })
               )

  describe "from_token/2" do
    test "decodes a valid token into the cloudflared credentials map" do
      assert {:ok,
              %{
                "AccountTag" => "acct-123",
                "TunnelID" => "tunnel-uuid-abc",
                "TunnelName" => "my-tunnel",
                "TunnelSecret" => "secret-base64=="
              }} = Credentials.from_token(@valid_token, "my-tunnel")
    end

    test "rejects non-base64 input" do
      assert {:error, {:invalid_token, :invalid_base64}} =
               Credentials.from_token("!!!not-base64!!!", "name")
    end

    test "rejects base64 of non-JSON" do
      junk_token = Base.encode64("not json at all")

      assert {:error, {:invalid_token, {:invalid_json, _}}} =
               Credentials.from_token(junk_token, "name")
    end

    test "rejects payload missing required keys" do
      missing_token = Base.encode64(Jason.encode!(%{"a" => "x", "t" => "y"}))

      assert {:error, {:invalid_token, {:missing_fields, %{"a" => "x", "t" => "y"}}}} =
               Credentials.from_token(missing_token, "name")
    end
  end

  describe "write/4" do
    test "writes <config_dir>/<tunnel_id>.json with the expected content" do
      dir = Path.join(System.tmp_dir!(), "flared-creds-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, path} = Credentials.write(dir, "tunnel-uuid-abc", "my-tunnel", @valid_token)

      assert path === Path.join(dir, "tunnel-uuid-abc.json")
      assert File.exists?(path)

      assert {:ok,
              %{
                "AccountTag" => "acct-123",
                "TunnelID" => "tunnel-uuid-abc",
                "TunnelName" => "my-tunnel",
                "TunnelSecret" => "secret-base64=="
              }} = path |> File.read!() |> Jason.decode()
    end

    test "creates the config_dir if it does not exist" do
      base = System.tmp_dir!()
      dir = Path.join([base, "flared-creds-#{System.unique_integer([:positive])}", "nested"])
      on_exit(fn -> File.rm_rf!(dir) end)

      refute File.exists?(dir)
      assert {:ok, _path} = Credentials.write(dir, "uuid", "name", @valid_token)
      assert File.dir?(dir)
    end

    test "propagates token decode errors" do
      assert {:error, {:invalid_token, _}} =
               Credentials.write(System.tmp_dir!(), "uuid", "name", "!!!not-base64!!!")
    end
  end

  describe "path/2" do
    test "returns the path without touching the filesystem" do
      assert "/tmp/dir/uuid.json" === Credentials.path("/tmp/dir", "uuid")
    end
  end
end
