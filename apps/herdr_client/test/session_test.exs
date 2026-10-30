defmodule Jarvis2.Herdr.SessionTest do
  use ExUnit.Case, async: false

  alias Jarvis2.Herdr.Session

  setup do
    dir = Path.join(System.tmp_dir!(), "jarvis2-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    executable = Path.join(dir, "herdr")
    log = Path.join(dir, "calls")
    state = Path.join(dir, "state")
    socket = Path.join(dir, "herdr.sock")

    File.write!(executable, """
    #!/bin/sh
    printf '%s|%s|%s|%s|%s\\n' "$*" "${HERDR_SOCKET_PATH-unset}" "${HERDR_PANE_ID-unset}" "${HERDR_WORKSPACE_ID-unset}" "${HERDR_TAB_ID-unset}" >> '#{log}'
    if [ "$1 $2 $3" = 'session list --json' ]; then
      if [ -f '#{state}' ]; then
        printf '{"sessions":[{"name":"jarvis2","running":%s,"socket_path":"#{socket}"}]}' "$(cat '#{state}')"
      else
        printf '{"sessions":[]}'
      fi
    elif [ "$1 $2 $3" = '--session jarvis2 server' ]; then
      [ ! -f '#{dir}/never' ] && printf true > '#{state}'
    elif [ "$1 $2 $3 $4" = '--session jarvis2 api snapshot' ]; then
      [ ! -f '#{dir}/not-ready' ]
    else
      exit 1
    fi
    """)

    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, executable: executable, state: state, socket: socket, log: log}
  end

  test "reuses a running session without starting a server", ctx do
    File.write!(ctx.state, "true")
    assert {:ok, ctx.socket} == Session.ensure("jarvis2", herdr: ctx.executable)
    refute File.read!(ctx.log) =~ "server"
  end

  test "starts an absent session, waits for it and checks the API", ctx do
    assert {:ok, ctx.socket} ==
             Session.ensure("jarvis2", herdr: ctx.executable, timeout: 1_000, poll_interval: 10)

    log = File.read!(ctx.log)
    assert log =~ "--session jarvis2 server"
    assert log =~ "--session jarvis2 api snapshot"
    assert length(String.split(log, "session list --json")) >= 3
  end

  test "starts a session without Linux-specific setsid", ctx do
    for name <- ~w(sh nohup cat) do
      File.ln_s!(System.find_executable(name), Path.join(ctx.dir, name))
    end

    previous = System.get_env("PATH")
    System.put_env("PATH", ctx.dir)
    on_exit(fn -> System.put_env("PATH", previous) end)

    assert {:ok, ctx.socket} ==
             Session.ensure("jarvis2", herdr: ctx.executable, timeout: 1_000, poll_interval: 10)
  end

  test "starts a stopped session", ctx do
    File.write!(ctx.state, "false")

    assert {:ok, ctx.socket} ==
             Session.ensure("jarvis2", herdr: ctx.executable, timeout: 1_000, poll_interval: 10)

    assert File.read!(ctx.log) =~ "--session jarvis2 server"
  end

  test "times out if the server never appears or its API is not ready", ctx do
    File.touch!(Path.join(ctx.dir, "never"))

    assert {:error, _} =
             Session.ensure("jarvis2", herdr: ctx.executable, timeout: 80, poll_interval: 10)

    File.rm!(Path.join(ctx.dir, "never"))
    File.touch!(Path.join(ctx.dir, "not-ready"))

    assert {:error, _} =
             Session.ensure("jarvis2", herdr: ctx.executable, timeout: 80, poll_interval: 10)
  end

  test "rejects missing executables and invalid session names", ctx do
    assert {:error, _} = Session.ensure("jarvis2", herdr: Path.join(ctx.dir, "missing"))
    assert {:error, _} = Session.ensure("bad; touch x", herdr: ctx.executable)
    refute File.exists?(ctx.log)
  end

  test "returns an error when herdr is not on PATH", ctx do
    previous = System.get_env("PATH")
    System.put_env("PATH", ctx.dir)

    on_exit(fn ->
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end)

    File.rm!(ctx.executable)
    assert {:error, "herdr executable not found"} = Session.ensure("jarvis2")
  end

  test "does not start a server when the session list is invalid", ctx do
    File.write!(ctx.executable, "#!/bin/sh\nprintf 'not json'\n")

    assert {:error, "invalid Herdr session list response"} =
             Session.ensure("jarvis2", herdr: ctx.executable)

    refute File.exists?(ctx.state)
  end

  test "clears inherited Herdr context from every subprocess", ctx do
    variables = ~w(HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID)
    previous = Enum.map(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &System.put_env(&1, "inherited"))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    assert {:ok, ctx.socket} ==
             Session.ensure("jarvis2", herdr: ctx.executable, timeout: 1_000, poll_interval: 10)

    for line <- ctx.log |> File.read!() |> String.split("\n", trim: true) do
      assert String.ends_with?(line, "|unset|unset|unset|unset")
    end
  end
end
