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
window.orderFrontRegardless()
app.run()
