// LiveView client. The Phoenix and LiveView bundles are served from their packages under /vendor,
// so the UI needs no JavaScript build step.
window.addEventListener("DOMContentLoaded", () => {
  const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content")
  const hooks = {
    Board: {
      mounted() {
        this.el.addEventListener("dragstart", event => {
          const card = event.target.closest("[data-card-id]")
          if (!card) return
          event.dataTransfer.setData("text/plain", card.dataset.cardId)
          event.dataTransfer.effectAllowed = "move"
        })
        this.el.addEventListener("dragover", event => {
          const column = event.target.closest("[data-column]")
          if (!column) return
          event.preventDefault()
          column.classList.add("drop-target")
        })
        this.el.addEventListener("dragleave", event => {
          const column = event.target.closest("[data-column]")
          if (column && !column.contains(event.relatedTarget)) column.classList.remove("drop-target")
        })
        this.el.addEventListener("drop", event => {
          event.preventDefault()
          const column = event.target.closest("[data-column]")
          if (!column) return
          column.classList.remove("drop-target")
          const id = event.dataTransfer.getData("text/plain")
          const card = [...this.el.querySelectorAll("[data-card-id]")].find(el => el.dataset.cardId === id)
          if (!card) return
          if (["scratch", "archive"].includes(column.dataset.column) && card.dataset.stop === "true" &&
              !window.confirm("Stop the agent and cancel any open questions?")) return
          // The server owns the DOM position, so refused drops never move the card.
          this.pushEvent("move_card", {id, to: column.dataset.column}, () => {})
        })
      }
    },
    // Fetch in the authenticated parent: a sandboxed iframe has an opaque origin and may not send the session cookie.
    SlidesPreview: {
      mounted() { this.loadDeck() },
      updated() { this.loadDeck() },
      destroyed() { this.controller?.abort() },
      async loadDeck() {
        const url = this.el.dataset.url
        if (url === this.deckUrl) return
        this.deckUrl = url
        this.controller?.abort()
        const controller = this.controller = new AbortController()
        const frame = this.el.querySelector("iframe")
        const error = this.el.querySelector(".banner-warn")
        error.hidden = true
        frame.removeAttribute("src")
        try {
          const response = await fetch(url, {credentials: "same-origin", redirect: "error", signal: controller.signal})
          if (!response.ok || !response.headers.get("content-type")?.startsWith("text/html")) throw new Error("preview unavailable")
          const html = await response.text()
          if (controller.signal.aborted) return
          // Opaque sandboxed blob: documents cannot reliably navigate their own hash in Chromium.
          frame.src = `data:text/html;charset=utf-8,${encodeURIComponent(html)}`
        } catch (_) {
          if (controller.signal.aborted) return
          this.deckUrl = null
          error.hidden = false
        }
      }
    },
    Copy: {
      mounted() {
        this.el.querySelector("button").addEventListener("click", async () => {
          try {
            await navigator.clipboard.writeText(this.el.querySelector("pre").textContent)
            this.el.querySelector("button").textContent = "Copied"
          } catch (_) {
            this.el.querySelector("button").textContent = "Copy failed"
          }
        })
      }
    },
    AnswerKeys: {
      mounted() {
        this.el.addEventListener("keydown", event => {
          if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
            event.preventDefault()
            const button = this.el.querySelector("#submit-answers")
            if (button && !button.disabled) button.click()
          } else if (event.key.toLowerCase() === "y" && !event.ctrlKey && !event.metaKey &&
                     !/^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName)) {
            const question = event.target.closest("[data-question]")
            if (question) {
              event.preventDefault()
              question.querySelector("button[id^='accept-']")?.click()
            }
          }
        })
      }
    }
  }
  const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    params: {_csrf_token: csrf}, hooks
  })
  liveSocket.connect()
  window.liveSocket = liveSocket
})
