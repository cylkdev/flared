defmodule Flared.TunnelsTest do
  use ExUnit.Case, async: true

  alias Flared.Tunnels

  test "build_ingress/1 appends catch-all 404 rule" do
    routes = [
      %{hostname: "chat.example.com", service: "http://localhost:4000"},
      %{hostname: "api.example.com", service: "http://localhost:4001"}
    ]

    ingress = Tunnels.build_ingress(routes)

    assert Enum.at(ingress, 0) == %{
             "hostname" => "chat.example.com",
             "service" => "http://localhost:4000"
           }

    assert Enum.at(ingress, 1) == %{
             "hostname" => "api.example.com",
             "service" => "http://localhost:4001"
           }

    assert List.last(ingress) == %{"service" => "http_status:404"}
  end
end
