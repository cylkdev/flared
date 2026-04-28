defmodule Flared.CredentialsTest do
  use ExUnit.Case, async: false

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
    test "writes <cloudflared_dir>/<tunnel_id>.json with the expected content" do
      dir = Path.join(System.tmp_dir!(), "flared-creds-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, path} =
        Credentials.write("tunnel-uuid-abc", "my-tunnel", @valid_token, cloudflared_dir: dir)

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

    test "creates the cloudflared_dir if it does not exist" do
      base = System.tmp_dir!()
      dir = Path.join([base, "flared-creds-#{System.unique_integer([:positive])}", "nested"])
      on_exit(fn -> File.rm_rf!(dir) end)

      refute File.exists?(dir)
      assert {:ok, _path} = Credentials.write("uuid", "name", @valid_token, cloudflared_dir: dir)
      assert File.dir?(dir)
    end

    test "propagates token decode errors" do
      assert {:error, {:invalid_token, _}} =
               Credentials.write("uuid", "name", "!!!not-base64!!!",
                 cloudflared_dir: System.tmp_dir!()
               )
    end

    test "falls back to Flared.Config.cloudflared_dir/0 when :cloudflared_dir option is absent" do
      base = System.tmp_dir!()
      dir = Path.join(base, "flared-creds-cfg-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      Application.put_env(:flared, :cloudflared_dir, dir)
      on_exit(fn -> Application.delete_env(:flared, :cloudflared_dir) end)

      assert {:ok, path} = Credentials.write("cfg-uuid", "n", @valid_token)

      assert path === Path.join(dir, "cfg-uuid.json")
    end
  end

  describe "path/2" do
    test "returns the path without touching the filesystem" do
      assert "/tmp/dir/uuid.json" === Credentials.path("uuid", cloudflared_dir: "/tmp/dir")
    end

    test "falls back to Flared.Config.cloudflared_dir/0 when :cloudflared_dir option is absent" do
      Application.put_env(:flared, :cloudflared_dir, "/from-config")
      on_exit(fn -> Application.delete_env(:flared, :cloudflared_dir) end)

      assert "/from-config/uuid.json" === Credentials.path("uuid")
    end
  end
end
