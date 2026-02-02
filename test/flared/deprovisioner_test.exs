defmodule Flared.DeprovisionerTest do
  use ExUnit.Case, async: true

  alias Flared.Provisioner

  test "deprovision/2 requires routes (same validation as provision)" do
    assert {:error, :missing_routes} = Provisioner.deprovision([], dry_run?: true)
  end
end
