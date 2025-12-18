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
      try {
        const response = await fetch(this.urlValue, {
          headers: { "Accept": "text/html" }
        })
        if (!response.ok) {
          this.showError(frame)
          return
        }
        const html = await response.text()
        const doc = new DOMParser().parseFromString(html, "text/html")
        const newFrame = doc.querySelector("turbo-frame")
        if (newFrame) {
          frame.innerHTML = newFrame.innerHTML
        }
      } catch (error) {
        this.showError(frame)
      }
    }
  }

  showError(frame) {
    frame.innerHTML = `
      <div class="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
        <p class="text-red-600 font-medium">Orchestrator unavailable</p>
        <p class="text-red-500 text-sm mt-1">Retrying automatically...</p>
      </div>
    `
  }
}
