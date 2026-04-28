defmodule Flared do
  @moduledoc """
  Flared provisions Cloudflare tunnels from Elixir.

  This module is a docs hub. The public API lives in `Flared.TunnelCLI`.

  ## Two ways to run a tunnel

    - **Remote** — ingress rules are pushed to the Cloudflare API;
      `cloudflared` runs with `--token <TOKEN>`. Stateless on disk.
    - **Local** — ingress rules are written to a local `config.yml`;
      credentials are written to `<config_dir>/<UUID>.json`;
      `cloudflared` runs with `--config <path> tunnel run`.

  ## Getting Started

  ### 1. Configure credentials

  In `config/runtime.exs`:

      import Config

      config :flared,
        api_token: System.fetch_env!("CLOUDFLARE_API_TOKEN"),
        account_id: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID")

  The `:api_token` must be a **User API Token** (My Profile → API Tokens)
  with `Cloudflare Tunnel:Edit`/`Read`, `DNS:Edit`, and `Zone:Read`
  scoped to the zones you will route to. See `Flared.Provisioner.Remote`
  for full token requirements.

  ### 2. Run a tunnel

      routes = [
        %{hostname: "chat.example.com", service: "http://localhost:4000"},
        %{hostname: "api.example.com",  service: "http://localhost:4001"}
      ]

      Flared.TunnelCLI.run_remote("site-a", routes)

  Or, to run with a local `config.yml`:

      Flared.TunnelCLI.run_local("site-a", routes, config_dir: ".cloudflared/site-a")

  Both block until `cloudflared` exits, then deprovision the
  Cloudflare-side resources before returning.

  ### 3. Inspect a tunnel

      Flared.TunnelCLI.status("site-a")
      #=> {:ok, %{name: "site-a", exists: true, tunnel_id: "..."}}

  The tunnel `name` is a required first positional argument on every
  `Flared.TunnelCLI` function.

  ## What lives where

  | Module                      | Purpose                                          |
  | --------------------------- | ------------------------------------------------ |
  | `Flared.TunnelCLI`             | Stateless high-level tunnel API.                 |
  | `Flared.Provisioner.Remote` | API-managed (token mode) provisioning.           |
  | `Flared.Provisioner.Local`  | Local-config provisioning + on-disk artifacts.   |
  | `Flared.Credentials`        | Builds the `<UUID>.json` credentials file.       |
  | `Flared.Config`             | Reads `:api_token`, `:account_id`, DNS defaults. |
  """
end
