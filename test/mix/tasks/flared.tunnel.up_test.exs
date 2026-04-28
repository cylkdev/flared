defmodule Mix.Tasks.Flared.Tunnel.UpTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Flared.Tunnel.Up

  describe "fetch_name/1" do
    test "returns the name when --name is set" do
      assert {:ok, "api"} = Up.fetch_name(name: "api")
    end

    test "rejects empty --name as missing" do
      assert {:error, :missing_name} = Up.fetch_name(name: "")
    end

    test "rejects absent --name as missing" do
      assert {:error, :missing_name} = Up.fetch_name([])
    end
  end

  describe "validate_mode/1" do
    test "returns remote when only --token is set" do
      assert {:ok, {:remote, "abc"}} = Up.validate_mode(token: "abc")
    end

    test "returns config when only --config is set" do
      assert {:ok, {:config, "/tmp/config.yml"}} =
               Up.validate_mode(config: "/tmp/config.yml")
    end

    test "rejects when both --token and --config are set" do
      assert {:error, :conflicting_modes} =
               Up.validate_mode(token: "abc", config: "/tmp/config.yml")
    end

    test "rejects when neither --token nor --config is set" do
      assert {:error, :missing_mode} = Up.validate_mode([])
    end

    test "treats empty --token as missing" do
      assert {:error, :missing_mode} = Up.validate_mode(token: "")
    end

    test "treats empty --config as missing" do
      assert {:error, :missing_mode} = Up.validate_mode(config: "")
    end

    test "treats empty --token plus valid --config as config mode" do
      assert {:ok, {:config, "/tmp/c.yml"}} =
               Up.validate_mode(token: "", config: "/tmp/c.yml")
    end

    test "treats empty --config plus valid --token as remote mode" do
      assert {:ok, {:remote, "abc"}} = Up.validate_mode(token: "abc", config: "")
    end
  end

  describe "validate_mode/2 with TUNNEL_TOKEN env value" do
    test "uses env token when --token flag is absent" do
      assert {:ok, {:remote, "env-token"}} = Up.validate_mode([], "env-token")
    end

    test "--token flag wins over env token" do
      assert {:ok, {:remote, "flag-token"}} =
               Up.validate_mode([token: "flag-token"], "env-token")
    end

    test "--config wins over env token (env vars are ambient, not a conflict)" do
      assert {:ok, {:config, "/tmp/c.yml"}} =
               Up.validate_mode([config: "/tmp/c.yml"], "env-token")
    end

    test "treats empty env token as missing" do
      assert {:error, :missing_mode} = Up.validate_mode([], "")
    end

    test "treats nil env token the same as the /1 arity" do
      assert {:error, :missing_mode} = Up.validate_mode([], nil)
    end

    test "rejects --token + --config even when env token is set" do
      assert {:error, :conflicting_modes} =
               Up.validate_mode([token: "flag", config: "/c.yml"], "env-token")
    end

    test "ignores empty env token when --token flag is also empty" do
      assert {:error, :missing_mode} = Up.validate_mode([token: ""], "")
    end
  end

  describe "build_command/2" do
    test "remote mode omits the token from argv" do
      assert ~c"cloudflared tunnel run" =
               Up.build_command("cloudflared", {:remote, "abc"})
    end

    test "config mode produces --config argv" do
      assert ~c"cloudflared --config /tmp/config.yml tunnel run" =
               Up.build_command("cloudflared", {:config, "/tmp/config.yml"})
    end

    test "honours custom executable in remote mode" do
      assert ~c"/opt/cf tunnel run" =
               Up.build_command("/opt/cf", {:remote, "T"})
    end

    test "honours custom executable in config mode" do
      assert ~c"/opt/cf --config /etc/cf.yml tunnel run" =
               Up.build_command("/opt/cf", {:config, "/etc/cf.yml"})
    end
  end

  describe "build_env/1" do
    test "remote mode passes the token via TUNNEL_TOKEN" do
      assert [{~c"TUNNEL_TOKEN", ~c"abc"}] = Up.build_env({:remote, "abc"})
    end

    test "config mode adds no env vars" do
      assert [] = Up.build_env({:config, "/tmp/config.yml"})
    end
  end
end
