require "application_system_test_case"

class ThemesTest < ApplicationSystemTestCase
  setup do
    visit backups_path
    page.execute_script("localStorage.removeItem('rclown.theme')")
    emulate_theme("light")
    page.refresh
  end

  teardown do
    emulate_theme("light")
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "manual themes persist across reloads and Turbo navigation" do
    assert_theme "light", preference: "auto"
    light_background = page.evaluate_script("getComputedStyle(document.body).backgroundColor")
    click_button "Dark theme"
    assert_theme "dark", preference: "dark"
    assert_equal "dark", page.evaluate_script("getComputedStyle(document.documentElement).colorScheme")
    assert_not_equal light_background, page.evaluate_script("getComputedStyle(document.body).backgroundColor")

    page.refresh
    assert_theme "dark", preference: "dark"
    page.execute_script("window.themeNavigationMarker = true")
    within("aside") { click_link "Providers" }
    assert_selector "h1", text: "Providers"
    assert page.evaluate_script("window.themeNavigationMarker"), "Expected a Turbo visit"
    assert_theme "dark", preference: "dark"
    page.go_back
    assert_selector "h1", text: "Backups"
    assert_theme "dark", preference: "dark"

    click_button "Light theme"
    assert_theme "light", preference: "light"
    assert_equal light_background, page.evaluate_script("getComputedStyle(document.body).backgroundColor")
  end

  test "auto responds to system changes while manual preferences take precedence" do
    emulate_theme("dark")
    assert_theme "dark", preference: "auto"
    click_button "Light theme"
    emulate_theme("light")
    emulate_theme("dark")
    assert_theme "light", preference: "light"
    click_button "Auto"
    assert_theme "dark", preference: "auto"
    emulate_theme("light")
    assert_theme "light", preference: "auto"
  end

  test "theme changes synchronize between tabs" do
    original_window = current_window
    second_window = open_new_window
    within_window(second_window) do
      visit backups_path
      click_button "Dark theme"
    end
    within_window(original_window) { assert_theme "dark", preference: "dark" }
  ensure
    second_window&.close
  end

  test "mobile switcher is accessible by keyboard and stays selected after navigation" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    assert_equal 390, page.evaluate_script("window.innerWidth")
    dark_button = find_button("Dark theme")
    dark_button.send_keys(:space)
    assert_theme "dark", preference: "dark"
    click_link "Accounts"
    assert_selector "h1", text: "Account backups"
    assert_theme "dark", preference: "dark"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "Mobile page should not overflow"
  end

  test "theme switching still works when browser storage is unavailable" do
    script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
      Storage.prototype.getItem = () => { throw new DOMException('Storage blocked', 'SecurityError') }
      Storage.prototype.setItem = () => { throw new DOMException('Storage blocked', 'SecurityError') }
    JS
    page.refresh
    assert_theme "light", preference: "auto"
    click_button "Dark theme"
    assert_theme "dark", preference: "dark"
    within("aside") { click_link "Providers" }
    assert_selector "h1", text: "Providers"
    assert_theme "dark", preference: "dark"
  ensure
    page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: script["identifier"]) if script
  end

  private

  def emulate_theme(value)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: value } ])
  end

  def assert_theme(theme, preference:)
    assert_selector "html[data-theme='#{theme}'][data-theme-preference='#{preference}']"
    assert_selector "button[data-theme-preference='#{preference}'][aria-pressed='true']", count: 1
  end
end
