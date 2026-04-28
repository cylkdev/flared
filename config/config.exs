import Config

config :flared,
  api_token: [{:system, "CLOUDFLARE_API_TOKEN"}],
  account_id: [{:system, "CLOUDFLARE_ACCOUNT_ID"}],
  config_dir: [{:system, "CLOUDFLARE_CONFIG_DIR"}, ".cloudflared"],
  executable: [{:system, "CLOUDFLARE_EXECUTABLE"}, "cloudflared"],
  tmp_dir: [{:system, "CLOUDFLARE_TMP_DIR"}],
  dns: %{ttl: 1}

if File.exists?(Path.expand("config.secrets.exs", __DIR__)) do
  import_config "config.secrets.exs"
end
