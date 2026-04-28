defmodule Flared.Provisioner.LocalTest do
  use ExUnit.Case, async: true

  alias Flared.Provisioner.Local

  describe "provision/3" do
    test "requires routes" do
      assert {:error, :missing_routes} =
               Local.provision("flare", [],
                 account_id: "x",
                 cloudflared_dir: "/tmp/flared-test",
                 dry_run?: true
               )
    end
  end

  describe "deprovision/3" do
    test "requires routes" do
      assert {:error, :missing_routes} =
               Local.deprovision("flare", [],
                 account_id: "x",
                 cloudflared_dir: "/tmp/flared-test",
                 dry_run?: true
               )
    end
  end
end
