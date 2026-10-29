defmodule Jarvis2Web.HostCheck do
  @moduledoc """
  Rejects requests whose `Host` header is not a loopback name. A DNS-rebinding page would reach the
  loopback listener with its own hostname, so this keeps it away from the UI and the MCP endpoint.
  """
  @behaviour Plug
  import Plug.Conn

  @allowed ~w(127.0.0.1 localhost ::1 [::1])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.host in Application.get_env(:jarvis2, :allowed_hosts, @allowed) do
      conn
    else
      conn |> send_resp(403, "forbidden host") |> halt()
    end
  end
end
