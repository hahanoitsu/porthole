import AppKit

// A phone dropping the connection mid-write must not kill the app.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
