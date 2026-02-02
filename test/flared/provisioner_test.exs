defmodule Flared.ProvisionerTest do
  use ExUnit.Case, async: true

  alias Flared.Provisioner

  test "parse_route/1 parses hostname and service" do
    assert {:ok, %{hostname: "chat.example.com", service: "http://localhost:4000"}} =
             Provisioner.parse_route("chat.example.com=http://localhost:4000")
  end

  test "parse_route/1 parses optional ttl and zone_id" do
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

  test "parse_route/1 rejects invalid ttl" do
    assert {:error, {:invalid_ttl, "nope"}} =
             Provisioner.parse_route("chat.example.com=http://localhost:4000,ttl=nope")
  end

  test "parse_route/1 rejects invalid head" do
    assert {:error, {:invalid_route_head, "nope"}} = Provisioner.parse_route("nope")
  end
end
