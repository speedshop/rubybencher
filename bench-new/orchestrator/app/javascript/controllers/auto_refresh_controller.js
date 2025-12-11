import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    interval: { type: Number, default: 5000 },
    url: String
  }

  connect() {
    this.startRefreshing()
  }

  disconnect() {
    this.stopRefreshing()
  }

  startRefreshing() {
    this.refreshTimer = setInterval(() => {
      this.refresh()
    }, this.intervalValue)
  }

  stopRefreshing() {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
    }
  }

  async refresh() {
    const frame = this.element.querySelector("turbo-frame")
    if (frame && this.urlValue) {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "text/html" }
      })
      const html = await response.text()
      const doc = new DOMParser().parseFromString(html, "text/html")
      const newFrame = doc.querySelector("turbo-frame")
      if (newFrame) {
        frame.innerHTML = newFrame.innerHTML
      }
    }
  }
}
