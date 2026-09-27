import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cloud", "local"]

  connect() {
    this.toggle()
  }

  toggle() {
    const local = this.element.querySelector('input[name="provider[provider_type]"]:checked')?.value === "local"
    this.cloudTargets.forEach(element => this.show(element, !local))
    this.localTargets.forEach(element => this.show(element, local))
  }

  show(element, visible) {
    element.hidden = !visible
    element.querySelectorAll("input").forEach(input => input.disabled = !visible)
  }
}
