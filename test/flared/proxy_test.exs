defmodule Flared.ProxyTest do
  use ExUnit.Case, async: true

  defmodule EndpointStub do
    def start_link(opts) do
      Agent.start_link(fn -> opts end)
    end
  end

  defp start_proxy!(opts) do
    {:ok, pid} = Flared.Proxy.start_link(EndpointStub, opts)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    Agent.get(pid, & &1)
  end

  test "start_link/2 sets adapter and defaults server false in :test" do
    opts = start_proxy!(host: "chat.example.com", secret_key_base: "secret")

    assert opts[:adapter] == Bandit.PhoenixAdapter
    assert opts[:server] == false
  end

  test "start_link/2 can override server option" do
    opts = start_proxy!(host: "chat.example.com", secret_key_base: "secret", server: true)

    assert opts[:server] == true
  end

  test "start_link/2 forces http loopback:4000" do
    opts =
      start_proxy!(
        host: "chat.example.com",
        secret_key_base: "secret",
        http: [ip: {127, 0, 0, 1}, port: 1234]
      )

    assert opts[:http] == [ip: :loopback, port: 4000]
  end

  test "start_link/2 forces url scheme https and port 443 and host from :host option" do
    opts =
      start_proxy!(
        host: "chat.example.com",
        secret_key_base: "secret",
        url: [scheme: "http", port: 80, host: "wrong.example.com", path: "/keep"]
      )

    assert opts[:url][:scheme] == "https"
    assert opts[:url][:port] == 443
    assert opts[:url][:host] == "chat.example.com"
    assert opts[:url][:path] == "/keep"
  end

  test "start_link/2 force_ssl rewrite_on includes x_forwarded_proto" do
    opts = start_proxy!(host: "chat.example.com", secret_key_base: "secret")

    assert opts[:force_ssl][:rewrite_on] == [:x_forwarded_proto]
  end

  test "start_link/2 merges force_ssl rewrite_on and de-dupes x_forwarded_proto" do
    opts =
      start_proxy!(
        host: "chat.example.com",
        secret_key_base: "secret",
        force_ssl: [rewrite_on: [:x_forwarded_host, :x_forwarded_proto]]
      )

    assert opts[:force_ssl][:rewrite_on] == [:x_forwarded_proto, :x_forwarded_host]
  end

  test "start_link/2 raises when :host is missing" do
    assert_raise KeyError, fn ->
      Flared.Proxy.start_link(EndpointStub, secret_key_base: "secret")
    end
  end

  test "start_link/2 raises when :secret_key_base is missing" do
    assert_raise ArgumentError, ~r/missing :secret_key_base option/, fn ->
      Flared.Proxy.start_link(EndpointStub, host: "chat.example.com")
    end
  end

  test "child_spec/1 (keyword form) sets id, start args, and defaults restart/shutdown/type" do
    spec = Flared.Proxy.child_spec(endpoint: EndpointStub, host: "chat.example.com", secret_key_base: "secret")

    assert spec.id == {Flared.Proxy, EndpointStub}
    assert spec.start == {Flared.Proxy, :start_link, [EndpointStub, [host: "chat.example.com", secret_key_base: "secret"]]}
    assert spec.restart == :permanent
    assert spec.shutdown == 5_000
    assert spec.type == :supervisor
  end

  test "child_spec/1 (tuple form) supports restart/shutdown overrides" do
    spec =
      Flared.Proxy.child_spec(
        {EndpointStub, [host: "chat.example.com", secret_key_base: "secret", restart: :transient, shutdown: 10_000]}
      )

    assert spec.restart == :transient
    assert spec.shutdown == 10_000
  end
end

