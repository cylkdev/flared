defmodule Flared.ConfigYMLTest do
  use ExUnit.Case, async: true

  alias Flared.ConfigYML

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "flared_generator_#{System.unique_integer([:positive])}")
  end

  test "render/3 renders multiple routes and a catch-all" do
    routes = [
      %{hostname: "chat.example.com", service: "http://localhost:4000"},
      %{hostname: "api.example.com", service: "http://localhost:4001"}
    ]

    {:ok, contents} = ConfigYML.render_config_yml(routes, "tunnel-id", nil)
    text = IO.iodata_to_binary(contents)

    assert text =~ "hostname: chat.example.com"
    assert text =~ "service: http://localhost:4000"
    assert text =~ "hostname: api.example.com"
    assert text =~ "service: http://localhost:4001"
    assert text =~ "service: http_status:404"
  end

  test "generate/5 writes a config file from routes" do
    routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
    dest_dir = tmp_dir()

    {:ok, path} = ConfigYML.generate_config_yml(dest_dir, routes, "tunnel-id", nil)

    assert File.exists?(path)
    assert File.read!(path) =~ "hostname: chat.example.com"
  end

  test "render/4 emits credentials-file when credentials_file is given" do
    routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]

    {:ok, contents} =
      ConfigYML.render_config_yml(routes, "tunnel-id", "/abs/dir/tunnel-id.json")

    text = IO.iodata_to_binary(contents)

    assert text =~ "credentials-file: /abs/dir/tunnel-id.json"
  end

  test "render/4 omits credentials-file when credentials_file is nil" do
    routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]

    {:ok, contents} = ConfigYML.render_config_yml(routes, "tunnel-id", nil)
    text = IO.iodata_to_binary(contents)

    refute text =~ "credentials-file:"
  end

  test "generate/5 writes credentials-file into the file when given" do
    routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
    dest_dir = tmp_dir()

    {:ok, path} =
      ConfigYML.generate_config_yml(dest_dir, routes, "tunnel-id", "/abs/dir/tunnel-id.json")

    assert File.read!(path) =~ "credentials-file: /abs/dir/tunnel-id.json"
  end
end
