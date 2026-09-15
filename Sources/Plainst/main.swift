import AppKit
import PlainstCore
import PlainstEditor

let app = NSApplication.shared
let documentController = PlainstDocumentController()
AppPreferences.registerDefaults()
AppPreferences.applyAppearance()
Typefaces.registerBundledFonts()
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
#if PLAINST_CHECKS
  AppChecks.run(controller: documentController)
#endif
withExtendedLifetime((delegate, documentController)) { app.run() }
