defmodule Flared.ConfigYML do
  @moduledoc """
  Generates `cloudflared` config artifacts from tunnel routes.

  Provides a domain-level API on top of `Flared.Template` that
  takes a list of routes and a tunnel ID and produces (or writes) the
  rendered `config.yml`.
  """

  alias Flared.Template

  @type route :: %{required(:hostname) => String.t(), required(:service) => String.t()}

  @type write_opt ::
          {:filename, Path.t()}
          | {:mode, non_neg_integer() | nil}
          | {:overwrite?, boolean()}

  @type template_opt :: {:template_path, String.t()}

  @doc """
  Renders a `cloudflared` config from routes and a tunnel ID.

  ### Examples

    iex> routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
    ...> Flared.ConfigYML.render(routes, "tunnel-id")
    {:ok, _contents}
  """
  @spec render(list(route()), String.t(), [template_opt()]) ::
          {:ok, iodata()} | {:error, term()}
  def render(routes, tunnel_id, opts \\ [])
      when is_list(routes) and is_binary(tunnel_id) and is_list(opts) do
    Template.render(%{routes: routes, tunnel_id: tunnel_id}, opts)
  end

  @doc """
  Generates a `cloudflared` config and writes it to the destination directory.

  ### Examples

    iex> routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
    ...> Flared.ConfigYML.generate(".cloudflared", routes, "tunnel-id")
    {:ok, _path}
  """
  @spec generate(
          Path.t(),
          list(route()),
          String.t(),
          [write_opt() | template_opt()]
        ) :: {:ok, Path.t()} | {:error, term()}
  def generate(dest_dir, routes, tunnel_id, opts \\ [])
      when is_binary(dest_dir) and is_list(routes) and is_binary(tunnel_id) and is_list(opts) do
    Template.write(dest_dir, %{routes: routes, tunnel_id: tunnel_id}, opts)
  end
end
