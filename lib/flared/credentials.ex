defmodule Flared.Credentials do
  @moduledoc """
  Builds and writes the credentials JSON file that locally-managed
  `cloudflared` expects on disk.

  The Cloudflare API returns a connector *token*: a base64-encoded JSON
  object of the shape `%{"a" => account_tag, "t" => tunnel_uuid, "s" =>
  tunnel_secret}`. The `cloudflared` binary, when launched without
  `--token`, reads a credentials file at `<config_dir>/<tunnel_id>.json`
  with a different shape:

      {
        "AccountTag":   "<account_tag>",
        "TunnelID":     "<tunnel_uuid>",
        "TunnelName":   "<name>",
        "TunnelSecret": "<tunnel_secret>"
      }

  This module decodes the token and writes the file.
  """

  @type credentials :: %{
          required(String.t()) => String.t()
        }

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
  Writes the credentials JSON for `token` to `<config_dir>/<tunnel_id>.json`.

  Creates `config_dir` if it does not exist. Returns `{:ok, path}` on
  success or `{:error, reason}` if the token cannot be decoded or the
  file cannot be written.
  """
  @spec write(
          config_dir :: Path.t(),
          tunnel_id :: String.t(),
          name :: String.t(),
          token :: String.t()
        ) :: {:ok, Path.t()} | {:error, term()}
  def write(config_dir, tunnel_id, name, token)
      when is_binary(config_dir) and is_binary(tunnel_id) and tunnel_id !== "" do
    with {:ok, credentials} <- from_token(token, name),
         path = Path.join(config_dir, "#{tunnel_id}.json"),
         :ok <- File.mkdir_p(config_dir),
         {:ok, encoded} <- Jason.encode(credentials, pretty: true),
         :ok <- File.write(path, encoded) do
      {:ok, path}
    end
  end

  @doc """
  Returns the path the credentials file would be written to for
  `tunnel_id` under `config_dir`, without touching the filesystem.
  """
  @spec path(config_dir :: Path.t(), tunnel_id :: String.t()) :: Path.t()
  def path(config_dir, tunnel_id) when is_binary(config_dir) and is_binary(tunnel_id) do
    Path.join(config_dir, "#{tunnel_id}.json")
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
