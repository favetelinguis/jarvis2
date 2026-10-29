const {test} = require("node:test")
const assert = require("node:assert/strict")
const {readFileSync} = require("node:fs")
const {join} = require("node:path")
const vm = require("node:vm")

function preview(fetch) {
  let hooks
  const context = {
    AbortController,
    fetch,
    document: {querySelector: () => ({getAttribute: () => "csrf"})},
    window: {
      addEventListener: (_, callback) => callback(),
      Phoenix: {Socket: {}},
      LiveView: {LiveSocket: class {
        constructor(_, __, options) { hooks = options.hooks }
        connect() {}
      }}
    }
  }
  vm.runInNewContext(readFileSync(join(__dirname, "../../priv/static/assets/app.js"), "utf8"), context)
  const frame = {removeAttribute() { delete this.src }}
  const error = {hidden: true}
  const el = {dataset: {url: "/deck?v=1"}, querySelector: selector => selector === "iframe" ? frame : error}
  return {hook: Object.assign({el}, hooks.SlidesPreview), frame, error}
}

function response(html) {
  return {ok: true, headers: {get: () => "text/html; charset=utf-8"}, text: async () => html}
}

test("fetches using the signed-in parent and preserves the frame until the deck changes", async () => {
  const requests = []
  const {hook, frame, error} = preview(async (url, options) => {
    requests.push({url, options})
    return response("<!doctype html><html><head></head><body>é</body></html>")
  })
  await hook.loadDeck()
  assert.equal(requests[0].options.credentials, "same-origin")
  assert.equal(requests[0].options.redirect, "error")
  assert.match(frame.src, /^data:text\/html;charset=utf-8,/)
  assert.match(decodeURIComponent(frame.src), /<body>é<\/body>/)
  assert.equal(error.hidden, true)
  const original = frame.src
  await hook.loadDeck()
  assert.equal(requests.length, 1)
  assert.equal(frame.src, original)
  hook.el.dataset.url = "/deck?v=2"
  await hook.loadDeck()
  assert.equal(requests.length, 2)
  assert.equal(requests[1].url, "/deck?v=2")
})

test("fails visibly rather than displaying a redirected login page", async () => {
  const {hook, frame, error} = preview(async () => { throw new Error("redirect") })
  await hook.loadDeck()
  assert.equal(frame.src, undefined)
  assert.equal(error.hidden, false)
})

test("ignores an obsolete response after a newer deck is requested", async () => {
  let finishFirst
  const {hook, frame} = preview((url) => url.endsWith("1")
    ? new Promise(resolve => { finishFirst = resolve })
    : Promise.resolve(response("new")))
  const first = hook.loadDeck()
  hook.el.dataset.url = "/deck?v=2"
  await hook.loadDeck()
  finishFirst(response("old"))
  await first
  assert.match(frame.src, /new$/)
})
