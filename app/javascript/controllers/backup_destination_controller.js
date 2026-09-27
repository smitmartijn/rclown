import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["storage", "path", "hint"]

  connect() {
    this.toggle()
  }

  toggle() {
    const local = this.storageTarget.selectedOptions[0]?.dataset.local === "true"
    this.pathTarget.required = local
    this.pathTarget.placeholder = local ? "cloudflare/my-bucket" : "path/within/bucket"
    this.hintTarget.textContent = local
      ? "Required relative path beneath the provider base directory. Subdirectories will be created automatically."
      : "Optional path within the bucket"
  }
}
