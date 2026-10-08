// notify-focus-ax.swift — the accessibility helper a banner click calls to
// bring an iTerm2 window forward across Spaces.
//
//   trusted                                       0 trusted / 3 not
//   raise <pid> <wid> [--eid <n>] [--budget-ms <n>] --ceiling <n>
//                                                 0 raised (prints the element id
//                                                 when it is known) / 1 other AX
//                                                 error or budget spent / 2 usage /
//                                                 3 not trusted / 4 not found /
//                                                 5 not iTerm2 / 7 AX cannot
//                                                 complete / 8 symbol missing
//   onspace <wid>                                 0 on a current Space / 6 not /
//                                                 4 unknown / 8 symbol missing
//   map <pid> [--budget-ms <n>] --ceiling <n>     prints `wid<TAB>eid` per window
//                                                 0 / 1 budget spent / 2 / 3 / 5 /
//                                                 7 / 8
//   aecheck                                       0 when Apple events to iTerm2
//                                                 are allowed, never asking
//
// The handler compiles this file itself (notify-focus.sh); nothing here is run
// through a shim, and no verb ever activates an application.
//
// PRIVATE SYMBOLS ARE LOOKED UP AT RUN TIME. A missing symbol linked by name
// fails the link and takes every verb with it; looked up with dlsym, it fails
// only the verbs that need it, with exit 8. The test-only seam
// CC_CMDS_NOTIFY_FOCUS_AX_MISSING=<symbol> treats that one name as missing.
//
// AX CANNOT-COMPLETE IS NEVER "NOT FOUND". iTerm2's accessibility server can
// stop answering for minutes while AppleScript still works, and a scan then
// misses every window. Reporting that as 4 would make the caller drop a good
// cache entry, so -25204 from any call ends the verb with 7 at once.
//
// Diagnostics go to standard error only when CC_CMDS_NOTIFY_FOCUS_TRACE is set.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let itermBundle = "com.googlecode.iterm2"

let env = ProcessInfo.processInfo.environment
let tracing = !(env["CC_CMDS_NOTIFY_FOCUS_TRACE"] ?? "").isEmpty

func trace(_ s: String) {
  if tracing { FileHandle.standardError.write(("notify-focus-ax: " + s + "\n").data(using: .utf8)!) }
}

func out(_ s: String) {
  FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

// MARK: symbols

typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
typealias MainConnectionFn = @convention(c) () -> Int32
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

// RTLD_DEFAULT is a macro Swift does not import.
let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

func lookup(_ name: String) -> UnsafeMutableRawPointer? {
  if env["CC_CMDS_NOTIFY_FOCUS_AX_MISSING"] == name {
    trace("symbol \(name) treated as missing")
    return nil
  }
  guard let p = dlsym(rtldDefault, name) else {
    trace("symbol \(name) not found")
    return nil
  }
  return p
}

func axSymbols() -> (CreateWithRemoteTokenFn, GetWindowFn)? {
  guard let a = lookup("_AXUIElementCreateWithRemoteToken"),
        let b = lookup("_AXUIElementGetWindow") else { return nil }
  return (unsafeBitCast(a, to: CreateWithRemoteTokenFn.self),
          unsafeBitCast(b, to: GetWindowFn.self))
}

func cgsSymbols() -> (MainConnectionFn, CopySpacesForWindowsFn, CopyManagedDisplaySpacesFn)? {
  guard let a = lookup("CGSMainConnectionID"),
        let b = lookup("CGSCopySpacesForWindows"),
        let c = lookup("CGSCopyManagedDisplaySpaces") else { return nil }
  return (unsafeBitCast(a, to: MainConnectionFn.self),
          unsafeBitCast(b, to: CopySpacesForWindowsFn.self),
          unsafeBitCast(c, to: CopyManagedDisplaySpacesFn.self))
}

// MARK: arguments

func usage(_ why: String) -> Never {
  trace("usage: \(why)")
  exit(2)
}

func number(_ s: String) -> UInt64? {
  if s.isEmpty || s.contains(where: { !("0"..."9").contains($0) }) { return nil }
  return UInt64(s)
}

struct Options {
  var eid: UInt64? = nil
  var budgetMs: UInt64? = nil
  var ceiling: UInt64? = nil
}

func parseOptions(_ args: ArraySlice<String>, allowEid: Bool) -> Options {
  var o = Options()
  var i = args.startIndex
  while i < args.endIndex {
    let flag = args[i]
    guard i + 1 < args.endIndex, let v = number(args[i + 1]) else { usage("\(flag) needs a number") }
    switch flag {
    case "--eid" where allowEid: o.eid = v
    case "--budget-ms": o.budgetMs = v
    case "--ceiling": o.ceiling = v
    default: usage("unknown option \(flag)")
    }
    i += 2
  }
  return o
}

// MARK: AX helpers

struct CannotComplete: Error {}

func check(_ e: AXError, _ what: String) throws {
  if e == .cannotComplete {
    trace("\(what): cannot complete (-25204)")
    throw CannotComplete()
  }
}

func requireTrusted() {
  if !AXIsProcessTrusted() {
    trace("process is not trusted for accessibility")
    exit(3)
  }
}

func requireIterm(_ pid: pid_t) {
  guard let app = NSRunningApplication(processIdentifier: pid),
        app.bundleIdentifier == itermBundle else {
    trace("pid \(pid) is not a running iTerm2")
    exit(5)
  }
}

// A remote token names one element of another process by its element id: the
// pid, a zero word, the magic 'coco', then the 64-bit id.
func remoteToken(_ pid: pid_t, _ eid: UInt64) -> CFData {
  var d = Data()
  var p = pid, z = Int32(0), magic = Int32(0x636f_636f), e = eid
  withUnsafeBytes(of: &p) { d.append(contentsOf: $0) }
  withUnsafeBytes(of: &z) { d.append(contentsOf: $0) }
  withUnsafeBytes(of: &magic) { d.append(contentsOf: $0) }
  withUnsafeBytes(of: &e) { d.append(contentsOf: $0) }
  return d as CFData
}

// Every element of a window answers _AXUIElementGetWindow with that window's
// id, so a wid match alone may be a button. The role is read only after the
// wid matched, which keeps the per-id cost of a scan at one call.
func isWindow(_ el: AXUIElement) throws -> Bool {
  var ref: CFTypeRef?
  let e = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref)
  try check(e, "role")
  return e == .success && (ref as? String) == (kAXWindowRole as String)
}

func windowId(_ el: AXUIElement, _ getWindow: GetWindowFn) throws -> CGWindowID? {
  var id: CGWindowID = 0
  let e = getWindow(el, &id)
  try check(e, "get window")
  return e == .success ? id : nil
}

final class Budget {
  let deadline: UInt64?
  init(_ ms: UInt64?) {
    if let ms = ms {
      deadline = DispatchTime.now().uptimeNanoseconds &+ ms &* 1_000_000
    } else {
      deadline = nil
    }
  }
  var spent: Bool {
    guard let d = deadline else { return false }
    return DispatchTime.now().uptimeNanoseconds >= d
  }
}

// MARK: verbs

func verbTrusted() -> Never {
  exit(AXIsProcessTrusted() ? 0 : 3)
}

func verbRaise(_ args: ArraySlice<String>) -> Never {
  guard args.count >= 2, let p = number(args[args.startIndex]), p > 0, p <= UInt64(Int32.max),
        let w = number(args[args.startIndex + 1]), w <= UInt64(UInt32.max) else {
    usage("raise <pid> <wid> [--eid <n>] [--budget-ms <n>] --ceiling <n>")
  }
  let o = parseOptions(args.dropFirst(2), allowEid: true)
  guard let ceiling = o.ceiling else { usage("raise needs --ceiling") }
  guard let (createWithToken, getWindow) = axSymbols() else { exit(8) }
  requireTrusted()
  let pid = pid_t(p), wid = CGWindowID(w)
  requireIterm(pid)
  let budget = Budget(o.budgetMs)

  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(app, 0.25)

  var hit: AXUIElement? = nil
  var hitEid: UInt64? = nil
  do {
    // 1. The element id the caller remembered, accepted only if it still is
    // that window.
    if let eid = o.eid, let el = createWithToken(remoteToken(pid, eid))?.takeRetainedValue() {
      AXUIElementSetMessagingTimeout(el, 0.25)
      if try windowId(el, getWindow) == wid, try isWindow(el) {
        hit = el; hitEid = eid
        trace("hint \(eid) still names window \(wid)")
      }
    }
    // 2. The windows the application lists — only those on the current Space.
    if hit == nil {
      var ref: CFTypeRef?
      let e = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref)
      try check(e, "windows")
      for el in (ref as? [AXUIElement]) ?? [] {
        if try windowId(el, getWindow) == wid { hit = el; break }
      }
      if hit != nil { trace("window \(wid) found in the windows list") }
    }
    // 3. Element ids upward from zero, stopping at the first match.
    if hit == nil {
      var eid: UInt64 = 0
      while hit == nil {
        if eid > ceiling {
          trace("ceiling \(ceiling) reached without window \(wid)")
          exit(4)
        }
        if budget.spent {
          trace("budget spent at element id \(eid)")
          exit(1)
        }
        if let el = createWithToken(remoteToken(pid, eid))?.takeRetainedValue() {
          AXUIElementSetMessagingTimeout(el, 0.25)
          if try windowId(el, getWindow) == wid, try isWindow(el) {
            hit = el; hitEid = eid
          }
        }
        eid += 1
      }
      trace("scan found window \(wid) at element id \(hitEid!)")
    }

    let r = AXUIElementPerformAction(hit!, kAXRaiseAction as CFString)
    try check(r, "raise")
    if r != .success {
      trace("raise failed: \(r.rawValue)")
      exit(1)
    }
    let m = AXUIElementSetAttributeValue(hit!, kAXMainAttribute as CFString, kCFBooleanTrue)
    try check(m, "main")
    if m != .success { trace("main failed: \(m.rawValue)") }
  } catch {
    exit(7)
  }
  if let eid = hitEid { out(String(eid)) }
  exit(0)
}

func verbMap(_ args: ArraySlice<String>) -> Never {
  guard args.count >= 1, let p = number(args[args.startIndex]), p > 0, p <= UInt64(Int32.max) else {
    usage("map <pid> [--budget-ms <n>] --ceiling <n>")
  }
  let o = parseOptions(args.dropFirst(1), allowEid: false)
  guard let ceiling = o.ceiling else { usage("map needs --ceiling") }
  guard let (createWithToken, getWindow) = axSymbols() else { exit(8) }
  requireTrusted()
  let pid = pid_t(p)
  requireIterm(pid)
  let budget = Budget(o.budgetMs)

  var seen = Set<CGWindowID>()
  var eid: UInt64 = 0
  do {
    while eid <= ceiling {
      if budget.spent {
        trace("budget spent at element id \(eid)")
        exit(1)
      }
      if let el = createWithToken(remoteToken(pid, eid))?.takeRetainedValue() {
        AXUIElementSetMessagingTimeout(el, 0.25)
        if let wid = try windowId(el, getWindow), wid != 0, !seen.contains(wid), try isWindow(el) {
          seen.insert(wid)
          out("\(wid)\t\(eid)")
        }
      }
      eid += 1
    }
  } catch {
    exit(7)
  }
  exit(0)
}

func verbOnspace(_ args: ArraySlice<String>) -> Never {
  guard args.count == 1, let w = number(args[args.startIndex]), w <= UInt64(UInt32.max) else {
    usage("onspace <wid>")
  }
  guard let (mainConnection, spacesForWindows, displaySpaces) = cgsSymbols() else { exit(8) }
  let c = mainConnection()
  // Mask 7: the window's Spaces of every kind.
  let ws = spacesForWindows(c, 7, [NSNumber(value: UInt32(w))] as CFArray)?.takeRetainedValue()
    as? [NSNumber] ?? []
  if ws.isEmpty {
    trace("window \(w) has no Space")
    exit(4)
  }
  guard let displays = displaySpaces(c)?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else {
    trace("display Spaces unreadable")
    exit(4)
  }
  var current = Set<UInt64>()
  for d in displays {
    if let cur = d["Current Space"] as? [String: Any] {
      if let n = (cur["id64"] ?? cur["ManagedSpaceID"]) as? NSNumber { current.insert(n.uint64Value) }
    }
  }
  if current.isEmpty {
    trace("no current Space found")
    exit(4)
  }
  for s in ws where current.contains(s.uint64Value) { exit(0) }
  trace("window \(w) is on \(ws) and the current Spaces are \(current.sorted())")
  exit(6)
}

func verbAecheck() -> Never {
  let target = NSAppleEventDescriptor(bundleIdentifier: itermBundle)
  guard let desc = target.aeDesc else { exit(1) }
  let wildcard = AEEventClass(0x2A2A_2A2A)  // typeWildCard, '****'
  let st = AEDeterminePermissionToAutomateTarget(desc, wildcard, AEEventID(wildcard), false)
  if st != noErr {
    trace("automation permission status \(st)")
    exit(1)
  }
  exit(0)
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { usage("no verb") }
let rest = argv.dropFirst(2)
switch argv[1] {
case "trusted": if !rest.isEmpty { usage("trusted takes no argument") }; verbTrusted()
case "raise": verbRaise(rest)
case "onspace": verbOnspace(rest)
case "map": verbMap(rest)
case "aecheck": if !rest.isEmpty { usage("aecheck takes no argument") }; verbAecheck()
default: usage("unknown verb \(argv[1])")
}
