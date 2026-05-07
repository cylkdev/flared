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

  Pass `credentials_file` as a non-empty path to embed a
  `credentials-file:` directive (local mode), or `nil` to omit it
  (token mode).

  ### Examples

    iex> routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
    ...> Flared.ConfigYML.render_config_yml(routes, "tunnel-id", nil)
    {:ok, _contents}
  """
  @spec render_config_yml(list(route()), String.t(), String.t() | nil, [template_opt()]) ::
          {:ok, iodata()} | {:error, term()}
  def render_config_yml(routes, tunnel_id, credentials_file, opts \\ [])
      when is_list(routes) and is_binary(tunnel_id) and
             (is_nil(credentials_file) or is_binary(credentials_file)) and is_list(opts) do
    Template.render(
      %{routes: routes, tunnel_id: tunnel_id, credentials_file: credentials_file},
      opts
    )
  end

  @doc """
  Generates a `cloudflared` config and writes it to the destination directory.

  See `render/4` for the meaning of `credentials_file`.

  ### Examples

    iex> routes = [%{hostname: "chat.example.com", service: "http://localhost:4000"}]
    ...> Flared.ConfigYML.generate_config_yml(".cloudflared", routes, "tunnel-id", nil)
    {:ok, _path}
  """
  @spec generate_config_yml(
          Path.t(),
          list(route()),
          String.t(),
          String.t() | nil,
          [write_opt() | template_opt()]
        ) :: {:ok, Path.t()} | {:error, term()}
  def generate_config_yml(dest_dir, routes, tunnel_id, credentials_file, opts \\ [])
      when is_binary(dest_dir) and is_list(routes) and is_binary(tunnel_id) and
             (is_nil(credentials_file) or is_binary(credentials_file)) and is_list(opts) do
    Template.write(
      dest_dir,
      %{routes: routes, tunnel_id: tunnel_id, credentials_file: credentials_file},
      opts
    )
  end
end
