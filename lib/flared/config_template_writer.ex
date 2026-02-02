defmodule Flared.ConfigTemplateWriter do
  @moduledoc """
  Renders and writes the `cloudflared` config template located at
  `priv/eex/cloudflared/config.yml.eex`.
  """

  alias Flared.TemplateWriter

  @type assigns :: %{optional(atom()) => term()}
  @type write_opt ::
          {:filename, Path.t()}
          | {:mode, non_neg_integer() | nil}
          | {:overwrite?, boolean()}
  @type template_opt :: {:template_path, String.t()} | {:credentials_path, String.t()}

  @doc """
  Renders the config template and returns the rendered contents.

  ## Examples

      iex> Flared.ConfigTemplateWriter.render("chat.example.com", "my-tunnel-id")
  """
  @spec render(hostname :: String.t(), tunnel_id :: String.t(), [template_opt()]) ::
          {:ok, iodata()} | {:error, term()}
  def render(hostname, tunnel_id, opts \\ []) do
    TemplateWriter.render(%{hostname: hostname, tunnel_id: tunnel_id}, opts)
  end

  @doc """
  Renders the config template and writes it to the destination directory.

  ## Examples

      iex> Flared.ConfigTemplateWriter.write(".cloudflared/test/", "chat.example.com", "my-tunnel-id")
  """
  @spec write(
          dest_dir :: String.t(),
          hostname :: String.t(),
          tunnel_id :: String.t(),
          [write_opt() | template_opt()]
        ) :: {:ok, Path.t()} | {:error, term()}
  def write(dest_dir, hostname, tunnel_id, opts \\ []) do
    TemplateWriter.write(dest_dir, %{hostname: hostname, tunnel_id: tunnel_id}, opts)
  end
end
