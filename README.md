# Flared

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `flare` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:flared, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/flare>.

## Token-based config generation

Generate a `config.yml` for token-based tunnel runs:

```bash
mix flared.gen.config \
  --tunnel-id <tunnel-id> \
  --route chat.example.com=http://localhost:4000 \
  --route api.example.com=http://localhost:4001 \
  --dest .cloudflared
```

Run `cloudflared` with a token:

```bash
export CLOUDFLARED_TOKEN=...
cloudflared tunnel --config .cloudflared/config.yml run --token $CLOUDFLARED_TOKEN
```

The generated config omits `credentials-file`. Token auth replaces the local
`<tunnel-id>.json` credentials file.
