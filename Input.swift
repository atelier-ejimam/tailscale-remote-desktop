import Foundation
import ApplicationServices
import AppKit

struct Command: Decodable {
    let t: String
    let x, y: Double?
    let b, dy, dx, code: Int?
    let s: String?
    let mods: [String]?
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Input: Terminal のアクセシビリティ許可が必要です\n".utf8))
    exit(3)
}
var point = CGEvent(source: nil)?.location ?? .zero
struct Click {
    let button: Int
    let point: CGPoint
    let time: TimeInterval
    let count: Int64
    var dragged = false

    func isNear(_ other: CGPoint) -> Bool {
        abs(point.x - other.x) <= 4 && abs(point.y - other.y) <= 4
    }
}
var held: [Int: Click] = [:]
var lastClick: Click?
var displaySize = CGSize.zero
func mainDisplay() -> CGRect {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    if bounds.size != displaySize && bounds.width > 0 && bounds.height > 0 {
        displaySize = bounds.size
        print("\(bounds.width) \(bounds.height)")
        fflush(stdout)
    }
    return bounds
}
_ = mainDisplay()
func mouse(_ type: CGEventType, _ b: Int) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                              mouseButton: b == 1 ? .right : .left) else { return }
    if let click = held[b] { event.setIntegerValueField(.mouseEventClickState, value: click.count) }
    event.post(tap: .cghidEventTap)
}
func release(_ b: Int) {
    guard let click = held[b] else { return }
    mouse(b == 1 ? .rightMouseUp : .leftMouseUp, b)
    held.removeValue(forKey: b)
    lastClick = click.dragged ? nil : click
}
func press(_ b: Int) {
    guard held[b] == nil else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let systemInterval = NSEvent.doubleClickInterval
    let interval = systemInterval > 0 ? systemInterval : 0.5
    var count: Int64 = 1
    if held.isEmpty, let previous = lastClick, previous.button == b,
       now - previous.time <= interval, previous.isNear(point) {
        count = previous.count + 1
    }
    lastClick = nil
    held[b] = Click(button: b, point: point, time: now, count: count)
    mouse(b == 1 ? .rightMouseDown : .leftMouseDown, b)
}
let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "opt": .maskAlternate, "ctrl": .maskControl, "shift": .maskShift
]
func key(_ code: CGKeyCode, flags: CGEventFlags = [], units: [UInt16] = []) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        event.flags = flags
        if !units.isEmpty {
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
        }
        event.post(tap: .cghidEventTap)
    }
}
func insertText(_ text: String) {
    var units: [UInt16] = []
    func flush() {
        if !units.isEmpty { key(0, units: units); units.removeAll(keepingCapacity: true) }
    }
    for scalar in text.unicodeScalars {
        if scalar.value == 10 || scalar.value == 9 {
            flush()
            key(scalar.value == 10 ? 36 : 48)
        } else {
            let next = String(scalar).utf16
            if units.count + next.count > 16 { flush() }
            units.append(contentsOf: next)
        }
    }
    flush()
}
while let line = readLine() {
    guard let c = try? JSONDecoder().decode(Command.self, from: Data(line.utf8)) else { continue }
    switch c.t {
    case "move":
        guard let x = c.x, let y = c.y, (0...1).contains(x), (0...1).contains(y) else { continue }
        let r = mainDisplay()
        guard r.width > 0, r.height > 0 else { continue }
        point = CGPoint(x: min(r.minX + x * r.width, r.maxX - 1),
                        y: min(r.minY + y * r.height, r.maxY - 1))
        for b in held.keys where held[b]?.isNear(point) == false { held[b]?.dragged = true }
        if held[0] != nil { mouse(.leftMouseDragged, 0) }
        else if held[1] != nil { mouse(.rightMouseDragged, 1) }
        else { mouse(.mouseMoved, 0) }
    case "down", "up":
        guard let b = c.b, (0...1).contains(b) else { continue }
        if c.t == "up" { release(b) }
        else { press(b) }
    case "wheel":
        let dx = c.dx ?? 0
        if let dy = c.dy, (-120...120).contains(dy), (-120...120).contains(dx) {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                    wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.post(tap: .cghidEventTap)
        }
    case "text":
        if let text = c.s { insertText(text) }
    case "key":
        if let code = c.code, (0...127).contains(code) {
            let flags = (c.mods ?? []).compactMap { modifierFlags[$0] }
            key(CGKeyCode(code), flags: flags.reduce([]) { $0.union($1) })
        }
    default: continue
    }
}
release(0)
release(1)
