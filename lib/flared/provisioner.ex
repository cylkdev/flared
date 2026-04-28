defmodule Flared.Provisioner do
  @moduledoc """
  Single entry point for provisioning Cloudflare tunnels.

  Wraps `Flared.Provisioner.Local` and `Flared.Provisioner.Remote`
  behind named functions so callers do not have to choose between the
  two submodules at the call site. The function name encodes the mode:
  `*_local` writes on-disk `cloudflared` artifacts; `*_remote` pushes
  ingress rules to the Cloudflare API and uses a token-based connector.

  See `Flared.Provisioner.Local` and `Flared.Provisioner.Remote` for
  full descriptions of the two modes, options, and result shapes.

  ## Functions

    * `provision_local/3`, `provision_remote/3` — create the tunnel,
      DNS records, and (local mode only) on-disk artifacts.
    * `deprovision_local/3`, `deprovision_remote/3` — delete DNS,
      tunnel, and (local mode only) on-disk artifacts.
    * `parse_route/1` — parse a `--route` flag string into a route map.
  """

  alias Flared.Provisioner.{Common, Local, Remote}

  @type route :: Remote.route()

  @doc """
  Provisions a local-mode tunnel.

  Calls `Flared.Provisioner.Local.provision/3`. See that function for
  option and result details.
  """
  @spec provision_local(String.t(), [route()], keyword()) ::
          {:ok, Local.result()} | {:error, term()}
  def provision_local(tunnel_name, routes, opts \\ []) do
    Local.provision(tunnel_name, routes, opts)
  end

  @doc """
  Provisions a remote-mode tunnel.

  Calls `Flared.Provisioner.Remote.provision/3`. See that function for
  option and result details.
  """
  @spec provision_remote(String.t(), [route()], keyword()) ::
          {:ok, Remote.result()} | {:error, term()}
  def provision_remote(tunnel_name, routes, opts \\ []) do
    Remote.provision(tunnel_name, routes, opts)
  end

  @doc """
  Deprovisions a local-mode tunnel.

  Calls `Flared.Provisioner.Local.deprovision/3`. See that function for
  option and result details.
  """
  @spec deprovision_local(String.t(), [route()], keyword()) ::
          {:ok, Local.deprovision_result()} | {:error, term()}
  def deprovision_local(tunnel_name, routes, opts \\ []) do
    Local.deprovision(tunnel_name, routes, opts)
  end

  @doc """
  Deprovisions a remote-mode tunnel.

  Calls `Flared.Provisioner.Remote.deprovision/3`. See that function
  for option and result details.
  """
  @spec deprovision_remote(String.t(), [route()], keyword()) ::
          {:ok, Remote.deprovision_result()} | {:error, term()}
  def deprovision_remote(tunnel_name, routes, opts \\ []) do
    Remote.deprovision(tunnel_name, routes, opts)
  end

  @doc """
  Parses a single `--route` flag value into a route map.

  Format: `<hostname>=<service>[,ttl=<n>][,zone_id=<zone_id>]`.

  Local and Remote modes share the same route format, so this is
  mode-agnostic. Calls `Flared.Provisioner.Common.parse_route/1`.
  """
  @spec parse_route(String.t()) :: {:ok, route()} | {:error, term()}
  def parse_route(value) do
    Common.parse_route(value)
  end
end
