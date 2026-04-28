defmodule Flared.Template do
  @moduledoc """
  Renders and writes a `cloudflared` config template.

  Assigns are passed straight through to the EEx template. They must use
  atom keys and supply `:tunnel_id` (a non-empty binary) and `:routes` (a
  list of `%{hostname: binary, service: binary}` maps with atom keys).
  """

  @type route :: %{required(:hostname) => String.t(), required(:service) => String.t()}
  @type assigns :: %{required(:tunnel_id) => String.t(), required(:routes) => [route()]}

  @type write_opt ::
          {:filename, Path.t()}
          | {:mode, non_neg_integer() | nil}
          | {:overwrite?, boolean()}

  @type template_opt :: {:template_path, String.t()}

  @app :flared

  @doc """
  Renders the config template from assigns.

  ### Examples

    iex> assigns = %{routes: [%{hostname: "chat.example.com", service: "http://localhost:4000"}], tunnel_id: "tunnel-id"}
    ...> Flared.Template.render(assigns)
    {:ok, _contents}
  """
  @spec render(assigns(), [template_opt()]) :: {:ok, iodata()} | {:error, term()}
  def render(assigns, opts \\ []) when is_map(assigns) and is_list(opts) do
    template_path = template_path(opts)

    with :ok <- ensure_template_exists(template_path),
         :ok <- validate_assigns(assigns) do
      {:ok, EEx.eval_file(template_path, assigns: assigns)}
    else
      {:error, _} = error -> error
    end
  rescue
    exception -> {:error, {:render_failed, exception}}
  end

  @doc """
  Writes the rendered config template to the destination directory.

  ### Examples

    iex> assigns = %{routes: [%{hostname: "chat.example.com", service: "http://localhost:4000"}], tunnel_id: "tunnel-id"}
    ...> Flared.Template.write(".cloudflared", assigns)
    {:ok, _path}
  """
  @spec write(Path.t(), assigns(), [write_opt() | template_opt()]) ::
          {:ok, Path.t()} | {:error, term()}
  def write(dest_dir, assigns, opts \\ [])
      when is_binary(dest_dir) and is_map(assigns) and is_list(opts) do
    filename = Keyword.get(opts, :filename, "config.yml")
    mode = Keyword.get(opts, :mode, 0o600)
    overwrite? = Keyword.get(opts, :overwrite?, true)

    expanded_dest_dir = Path.expand(dest_dir)
    output_path = Path.join(expanded_dest_dir, filename)

    with :ok <- File.mkdir_p(expanded_dest_dir),
         {:ok, rendered} <- render(assigns, opts),
         :ok <- write_file(output_path, rendered, overwrite?),
         :ok <- maybe_chmod(output_path, mode) do
      {:ok, output_path}
    else
      {:error, _} = error -> error
    end
  end

  defp template_path(opts) do
    opts[:template_path] ||
      Application.app_dir(@app, "priv/eex/cloudflared/config.yml.eex")
  end

  defp ensure_template_exists(path) do
    if File.regular?(path) do
      :ok
    else
      {:error, {:template_not_found, path}}
    end
  end

  defp validate_assigns(%{tunnel_id: tunnel_id, routes: routes})
       when is_binary(tunnel_id) and tunnel_id != "" and is_list(routes) do
    validate_routes(routes)
  end

  defp validate_assigns(assigns) do
    missing =
      Enum.reject([:tunnel_id, :routes], fn key ->
        Map.has_key?(assigns, key) and not is_nil(Map.get(assigns, key))
      end)

    {:error, {:missing_assigns, missing}}
  end

  defp validate_routes(routes) do
    routes
    |> Enum.reduce_while(:ok, fn route, :ok ->
      case validate_route(route) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_route(%{hostname: hostname, service: service})
       when is_binary(hostname) and hostname != "" and is_binary(service) and service != "" do
    :ok
  end

  defp validate_route(route), do: {:error, {:invalid_route, route}}

  defp write_file(path, contents, overwrite?) do
    if overwrite? do
      File.write(path, contents)
    else
      case File.open(path, [:write, :exclusive]) do
        {:ok, io_device} ->
          try do
            IO.binwrite(io_device, contents)
            :ok
          after
            File.close(io_device)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_chmod(_path, nil), do: :ok

  defp maybe_chmod(path, mode) when is_integer(mode) do
    File.chmod(path, mode)
  end
end
