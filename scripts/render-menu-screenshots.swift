#!/usr/bin/env swift
import AppKit

struct Row {
    let title: String
    let state: String
    let submenu: Bool
    let separator: Bool

    init(_ title: String = "", state: String = "", submenu: Bool = false, separator: Bool = false) {
        self.title = title
        self.state = state
        self.submenu = submenu
        self.separator = separator
    }
}

let mainRows = [
    Row("⬇️  Update Claudes to v1.0.0"), Row(separator: true),
    Row("🟢  Default", state: "✓", submenu: true),
    Row("⚪️  Expo", submenu: true),
    Row("🟢  Work", submenu: true),
    Row("⚪️  Client   ⬆️ update pending", submenu: true),
    Row("⏳  Personal   (repatching…)", submenu: true), Row(separator: true),
    Row("Manage Claudes", submenu: true), Row("Open Sessions In", submenu: true),
    Row(separator: true), Row("Report a Bug…"), Row("Claudes v0.9.1"), Row("Quit Claudes", state: "⌘Q")
]

let profileRows = [
    Row("Set as Active (Global)"), Row(separator: true),
    Row("Open Desktop App"), Row("Open Claude Code (Terminal)"),
    Row("Sessions", submenu: true), Row("Manage Profile", submenu: true)
]

let sessionRows = [
    Row("Open Claude Code In", submenu: true), Row("Transfer Session…"),
    Row(separator: true), Row("Copy Command:  claude-work")
]

let profileManageRows = [
    Row("Reveal Data Dir"), Row(separator: true), Row("Delete Profile…")
]

let claudesManageRows = [
    Row("New Profile…"), Row(separator: true),
    Row("Re-patch All (after Claude update)"),
    Row("Auto-repatch after Claude updates", state: "✓")
]

let rowHeight: CGFloat = 48
let separatorHeight: CGFloat = 18
let padding: CGFloat = 10

func panelHeight(_ rows: [Row]) -> CGFloat {
    rows.reduce(padding * 2) { $0 + ($1.separator ? separatorHeight : rowHeight) }
}

func drawPanel(_ rows: [Row], at origin: NSPoint, width: CGFloat, selected: Int? = nil) {
    let height = panelHeight(rows)
    let rect = NSRect(x: origin.x, y: origin.y - height, width: width, height: height)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(calibratedWhite: 0.96, alpha: 0.97).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
    NSGraphicsContext.current?.saveGraphicsState()
    NSShadow().set()

    var y = origin.y - padding
    var visibleIndex = 0
    for row in rows {
        if row.separator {
            y -= separatorHeight / 2
            NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX + 22, y: y))
            line.line(to: NSPoint(x: rect.maxX - 22, y: y))
            line.lineWidth = 1
            line.stroke()
            y -= separatorHeight / 2
            continue
        }
        y -= rowHeight
        if selected == visibleIndex {
            NSColor(calibratedRed: 0.18, green: 0.48, blue: 0.92, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX + 8, y: y + 2, width: rect.width - 16, height: rowHeight - 4), xRadius: 9, yRadius: 9).fill()
        }
        let selectedColor = selected == visibleIndex ? NSColor.white : NSColor(calibratedWhite: 0.1, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: selectedColor]
        if !row.state.isEmpty {
            (row.state as NSString).draw(at: NSPoint(x: rect.minX + 20, y: y + 10), withAttributes: attrs)
        }
        (row.title as NSString).draw(at: NSPoint(x: rect.minX + 66, y: y + 10), withAttributes: attrs)
        if row.submenu {
            ("›" as NSString).draw(at: NSPoint(x: rect.maxX - 36, y: y + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: selectedColor])
        }
        visibleIndex += 1
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

func render(_ name: String, width: CGFloat, draw: () -> Void) {
    let size = NSSize(width: width, height: 700)
    let image = NSImage(size: size)
    image.lockFocus()
    let colors = [NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.25, alpha: 1), NSColor(calibratedRed: 0.31, green: 0.37, blue: 0.55, alpha: 1)]
    NSGradient(colors: colors)!.draw(in: NSRect(origin: .zero, size: size), angle: 90)
    NSColor(calibratedWhite: 0.04, alpha: 0.95).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 648, width: width, height: 52)).fill()
    ("Claudes menu proposal" as NSString).draw(at: NSPoint(x: 28, y: 662), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.white])
    draw()
    image.unlockFocus()
    guard let data = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: data),
          let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not render \(name)") }
    try! png.write(to: URL(fileURLWithPath: "docs/\(name)"))
}

render("menu-v5-profile.png", width: 1260) {
    drawPanel(mainRows, at: NSPoint(x: 30, y: 635), width: 590, selected: 3)
    drawPanel(profileRows, at: NSPoint(x: 630, y: 500), width: 590)
}

render("menu-v5-sessions.png", width: 1810) {
    drawPanel(mainRows, at: NSPoint(x: 25, y: 635), width: 570, selected: 3)
    drawPanel(profileRows, at: NSPoint(x: 605, y: 500), width: 570, selected: 3)
    drawPanel(sessionRows, at: NSPoint(x: 1185, y: 390), width: 600)
}

render("menu-v5-manage.png", width: 1810) {
    drawPanel(mainRows, at: NSPoint(x: 25, y: 635), width: 570, selected: 3)
    drawPanel(profileRows, at: NSPoint(x: 605, y: 500), width: 570, selected: 4)
    drawPanel(profileManageRows, at: NSPoint(x: 1185, y: 340), width: 600)
    drawPanel(claudesManageRows, at: NSPoint(x: 1185, y: 635), width: 600)
}
