defmodule Flared.Provisioner.RemoteTest do
  use ExUnit.Case, async: true

  alias Flared.Provisioner.Remote

  test "deprovision/3 requires routes" do
    assert {:error, :missing_routes} =
             Remote.deprovision("flare", [], account_id: "x", dry_run?: true)
  end
end
