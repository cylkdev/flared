defmodule Flared.ZonesTest do
  use ExUnit.Case, async: true

  alias Flared.Zones

  test "resolve_zone_id/2 chooses the longest suffix match" do
    zones = [
      %{"id" => "1", "name" => "example.com"},
      %{"id" => "2", "name" => "sub.example.com"}
    ]

    assert {:ok, "2"} = Zones.resolve_zone_id("a.sub.example.com", zones)
  end

  test "resolve_zone_id/2 errors when no zone matches" do
    zones = [%{"id" => "1", "name" => "example.com"}]
    assert {:error, :zone_not_found} = Zones.resolve_zone_id("nope.test", zones)
  end

  test "resolve_zone_id/2 errors when ambiguous" do
    zones = [
      %{"id" => "1", "name" => "example.com"},
      %{"id" => "2", "name" => "example.com"}
    ]

    assert {:error, {:ambiguous_zone_match, 11, ["1", "2"]}} =
             Zones.resolve_zone_id("a.example.com", zones)
  end
end
