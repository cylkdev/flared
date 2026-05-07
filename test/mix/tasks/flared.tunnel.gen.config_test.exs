defmodule Mix.Tasks.Flared.Tunnel.Gen.ConfigTest do
  use ExUnit.Case, async: false

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "flared_gen_config_task_#{System.unique_integer([:positive])}")
  end

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(original_shell)
    end)

    :ok
  end

  test "run/1 writes config and prints token run command" do
    Mix.Task.reenable("flared.gen.config")
    dest_dir = tmp_dir()

    {:ok, path} =
      Mix.Tasks.Flared.Tunnel.Gen.Config.run([
        "--tunnel-id",
        "tunnel-id",
        "--route",
        "chat.example.com=http://localhost:4000",
        "--dest",
        dest_dir
      ])

    assert File.exists?(path)
    assert File.read!(path) =~ "hostname: chat.example.com"
    assert File.read!(path) =~ "service: http_status:404"

    messages = receive_messages([])

    assert Enum.any?(messages, fn message ->
             String.contains?(
               message,
               "cloudflared tunnel --config #{path} run --token $CLOUDFLARED_TOKEN"
             )
           end)
  end

  defp receive_messages(messages) do
    receive do
      {:mix_shell, _level, [message]} ->
        receive_messages([message | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
