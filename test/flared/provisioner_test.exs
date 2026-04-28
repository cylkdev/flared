defmodule Flared.ProvisionerTest do
  use ExUnit.Case, async: true

  alias Flared.Provisioner

  describe "provision_local/3" do
    test "requires routes" do
      assert {:error, :missing_routes} =
               Provisioner.provision_local("flare", [],
                 account_id: "x",
                 config_dir: "/tmp/flared-test",
                 dry_run?: true
               )
    end
  end

  describe "provision_remote/3" do
    test "requires routes" do
      assert {:error, :missing_routes} =
               Provisioner.provision_remote("flare", [], account_id: "x", dry_run?: true)
    end
  end

  describe "deprovision_local/3" do
    test "requires routes" do
      assert {:error, :missing_routes} =
               Provisioner.deprovision_local("flare", [],
                 account_id: "x",
                 config_dir: "/tmp/flared-test",
                 dry_run?: true
               )
    end
  end

  describe "deprovision_remote/3" do
    test "requires routes" do
      assert {:error, :missing_routes} =
               Provisioner.deprovision_remote("flare", [], account_id: "x", dry_run?: true)
    end
  end

  describe "parse_route/1" do
    test "parses hostname and service" do
      assert {:ok, %{hostname: "chat.example.com", service: "http://localhost:4000"}} =
               Provisioner.parse_route("chat.example.com=http://localhost:4000")
    end

    test "parses optional ttl and zone_id" do
      assert {:ok,
              %{
                hostname: "chat.example.com",
                service: "http://localhost:4000",
                ttl: 60,
                zone_id: "zone123"
              }} =
               Provisioner.parse_route(
                 "chat.example.com=http://localhost:4000,ttl=60,zone_id=zone123"
               )
    end

    test "rejects invalid ttl" do
      assert {:error, {:invalid_ttl, "nope"}} =
               Provisioner.parse_route("chat.example.com=http://localhost:4000,ttl=nope")
    end

    test "rejects invalid head" do
      assert {:error, {:invalid_route_head, "nope"}} = Provisioner.parse_route("nope")
    end
  end
end
