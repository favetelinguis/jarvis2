// LiveView client. The Phoenix and LiveView bundles are served from their packages under /vendor,
// so the UI needs no JavaScript build step.
window.addEventListener("DOMContentLoaded", () => {
  const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content")
  const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    params: {_csrf_token: csrf}
  })
  liveSocket.connect()
  window.liveSocket = liveSocket
})
