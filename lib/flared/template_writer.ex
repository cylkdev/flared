defmodule Flared.TemplateWriter do
  @moduledoc """
  Renders and writes the `cloudflared` config template located at
  `priv/eex/cloudflared/config.yml.eex`.

  This module is the assigns-based API. Callers provide a map of assigns, and
  this module handles defaults and writing.
  """

  @type assigns :: %{optional(atom()) => term()}

  @type write_opt ::
          {:filename, Path.t()}
          | {:mode, non_neg_integer() | nil}
          | {:overwrite?, boolean()}

  @type template_opt :: {:template_path, String.t()} | {:credentials_path, String.t()}

  @app :flared
  @required_assign_keys [:hostname, :tunnel_id]

  @spec render(assigns(), [template_opt()]) :: {:ok, iodata()} | {:error, term()}
  def render(assigns, opts \\ []) when is_map(assigns) and is_list(opts) do
    template_path = template_path(opts)

    with :ok <- ensure_template_exists(template_path),
         :ok <- validate_required_assigns(assigns),
         assigns <- normalize_assigns(assigns, opts) do
      {:ok, EEx.eval_file(template_path, assigns: assigns)}
    end
  rescue
    exception -> {:error, {:render_failed, exception}}
  end

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
    end
  end

  defp normalize_assigns(assigns, opts) do
    credentials_path =
      cond do
        is_binary(Map.get(assigns, :credentials_path)) -> Map.fetch!(assigns, :credentials_path)
        is_binary(opts[:credentials_path]) -> opts[:credentials_path]
        true -> "~/.cloudflared/"
      end
      |> Path.expand()

    assigns
    |> Map.put(:credentials_path, credentials_path)
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

  defp validate_required_assigns(assigns) do
    missing =
      Enum.reject(@required_assign_keys, fn key ->
        Map.has_key?(assigns, key) and not is_nil(Map.get(assigns, key))
      end)

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_assigns, keys}}
    end
  end

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
