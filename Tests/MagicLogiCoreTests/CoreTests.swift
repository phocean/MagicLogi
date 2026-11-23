// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

import XCTest
@testable import MagicLogiCore

final class HIDPPTests: XCTestCase {
    func testEncode() {
        let m = HIDPPMessage(featureIndex: 0x0A, function: 3, params: [0, 0x06, 0x40])
        XCTAssertEqual(m.bytes.count, 20)
        XCTAssertEqual(Array(m.bytes.prefix(7)), [0x11, 0xFF, 0x0A, 0x3C, 0x00, 0x06, 0x40])
        XCTAssertTrue(m.bytes[7...].allSatisfy { $0 == 0 })
    }

    func testParamsTruncatedAndPadded() {
        let m = HIDPPMessage(featureIndex: 1, function: 0, params: [UInt8](repeating: 7, count: 30))
        XCTAssertEqual(m.params.count, 16)
        XCTAssertEqual(m.bytes.count, 20)
    }

    func testDecodeRejectsMalformed() {
        XCTAssertNil(HIDPPMessage(report: []))
        XCTAssertNil(HIDPPMessage(report: [0x11] + [UInt8](repeating: 0, count: 18)))   // 19 bytes
        XCTAssertNil(HIDPPMessage(report: [0x10] + [UInt8](repeating: 0, count: 19)))   // short report ID
        XCTAssertNil(HIDPPMessage(report: [0x11] + [UInt8](repeating: 0, count: 25)))
    }

    func testAnswersAndErrors() {
        let req = HIDPPMessage(featureIndex: 0x09, function: 2, params: [0x00, 0x53])
        var resp = req.bytes
        resp[4] = 0x00; resp[5] = 0x53
        let ok = HIDPPMessage(report: resp)!
        XCTAssertTrue(ok.answers(req))
        XCTAssertNil(ok.errorCode)

        // Notification (software ID 0) for the same feature/function: not an answer.
        var notif = resp
        notif[3] = 0x20
        XCTAssertFalse(HIDPPMessage(report: notif)!.answers(req))

        // Error: [11 FF FF featIdx fn|sw code ...]
        let err = HIDPPMessage(report: [0x11, 0xFF, 0xFF, 0x09, 0x2C, 0x02] + [UInt8](repeating: 0, count: 14))!
        XCTAssertTrue(err.isError)
        XCTAssertTrue(err.answers(req))
        XCTAssertEqual(err.errorCode, 0x02)
        XCTAssertEqual(HIDPPErrorCode.describe(0x02), "InvalidArgument")

        // An error for another request is not ours.
        let other = HIDPPMessage(report: [0x11, 0xFF, 0xFF, 0x0A, 0x2C, 0x02] + [UInt8](repeating: 0, count: 14))!
        XCTAssertFalse(other.answers(req))
    }

    func testU16Bounds() {
        XCTAssertEqual([0x12, 0x34].u16(0), 0x1234)
        XCTAssertNil([0x12].u16(0))
        XCTAssertNil([0x12, 0x34].u16(1))
        XCTAssertNil([0x12, 0x34].u16(-1))
    }
}

final class PayloadTests: XCTestCase {
    /// Raw getSensorDpiList answer read from the MX Anywhere 2S (2026-11-22).
    let realDPIList: [UInt8] = [0x00, 0xC8, 0xE0, 0x32, 0x0F, 0xA0, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0]

    func testDPIRangeFromDevice() {
        let list = DPIList.decode(realDPIList)
        XCTAssertEqual(list.count, 77)
        XCTAssertEqual(list.first, 200)
        XCTAssertEqual(list.last, 4000)
        XCTAssertTrue(list.contains(1000))
        XCTAssertFalse(list.contains(1025))
    }

    func testDPINearest() {
        let list = DPIList.decode(realDPIList)
        XCTAssertEqual(DPIList.nearest(1600, in: list), 1600)
        XCTAssertEqual(DPIList.nearest(1625, in: list), 1600)   // tie → lower
        XCTAssertEqual(DPIList.nearest(1630, in: list), 1650)
        XCTAssertEqual(DPIList.nearest(50, in: list), 200)
        XCTAssertEqual(DPIList.nearest(9000, in: list), 4000)
        XCTAssertNil(DPIList.nearest(1000, in: []))
    }

    func testDPIDiscreteAndMalformed() {
        XCTAssertEqual(DPIList.decode([0x01, 0x90, 0x03, 0x20, 0x00, 0x00]), [400, 800])
        XCTAssertEqual(DPIList.decode([0xE0, 0x32, 0x0F, 0xA0]), [4000])       // step without a start
        XCTAssertEqual(DPIList.decode([0x00, 0xC8, 0xE0, 0x00, 0x0F, 0xA0]), [200, 4000]) // zero step ignored
        XCTAssertEqual(DPIList.decode([0x00, 0xC8, 0xE0, 0x32]), [200])        // step without an end
        XCTAssertEqual(DPIList.decode([]), [])
        XCTAssertEqual(DPIList.decode([0x00]), [])
    }

    func testControlInfo() {
        // Middle button as reported by the device: flags mouse|reprog|divert, rawXY.
        let c = ControlInfo(params: [0x00, 0x52, 0x00, 0xA9, 0x31, 0x00, 0x02, 0x0B, 0x01, 0, 0, 0, 0, 0, 0, 0])!
        XCTAssertEqual(c.cid, 0x0052)
        XCTAssertEqual(c.tid, 0x00A9)
        XCTAssertTrue(c.isMouseButton && c.isReprogrammable && c.isDivertable && c.supportsRawXY)
        XCTAssertFalse(c.isPersistentlyDivertable || c.isVirtual)
        XCTAssertEqual(c.flagNames, ["mouse", "reprog", "divert", "rawXY"])
        XCTAssertNil(ControlInfo(params: [0, 0, 0, 0, 0, 0, 0, 0, 0]))   // CID 0
        XCTAssertNil(ControlInfo(params: [0, 0x52]))
    }

    func testControlReporting() {
        let r = ControlReporting(params: [0x00, 0x53, 0x01, 0x00, 0x00, 0x00])!
        XCTAssertTrue(r.diverted)
        XCTAssertFalse(r.persistentlyDiverted)
        XCTAssertEqual(r.remap, 0)
        XCTAssertEqual(ControlReporting.setDivertParams(cid: 0x0053, divert: true), [0x00, 0x53, 0x23, 0, 0])
        XCTAssertEqual(ControlReporting.setDivertParams(cid: 0x005D, divert: false), [0x00, 0x5D, 0x22, 0, 0])
        XCTAssertEqual(ControlReporting.setDivertParams(cid: 0x0052, divert: true, rawXY: true), [0x00, 0x52, 0x33, 0, 0])
        // rawXY is never left on without diversion.
        XCTAssertEqual(ControlReporting.setDivertParams(cid: 0x0052, divert: false, rawXY: true), [0x00, 0x52, 0x22, 0, 0])
        XCTAssertTrue(ControlReporting(params: [0x00, 0x52, 0x11, 0, 0])!.rawXY)
        XCTAssertNil(ControlReporting(params: [0, 0x53]))
    }

    func testDivertedButtons() {
        XCTAssertEqual(decodeDivertedButtons([0x00, 0x56, 0x00, 0x53] + [UInt8](repeating: 0, count: 12)), [0x56, 0x53])
        XCTAssertEqual(decodeDivertedButtons([UInt8](repeating: 0, count: 16)), [])
        XCTAssertEqual(decodeDivertedButtons([0x00]), [])
        // Only the first 4 slots count.
        XCTAssertEqual(decodeDivertedButtons([0, 1, 0, 2, 0, 3, 0, 4, 0, 5]), [1, 2, 3, 4])
    }

    func testRawXY() {
        XCTAssertEqual(decodeRawXY([0xFF, 0xF6, 0x00, 0x05])?.dx, -10)
        XCTAssertEqual(decodeRawXY([0xFF, 0xF6, 0x00, 0x05])?.dy, 5)
        XCTAssertNil(decodeRawXY([0x00, 0x01, 0x00]))
    }

    func testGestures() {
        var g = GestureTracker(threshold: 100)
        XCTAssertNil(g.add(dx: 500, dy: 0))         // not active
        g.begin()
        XCTAssertNil(g.add(dx: -60, dy: 10))
        XCTAssertEqual(g.add(dx: -50, dy: 0), .left)
        // Chaining in the same hold: counted from zero, 2.25× the threshold.
        XCTAssertNil(g.add(dx: -220, dy: 0))
        XCTAssertEqual(g.add(dx: -5, dy: 0), .left)
        XCTAssertNil(g.add(dx: 0, dy: 220))
        XCTAssertEqual(g.add(dx: 0, dy: 5), .down)
        XCTAssertFalse(g.end())                      // not a click
        g.begin()
        XCTAssertNil(g.add(dx: 30, dy: -20))
        XCTAssertTrue(g.end())                       // small motion: click
        XCTAssertFalse(g.end())                      // already ended
        g.begin()
        XCTAssertEqual(g.add(dx: 20, dy: 150), .down)
        g.begin()
        XCTAssertEqual(g.add(dx: 0, dy: -100), .up)
        g.begin()
        XCTAssertEqual(g.add(dx: 100, dy: 100), .right)  // tie → horizontal
        g.begin(); g.cancel()
        XCTAssertFalse(g.end())
        g.begin()
        for _ in 0..<10 { _ = g.add(dx: Int.max / 4, dy: 0) }  // no overflow
    }

    func testBattery() {
        let b = BatteryStatus(params: [50, 20, 0])!
        XCTAssertEqual(b.level, 50)
        XCTAssertEqual(b.statusName, "discharging")
        XCTAssertNil(BatteryStatus(params: [101, 0, 0]))
        XCTAssertNil(BatteryStatus(params: [50]))
    }

    func testWheelMode() {
        let m = WheelMode(diverted: false, highResolution: false, inverted: true)
        XCTAssertEqual(m.raw, 0x04)
        XCTAssertTrue(WheelMode(raw: 0x07).divertedToHIDPP)
        XCTAssertTrue(WheelMode(raw: 0x07).highResolution)
        XCTAssertFalse(WheelMode(raw: 0x00).inverted)
    }

    func testASCII() {
        XCTAssertEqual(asciiString([0x4D, 0x58, 0x00, 0x41]), "MX")
        XCTAssertEqual(asciiString([0x41, 0x07, 0xFF]), "A??")
    }
}

final class TOMLTests: XCTestCase {
    func testParse() throws {
        let doc = try TOMLDocument.parse("""
        # comment
        top = 1
        [pointer]
        dpi = 1_600   # trailing comment
        [buttons]
        back = "keys:cmd+[" # the bracket and # inside quotes stay
        tag = "a#b"
        flag = false
        neg = -3
        """)
        XCTAssertEqual(doc.tables[""]?["top"]?.value, .integer(1))
        XCTAssertEqual(doc.tables["pointer"]?["dpi"]?.value, .integer(1600))
        XCTAssertEqual(doc.tables["buttons"]?["back"]?.value, .string("keys:cmd+["))
        XCTAssertEqual(doc.tables["buttons"]?["tag"]?.value, .string("a#b"))
        XCTAssertEqual(doc.tables["buttons"]?["flag"]?.value, .boolean(false))
        XCTAssertEqual(doc.tables["buttons"]?["neg"]?.value, .integer(-3))
        XCTAssertEqual(doc.tables["pointer"]?["dpi"]?.line, 4)
    }

    func testEscapes() throws {
        let doc = try TOMLDocument.parse(#"k = "a\"b\\c""#)
        XCTAssertEqual(doc.tables[""]?["k"]?.value, .string("a\"b\\c"))
    }

    func testErrors() {
        let bad: [(String, Int)] = [
            ("k = 1\nk = 2", 2),
            ("[a]\n[a]", 2),
            ("k = \"open", 1),
            ("k = 1.5", 1),
            ("k = [1, 2]", 1),
            ("k = 'x'", 1),
            ("k =", 1),
            ("just text", 1),
            ("[a.b]", 1),
            ("[[arr]]", 1),
            ("a.b = 1", 1),
            ("k = 1__0", 1),
            ("k = \"x\" y", 1),
            ("k = \"\\q\"", 1),
            ("k = 99999999999999", 1),
        ]
        for (text, line) in bad {
            XCTAssertThrowsError(try TOMLDocument.parse(text), text) { e in
                XCTAssertEqual((e as? TOMLError)?.line, line, text)
            }
        }
    }
}

final class ConfigTests: XCTestCase {
    func testFull() throws {
        let cfg = try Config.parse("""
        [pointer]
        dpi = 1600
        [scroll]
        invert = true
        [buttons]
        middle = "mission-control"
        back = "back"
        forward = "keys:cmd+shift+4"
        tilt_left = "native"
        tilt_right = "none"
        """)
        XCTAssertEqual(cfg.dpi, 1600)
        XCTAssertEqual(cfg.invertScroll, true)
        XCTAssertEqual(cfg.action(for: .middle), .system(.missionControl))
        XCTAssertEqual(cfg.action(for: .back), .mouseButton(3))
        XCTAssertEqual(cfg.action(for: .forward), .keys(KeyCombo(keyCode: 0x15, modifiers: [.command, .shift], character: "4")))
        XCTAssertEqual(cfg.action(for: .tiltLeft), .native)
        XCTAssertEqual(cfg.action(for: .tiltRight), ButtonAction.none)
        XCTAssertTrue(cfg.needsEventPosting)
        XCTAssertEqual(cfg.summary, "dpi=1600 invert=on remapped=middle,back,forward,tilt_right")
    }

    func testEmptyMeansUnchanged() throws {
        let cfg = try Config.parse("")
        XCTAssertNil(cfg.dpi)
        XCTAssertNil(cfg.invertScroll)
        XCTAssertFalse(cfg.needsEventPosting)
        XCTAssertTrue(Control.allCases.allSatisfy { cfg.action(for: $0) == .native })
        XCTAssertEqual(cfg.summary, "dpi=unchanged invert=unchanged remapped=none")
    }

    func testNoneNeedsNoAccessibility() throws {
        let cfg = try Config.parse("[buttons]\nmiddle = \"none\"")
        XCTAssertTrue(cfg.action(for: .middle).needsDiversion)
        XCTAssertFalse(cfg.needsEventPosting)
    }

    func testGestureConfig() throws {
        let cfg = try Config.parse("""
        [buttons]
        middle = "gestures"
        [gestures]
        click = "middle-click"
        left = "space-right"
        threshold = 300
        """)
        XCTAssertEqual(cfg.action(for: .middle), .gestures)
        XCTAssertEqual(cfg.gestures[.click], .mouseButton(2))
        XCTAssertEqual(cfg.gestures[.left], .system(.spaceRight))
        XCTAssertEqual(cfg.gestures[.right], .system(.spaceRight))   // default kept
        XCTAssertEqual(cfg.gestures[.up], .system(.missionControl))
        XCTAssertEqual(cfg.gestureThreshold, 300)
        XCTAssertEqual(try Config.parse("").gestures[.click], .mouseButton(2))   // default click = middle click
        XCTAssertTrue(cfg.needsEventPosting)
        for bad in ["[gestures]\nclick = \"native\"", "[gestures]\nup = \"gestures\"",
                    "[gestures]\nthreshold = 5", "[gestures]\nthreshold = \"x\"", "[gestures]\nspin = \"none\""] {
            XCTAssertThrowsError(try Config.parse(bad), bad)
        }
    }

    func testStrictErrors() {
        let bad = [
            "[pointr]\ndpi = 800",
            "[pointer]\ndpii = 800",
            "dpi = 800",
            "[pointer]\ndpi = 100",
            "[pointer]\ndpi = 4050",
            "[pointer]\ndpi = \"800\"",
            "[scroll]\ninvert = 1",
            "[buttons]\nback = \"teleport\"",
            "[buttons]\nback = 4",
            "[buttons]\nback = \"keys:cmd+\"",
            "[buttons]\nback = \"keys:hyper+a\"",
            "[buttons]\nleft = \"back\"",
        ]
        for text in bad { XCTAssertThrowsError(try Config.parse(text), text) }
    }

    func testControlIDs() {
        XCTAssertEqual(Control(cid: 0x0053), .back)
        XCTAssertNil(Control(cid: 0x0050))
        XCTAssertEqual(managedControlIDs, [0x52, 0x53, 0x56, 0x5B, 0x5D, 0xD7])
    }

    /// The shipped example must always be valid.
    func testExampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/config.example.toml")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNoThrow(try Config.parse(text))
    }
}

final class ActionTests: XCTestCase {
    func testKeyCombo() {
        XCTAssertEqual(KeyCombo.parse("cmd+shift+4"), KeyCombo(keyCode: 0x15, modifiers: [.command, .shift], character: "4"))
        XCTAssertEqual(KeyCombo.parse("cmd+[")?.character, "[")
        XCTAssertNil(KeyCombo.parse("ctrl+up")?.character)
        XCTAssertNil(KeyCombo.parse("f1")?.character)
        XCTAssertEqual(KeyCombo.parse("CTRL+Up"), KeyCombo(keyCode: 0x7E, modifiers: .control))
        XCTAssertEqual(KeyCombo.parse("f11"), KeyCombo(keyCode: 0x67, modifiers: []))
        XCTAssertEqual(KeyCombo.parse("opt+alt+option+a")?.modifiers, .option)
        XCTAssertNil(KeyCombo.parse(""))
        XCTAssertNil(KeyCombo.parse("cmd+"))
        XCTAssertNil(KeyCombo.parse("cmd+f13"))
        XCTAssertNil(KeyCombo.parse("super+a"))
        XCTAssertTrue(KeyCombo.parse("ctrl+left")!.isArrow)
        XCTAssertTrue(KeyCombo.parse("f3")!.isFunctionKey)
        XCTAssertFalse(KeyCombo.parse("cmd+a")!.isFunctionKey)
    }

    func testNamedActions() {
        XCTAssertEqual(ButtonAction.parse("native"), .native)
        XCTAssertEqual(ButtonAction.parse(" Mission-Control "), .system(.missionControl))
        XCTAssertEqual(ButtonAction.parse("middle-click"), .mouseButton(2))
        XCTAssertEqual(ButtonAction.parse("keys:cmd+w"), .keys(KeyCombo(keyCode: 0x0D, modifiers: .command, character: "w")))
        XCTAssertEqual(ButtonAction.parse("back"), .mouseButton(3))
        XCTAssertEqual(ButtonAction.parse("forward"), .mouseButton(4))
        XCTAssertNil(ButtonAction.parse("keys:"))
        XCTAssertNil(ButtonAction.parse("unknown"))
        XCTAssertFalse(ButtonAction.native.needsDiversion)
        XCTAssertTrue(ButtonAction.none.needsDiversion)
        XCTAssertFalse(ButtonAction.none.needsEventPosting)
    }

    func testSystemShortcutResolution() {
        // This Mac's actual entry for Mission Control: ⇧⌘↑ (with fn+numpad bits).
        let custom: [String: Any] = ["enabled": 1, "value": ["parameters": [65535, 126, 11665408], "type": "standard"]]
        XCTAssertEqual(SystemShortcut.missionControl.resolve(entry: custom),
                       .combo(KeyCombo(keyCode: 126, modifiers: [.shift, .command])))
        // Show Desktop on ⇧⌘D here (character 'd' = 100, key code 2).
        let desk: [String: Any] = ["enabled": true, "value": ["parameters": [100, 2, 1179648]]]
        XCTAssertEqual(SystemShortcut.showDesktop.resolve(entry: desk),
                       .combo(KeyCombo(keyCode: 2, modifiers: [.shift, .command])))
        XCTAssertEqual(SystemShortcut.spaceLeft.resolve(entry: ["enabled": 0]), .disabled)
        XCTAssertEqual(SystemShortcut.spaceLeft.resolve(entry: ["enabled": false]), .disabled)
        XCTAssertEqual(SystemShortcut.missionControl.resolve(entry: nil), .combo(SystemShortcut.missionControl.fallback))
        // Malformed entries fall back to the default.
        XCTAssertEqual(SystemShortcut.missionControl.resolve(entry: ["enabled": 1, "value": ["parameters": [1, 999, 0]]]),
                       .combo(SystemShortcut.missionControl.fallback))
        XCTAssertEqual(SystemShortcut.missionControl.resolve(entry: ["enabled": 1]),
                       .combo(SystemShortcut.missionControl.fallback))
    }

    func testTracker() {
        var t = DivertedButtonTracker()
        var e = t.update([0x53])
        XCTAssertEqual(e.pressed, [0x53]); XCTAssertEqual(e.released, [])
        e = t.update([0x53, 0x56])
        XCTAssertEqual(e.pressed, [0x56]); XCTAssertEqual(e.released, [])
        e = t.update([0x56])
        XCTAssertEqual(e.pressed, []); XCTAssertEqual(e.released, [0x53])
        e = t.update([0x56])   // repeated report: no edge
        XCTAssertEqual(e.pressed, []); XCTAssertEqual(e.released, [])
        XCTAssertEqual(t.releaseAll(), [0x56])
        XCTAssertEqual(t.held, [])
        e = t.update([])
        XCTAssertEqual(e.released, [])
    }
}

final class ConflictsTests: XCTestCase {
    func testNothingInstalled() {
        XCTAssertEqual(Conflicts.installed { _ in false }, [])
        XCTAssertNil(Conflicts.warning([]))
    }

    func testPluginServiceDetected() {
        let found = Conflicts.installed { $0 == "/Applications/Utilities/LogiPluginService.app" }
        XCTAssertEqual(found.map(\.name), ["Logi Plugin Service"])
        let w = Conflicts.warning(found) ?? ""
        XCTAssertTrue(w.contains("Logi Plugin Service"))
        XCTAssertTrue(w.contains("/Applications/Utilities/LogiPluginService.app"))
    }

    func testOnlyFixedPathsAreChecked() {
        var asked: [String] = []
        _ = Conflicts.installed { asked.append($0); return true }
        XCTAssertEqual(asked, Conflicts.known.map(\.path))
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("/Applications/") && $0.hasSuffix(".app") })
    }
}
