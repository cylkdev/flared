defmodule Flared.Proxy do
  @moduledoc """
  A proxy endpoint for your Phoenix application.

  ## Usage

  To add a proxy endpoint to your application, add the following to your `application.ex`:

  ```elixir
  children =
    [
      {
        Flared.Proxy,
        endpoint: FlaredWeb.Endpoint,
        host: "chat.example.com",
        secret_key_base: "secret_key_base"
      }
    ]
  ```
  """

  @adapter Bandit.PhoenixAdapter
  @server_enabled false

  def start_link(endpoint, options \\ []) do
    options
    |> Keyword.put(:adapter, @adapter)
    |> Keyword.put(:server, options[:server] || @server_enabled)
    |> put_url_options()
    |> put_http_options()
    |> put_force_ssl_options()
    |> ensure_secret_key_base!()
    |> endpoint.start_link()
  end

  def child_spec({endpoint, options}) do
    %{
      id: {__MODULE__, endpoint},
      start: {__MODULE__, :start_link, [endpoint, options]},
      restart: Keyword.get(options, :restart, :permanent),
      shutdown: Keyword.get(options, :shutdown, 5_000),
      type: :supervisor
    }
  end

  def child_spec(opts) do
    opts |> Keyword.pop!(:endpoint) |> child_spec()
  end

  defp put_force_ssl_options(options) do
    Keyword.update(options, :force_ssl, [rewrite_on: [:x_forwarded_proto]], fn ssl_opts ->
      Keyword.update(ssl_opts, :rewrite_on, [:x_forwarded_proto], fn values ->
        Enum.uniq([:x_forwarded_proto | values])
      end)
    end)
  end

  defp put_http_options(options) do
    Keyword.put(options, :http, ip: :loopback, port: 4000)
  end

  defp put_url_options(options) do
    {host, options} = Keyword.pop!(options, :host)
    required_options = [host: host, port: 443, scheme: "https"]
    Keyword.update(options, :url, required_options, &Keyword.merge(&1, required_options))
  end

  defp ensure_secret_key_base!(options) do
    unless Keyword.has_key?(options, :secret_key_base) do
      raise ArgumentError, "missing :secret_key_base option, got: #{inspect(options)}"
    end

    options
  end
end
