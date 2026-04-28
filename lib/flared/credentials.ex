defmodule Flared.Credentials do
  @moduledoc """
  Builds and writes the credentials JSON file that locally-managed
  `cloudflared` expects on disk.

  The Cloudflare API returns a connector *token*: a base64-encoded JSON
  object of the shape `%{"a" => account_tag, "t" => tunnel_uuid, "s" =>
  tunnel_secret}`. The `cloudflared` binary, when launched without
  `--token`, reads a credentials file at
  `<cloudflared_dir>/<tunnel_id>.json` with a different shape:

      {
        "AccountTag":   "<account_tag>",
        "TunnelID":     "<tunnel_uuid>",
        "TunnelName":   "<name>",
        "TunnelSecret": "<tunnel_secret>"
      }

  This module decodes the token and writes the file.

  ## Resolving `cloudflared_dir`

  `write/4` and `path/2` resolve the destination directory in this order:

    1. `:cloudflared_dir` option, when given.
    2. `Flared.Config.cloudflared_dir/0`.
    3. The module-level default `#{inspect(".cloudflared")}`.
  """

  alias Flared.Config

  @default_cloudflared_dir ".cloudflared"

  @type credentials :: %{
          required(String.t()) => String.t()
        }

  @type opt :: {:cloudflared_dir, Path.t()}

  @doc """
  Decodes a cloudflared connector token into the credentials map that
  `cloudflared` expects on disk.

  Returns `{:error, {:invalid_token, reason}}` if the token is not
  valid base64 or its decoded payload is not a JSON object containing
  the expected `"a"`, `"t"`, and `"s"` keys.
  """
  @spec from_token(token :: String.t(), name :: String.t()) ::
          {:ok, credentials()} | {:error, {:invalid_token, term()}}
  def from_token(token, name)
      when is_binary(token) and token !== "" and is_binary(name) and name !== "" do
    with {:ok, json} <- decode_base64(token),
         {:ok, payload} <- decode_json(json),
         {:ok, account_tag, tunnel_uuid, secret} <- extract_fields(payload) do
      {:ok,
       %{
         "AccountTag" => account_tag,
         "TunnelID" => tunnel_uuid,
         "TunnelName" => name,
         "TunnelSecret" => secret
       }}
    end
  end

  @doc """
  Writes the credentials JSON for `token` to
  `<cloudflared_dir>/<tunnel_id>.json`.

  Creates the directory if it does not exist. Returns `{:ok, path}` on
  success or `{:error, reason}` if the token cannot be decoded or the
  file cannot be written.

  ## Options

    * `:cloudflared_dir` — directory to write into. See module docs for
      the resolution order when omitted.
  """
  @spec write(
          tunnel_id :: String.t(),
          name :: String.t(),
          token :: String.t(),
          opts :: [opt()]
        ) :: {:ok, Path.t()} | {:error, term()}
  def write(tunnel_id, name, token, opts \\ [])
      when is_binary(tunnel_id) and tunnel_id !== "" and is_list(opts) do
    cloudflared_dir = resolve_cloudflared_dir(opts)

    with {:ok, credentials} <- from_token(token, name),
         path = Path.join(cloudflared_dir, "#{tunnel_id}.json"),
         :ok <- File.mkdir_p(cloudflared_dir),
         {:ok, encoded} <- Jason.encode(credentials, pretty: true),
         :ok <- File.write(path, encoded) do
      {:ok, path}
    end
  end

  @doc """
  Returns the path the credentials file would be written to for
  `tunnel_id`, without touching the filesystem.

  ## Options

    * `:cloudflared_dir` — directory to resolve against. See module
      docs for the resolution order when omitted.
  """
  @spec path(tunnel_id :: String.t(), opts :: [opt()]) :: Path.t()
  def path(tunnel_id, opts \\ []) when is_binary(tunnel_id) and is_list(opts) do
    opts
    |> resolve_cloudflared_dir()
    |> Path.join("#{tunnel_id}.json")
  end

  defp resolve_cloudflared_dir(opts) do
    opts[:cloudflared_dir] || Config.cloudflared_dir() || @default_cloudflared_dir
  end

  defp decode_base64(token) do
    case Base.decode64(token, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> base64_with_padding(token)
    end
  end

  defp base64_with_padding(token) do
    case Base.decode64(token) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_token, :invalid_base64}}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:invalid_token, {:invalid_json, reason}}}
    end
  end

  defp extract_fields(%{"a" => a, "t" => t, "s" => s})
       when is_binary(a) and is_binary(t) and is_binary(s),
       do: {:ok, a, t, s}

  defp extract_fields(payload),
    do: {:error, {:invalid_token, {:missing_fields, payload}}}
end
