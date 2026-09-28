// Loaded synchronously in the head so the saved theme is applied before paint.
(() => {
  const storageKey = "rclown.theme"
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)")
  const validPreference = (value) => ["auto", "light", "dark"].includes(value) ? value : "auto"
  const readPreference = () => {
    try {
      return validPreference(localStorage.getItem(storageKey))
    } catch {
      return "auto"
    }
  }
  let preference = readPreference()

  const applyTheme = () => {
    document.documentElement.dataset.theme = preference === "auto"
      ? (systemTheme.matches ? "dark" : "light")
      : preference
    document.documentElement.dataset.themePreference = preference
    document.querySelectorAll("button[data-theme-preference]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.themePreference === preference))
    })
  }

  document.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-theme-preference]")
    if (!button) return

    preference = validPreference(button.dataset.themePreference)
    try {
      localStorage.setItem(storageKey, preference)
    } catch {
      // The switcher still works for this visit if browser storage is unavailable.
    }
    applyTheme()
  })

  systemTheme.addEventListener("change", applyTheme)
  window.addEventListener("storage", (event) => {
    if (event.key === storageKey || event.key === null) {
      preference = readPreference()
      applyTheme()
    }
  })
  document.addEventListener("DOMContentLoaded", applyTheme)
  document.addEventListener("turbo:render", applyTheme)
  document.addEventListener("turbo:load", applyTheme)
  applyTheme()
})()
