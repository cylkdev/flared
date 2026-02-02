defmodule Flared.DnsTest do
  use ExUnit.Case, async: true

  alias Flared.DNS

  test "desired_record/3 forces proxied true" do
    record = DNS.desired_record("chat.example.com", "tunnel-uuid", ttl: 1)

    assert record["type"] == "CNAME"
    assert record["name"] == "chat.example.com"
    assert record["content"] == "tunnel-uuid.cfargotunnel.com"
    assert record["proxied"] == true
    assert record["ttl"] == 1
  end
end
