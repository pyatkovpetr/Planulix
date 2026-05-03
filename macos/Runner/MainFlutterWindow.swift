import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Default to IDE-sized window so DesktopShell (width >= 900) kicks in,
    // and keep a minimum that won't collapse the 4-panel layout.
    let defaultSize = NSSize(width: 1400, height: 900)
    if let screen = self.screen ?? NSScreen.main {
      let sf = screen.visibleFrame
      let origin = NSPoint(
        x: sf.origin.x + (sf.width - defaultSize.width) / 2,
        y: sf.origin.y + (sf.height - defaultSize.height) / 2
      )
      self.setFrame(NSRect(origin: origin, size: defaultSize), display: true)
    } else {
      self.setContentSize(defaultSize)
    }
    // Min width 400 so user can shrink below 900 to get the mobile shell;
    // default 1400 opens in desktop layout.
    self.minSize = NSSize(width: 400, height: 600)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
