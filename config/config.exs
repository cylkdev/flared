import Config

config :flared,
  cloudflare_tunnel_name: "flared",
  cloudflare_dns_defaults: %{ttl: 1}

if File.exists?(Path.expand("config.secrets.exs", __DIR__)) do
  import_config "config.secrets.exs"
end
