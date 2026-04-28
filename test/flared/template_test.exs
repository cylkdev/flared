defmodule Flared.TemplateTest do
  use ExUnit.Case, async: true

  alias Flared.Template

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "flared_template_writer_#{System.unique_integer([:positive])}")
  end

  test "render/2 renders a single-route assigns map" do
    assigns = %{
      routes: [%{hostname: "chat.example.com", service: "http://localhost:4000"}],
      tunnel_id: "tunnel-id"
    }

    {:ok, contents} = Template.render(assigns)
    text = IO.iodata_to_binary(contents)

    assert text =~ "tunnel: tunnel-id"
    assert text =~ "hostname: chat.example.com"
    assert text =~ "service: http://localhost:4000"
    refute text =~ "credentials-file:"
  end

  test "render/2 emits credentials-file when the assign is present" do
    assigns = %{
      routes: [%{hostname: "chat.example.com", service: "http://localhost:4000"}],
      tunnel_id: "tunnel-id",
      credentials_file: "/abs/dir/tunnel-id.json"
    }

    {:ok, contents} = Template.render(assigns)
    text = IO.iodata_to_binary(contents)

    assert text =~ "credentials-file: /abs/dir/tunnel-id.json"
  end

  test "render/2 rejects an empty credentials_file assign" do
    assigns = %{
      routes: [%{hostname: "chat.example.com", service: "http://localhost:4000"}],
      tunnel_id: "tunnel-id",
      credentials_file: ""
    }

    assert {:error, {:invalid_credentials_file, ""}} = Template.render(assigns)
  end

  test "write/3 writes a config file from an assigns map" do
    assigns = %{
      routes: [%{hostname: "chat.example.com", service: "http://localhost:4000"}],
      tunnel_id: "tunnel-id"
    }

    dest_dir = tmp_dir()

    {:ok, path} = Template.write(dest_dir, assigns)

    assert File.exists?(path)
    assert File.read!(path) =~ "hostname: chat.example.com"
  end
end
