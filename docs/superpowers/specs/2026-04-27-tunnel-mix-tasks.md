# Tunnel Mix Tasks — module and function specs

Date: 2026-04-27

Three Mix tasks that wrap `Flared.TunnelSupervisor` and `Flared.Tunnel` for CLI ergonomics.

## Files in scope

- `lib/mix/tasks/flared.tunnel.open.ex`
- `lib/mix/tasks/flared.tunnel.close.ex`
- `lib/mix/tasks/flared.tunnel.status.ex`
- `test/mix/tasks/flared.tunnel.open_test.exs`
- `test/mix/tasks/flared.tunnel.close_test.exs`
- `test/mix/tasks/flared.tunnel.status_test.exs`

## Files out of scope (must not be modified)

- `lib/flared/tunnel_supervisor.ex`
- `lib/flared/tunnel.ex`
- `lib/flared/provisioner.ex`
- `lib/flared/application.ex`
- `lib/mix/tasks/flared.provision.ex`
- `lib/mix/tasks/flared.deprovision.ex`
- `test/flared/tunnel_supervisor_test.exs`
- `test/flared/tunnel_test.exs`

---

## Module: `Mix.Tasks.Flared.Tunnel.Open`

### Purpose

Open a Cloudflare Tunnel by starting a `Flared.Tunnel` GenServer under
`Flared.TunnelSupervisor`, then block the BEAM until interrupted so the
supervised cloudflared OS process keeps running.

### Public interface

- `run(argv :: [String.t()]) :: :ok` — Mix task entrypoint. Parses
  argv, starts the tunnel via `Flared.TunnelSupervisor.start_child/3`,
  prints status, then blocks (production) or returns `:ok` (test override).

### Invariants

- Always calls `Mix.Task.run("app.start")` before any tunnel work, so the
  `Flared.TunnelSupervisor` is up.
- At least one `--route` flag is required; if none, halt with `1` and a
  human-readable error.
- Unknown options halt with `1` matching `flared.provision` behaviour.
- Provisioner errors are routed through `format_error/1` and produce
  halt `1`.
- The blocking step is configurable via a `:sleep_fn` opt so tests can
  replace `Process.sleep(:infinity)` with a no-op.

### Function specs

- `run/1`
  - Inputs: `argv :: [String.t()]` — raw OptionParser argv.
  - Output: `:ok` (when not blocking) or never-returns (when blocking).
  - Contract: parse argv, start child under `Flared.TunnelSupervisor`,
    print status, then call the configured sleep function. On any
    error, write the formatted message to `Mix.shell().error/1` and
    `System.halt(1)`.
  - Preconditions: the application can be started; at least one `--route`.
  - Postconditions: a child `Flared.Tunnel` is registered under the
    requested name (default `Flared.Tunnel`); `:ok` is returned only
    when the configured sleep function is overridden to return.

- `run/2` (private OR public-with-`@doc false`, testing seam)
  - Inputs: `argv`, `opts :: keyword()` where `opts[:sleep_fn]` is a
    `(-> any())`. Default: `fn -> Process.sleep(:infinity) end`.
  - Output: `:ok`.
  - Contract: same as `run/1` but uses the supplied sleep function.

- `parse_routes/1` (private)
  - Inputs: list of route strings.
  - Output: `{:ok, [route()]}` or `{:error, reason}`.
  - Contract: identical to the helper in `flared.provision.ex`. Empty
    list returns `{:error, :missing_routes}`. Each entry parsed via
    `Flared.Provisioner.parse_route/1`.

- `build_start_opts/1` (private)
  - Inputs: parsed keyword from OptionParser.
  - Output: keyword list ready for `TunnelSupervisor.start_child/3`'s
    `opts` argument.
  - Contract: forwards `account_id`, `tunnel_name`, `concurrency`,
    `dry_run?` (under that key, matching what Provisioner reads),
    `auto_start`, `max_attempts`, `base_backoff_ms`, `max_backoff_ms`,
    `stabilization_ms`. Drops `nil` and empty values.

- `print_started/2` (private)
  - Inputs: registered name (atom), parsed keyword.
  - Output: `:ok`.
  - Contract: emit a one-line confirmation that the tunnel is running,
    plus the current status atom from `Flared.Tunnel.status/1`.

- `format_error/1` (private)
  - Inputs: any provisioner / supervisor error term.
  - Output: human-readable string.
  - Contract: covers `:missing_routes`, `:already_started`, `:not_found`
    plus everything `flared.provision` covers; falls back to
    `inspect/1` for unknown terms.

---

## Module: `Mix.Tasks.Flared.Tunnel.Close`

### Purpose

Stop a tunnel by calling `Flared.TunnelSupervisor.stop_child/1` with a
registered name.

### Public interface

- `run(argv :: [String.t()]) :: :ok` — Mix task entrypoint.

### Invariants

- Always calls `Mix.Task.run("app.start")` first.
- `--name` defaults to `Flared.Tunnel`.
- `{:error, :not_found}` produces a clear "no tunnel registered as <name>"
  message and halt `1`.

### Function specs

- `run/1`
  - Inputs: `argv :: [String.t()]`.
  - Output: `:ok` on success, never returns on error (halt 1).
  - Contract: parse `--name`, convert to atom, call
    `Flared.TunnelSupervisor.stop_child(name)`. Print `ok` on success;
    error message and halt 1 on `{:error, _}`.

- `format_error/2` (private)
  - Inputs: error term, name atom.
  - Output: human-readable string.
  - Contract: `:not_found` → `"no tunnel registered as <name>"`; other
    terms → `inspect/1`.

---

## Module: `Mix.Tasks.Flared.Tunnel.Status`

### Purpose

Print the lifecycle status (`:idle | :running | :backing_off | :exhausted`)
for a tunnel registered under the given name.

### Public interface

- `run(argv :: [String.t()]) :: :ok` — Mix task entrypoint.

### Invariants

- Always calls `Mix.Task.run("app.start")` first.
- `--name` defaults to `Flared.Tunnel`.
- If `Process.whereis(name)` is nil, print "no tunnel registered as <name>"
  and halt `1`.
- `--json` produces `{"name": "...", "status": "..."}` exactly.

### Function specs

- `run/1`
  - Inputs: `argv :: [String.t()]`.
  - Output: `:ok` on success, never returns on error (halt 1).
  - Contract: parse `--name` and `--json`. If no process registered,
    halt 1. Otherwise read `Flared.Tunnel.status(name)`, render either
    JSON or `name => status`.

- `print_status/3` (private)
  - Inputs: name atom, status atom, `json? :: boolean()`.
  - Output: `:ok`.
  - Contract: when `json?` true, emit JSON via `Jason.encode!/1` with
    string keys `"name"` and `"status"` (atom values converted to strings);
    otherwise emit `"<name>: <status>"`.
