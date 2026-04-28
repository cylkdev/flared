import Config

config :flared,
  api_token: [{:system, "CLOUDFLARE_API_TOKEN"}],
  account_id: [{:system, "CLOUDFLARE_ACCOUNT_ID"}],
  cloudflared_dir: [{:system, "CLOUDFLARED_DIR"}, ".cloudflared"],
  executable: [{:system, "CLOUDFLARED_EXECUTABLE"}, "cloudflared"],
  tmp_dir: [{:system, "CLOUDFLARED_TMP_DIR"}],
  dns: %{ttl: 1}

if File.exists?(Path.expand("config.secrets.exs", __DIR__)) do
  import_config "config.secrets.exs"
end
