import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: CGRect(x: 100, y: 200, width: 420, height: 280),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = "UTSUSHIE AX fixture"
let button = NSButton(title: "Capture fixture", target: nil, action: nil)
button.frame = CGRect(x: 40, y: 100, width: 180, height: 40)
window.contentView?.addSubview(button)
let secondButton = NSButton(title: "Next", target: nil, action: nil)
secondButton.frame = CGRect(x: 250, y: 100, width: 120, height: 40)
window.contentView?.addSubview(secondButton)
window.orderFrontRegardless()
app.run()
