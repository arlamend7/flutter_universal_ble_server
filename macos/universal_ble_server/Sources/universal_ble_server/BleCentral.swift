import FlutterMacOS
import CoreBluetooth

/// All CoreBluetooth and Flutter callbacks are confined to the main queue.
final class BleCentral: NSObject, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private var manager: CBCentralManager?
  private var sink: FlutterEventSink?
  private let channel: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var devices: [String: CBPeripheral] = [:]
  private var peer: CBPeripheral?
  private var fields: [String: CBCharacteristic] = [:]
  private var servicesPending = Set<CBUUID>()
  private var pending: FlutterResult?
  private var operation: String?
  private var pendingKey: String?
  private var support: [FlutterResult] = []
  private var sequence = 0
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "universal_ble_server/client/methods", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "universal_ble_server/client/events", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    events.setStreamHandler(self)
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func error(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
  private func state() -> String {
    switch manager?.state ?? .unknown {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    default: return "unknown"
    }
  }
  private func uuid(_ id: CBUUID) -> String {
    let s = id.uuidString.lowercased()
    if s.count == 4 { return "0000\(s)-0000-1000-8000-00805f9b34fb" }
    if s.count == 8 { return "\(s)-0000-1000-8000-00805f9b34fb" }
    return s
  }
  private func key(_ c: CBCharacteristic) -> String { "\(uuid(c.service!.uuid))/\(uuid(c.uuid))" }
  private func begin(_ name: String, _ result: @escaping FlutterResult, key: String? = nil) -> Bool {
    guard pending == nil else { result(error("busy", "Operation pending")); return false }
    pending = result; operation = name; pendingKey = key; sequence += 1
    let ticket = sequence
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self = self, self.sequence == ticket, self.pending != nil else { return }
      self.finish(self.error("timeout", "BLE operation timed out"))
      self.close(resetManager: true)
      self.sink?(["type": "disconnected"])
    }
    return true
  }
  private func finish(_ value: Any?) { let result = pending; pending = nil; operation = nil; pendingKey = nil; sequence += 1; result?(value) }
  private func close(resetManager: Bool = false) {
    if pending != nil { finish(error("disconnected", "Connection closed")) }
    if let p = peer { p.delegate = nil; manager?.cancelPeripheralConnection(p) }
    peer = nil; fields.removeAll(); servicesPending.removeAll()
    if resetManager { manager?.stopScan(); manager?.delegate = nil; manager = nil; devices.removeAll() }
  }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "dispose" { close(resetManager: true); result(nil); return }
    if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
    switch call.method {
    case "checkSupport", "requestPermissions":
      if state() == "unknown" {
        support.append(result)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishSupport() }
      } else { result(state()) }
    case "stopScan": manager?.stopScan(); result(nil)
    case "disconnect": close(); result(nil)
    default:
      guard state() == "poweredOn" else { result(error(state() == "unauthorized" ? "permission_denied" : "bluetooth_off", "Bluetooth is not ready")); return }
      switch call.method {
      case "startScan":
        let uuids = (args["services"] as? [String] ?? []).map { CBUUID(string: $0) }
        manager?.scanForPeripherals(withServices: uuids.isEmpty ? nil : uuids, options: nil); result(nil)
      case "connect":
        guard peer == nil, let id = args["id"] as? String, let p = devices[id] else { result(error("disconnected", "Scan first and disconnect any previous peer")); return }
        guard begin("connect", result) else { return }
        peer = p; p.delegate = self; manager?.connect(p, options: nil)
      case "maximumWriteBytes":
        guard let p = peer else { result(error("disconnected", "No peer")); return }
        result(p.maximumWriteValueLength(for: .withResponse))
      case "discover":
        guard let p = peer else { result(error("disconnected", "No peer")); return }
        guard begin("discover", result) else { return }
        fields.removeAll(); p.discoverServices(nil)
      case "read", "write", "subscribe":
        guard let p = peer, let k = args["key"] as? String, let c = fields[k] else { result(error("ble_error", "Characteristic missing")); return }
        guard begin(call.method, result, key: k) else { return }
        if call.method == "read" { p.readValue(for: c) }
        else if call.method == "subscribe" { p.setNotifyValue(args["enabled"] as? Bool ?? false, for: c) }
        else {
          guard let value = args["value"] as? String, let data = Data(base64Encoded: value), data.count <= p.maximumWriteValueLength(for: .withResponse) else { finish(error("ble_error", "Invalid or oversized write")); return }
          p.writeValue(data, for: c, type: .withResponse)
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private func finishSupport() { let results = support; support.removeAll(); for r in results { r(state()) } }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === manager else { return }
    finishSupport(); sink?(["type": "state", "state": state()])
    if central.state != .poweredOn { close(); sink?(["type": "disconnected"]) }
  }
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard central === manager else { return }
    let id = peripheral.identifier.uuidString
    guard devices.count < 1024 || devices[id] != nil else { return }
    devices[id] = peripheral
    var event: [String: Any] = ["type": "discovered", "id": id, "rssi": RSSI.intValue]
    if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name { event["name"] = name }
    sink?(event)
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    if central === manager && peripheral === peer && operation == "connect" { finish(nil) }
  }
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if central === manager && peripheral === peer { close(); sink?(["type": "disconnected"]) }
  }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    if central === manager && peripheral === peer { close(); sink?(["type": "disconnected"]) }
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard peripheral === peer && operation == "discover" else { return }
    if let e = error { finish(self.error("ble_error", e.localizedDescription)); return }
    let services = peripheral.services ?? []
    servicesPending = Set(services.map { $0.uuid })
    if services.isEmpty { finish([]); return }
    for service in services { peripheral.discoverCharacteristics(nil, for: service) }
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard peripheral === peer && operation == "discover" else { return }
    if let e = error { finish(self.error("ble_error", e.localizedDescription)); return }
    for c in service.characteristics ?? [] {
      if fields[key(c)] != nil { finish(self.error("ble_error", "Ambiguous characteristic")); return }
      fields[key(c)] = c
    }
    servicesPending.remove(service.uuid)
    if !servicesPending.isEmpty { return }
    let result: [[String: Any]] = fields.values.map { c in
      var access: [String] = []
      if c.properties.contains(.read) { access.append("read") }
      if c.properties.contains(.write) { access.append("write") }
      if c.properties.contains(.notify) || c.properties.contains(.indicate) { access.append("notify") }
      return ["service": uuid(c.service!.uuid), "uuid": uuid(c.uuid), "access": access]
    }
    finish(result)
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard peripheral === peer else { return }
    if operation == "read" && pendingKey == key(c) {
      if let e = error { finish(self.error("ble_error", e.localizedDescription)) }
      else { finish((c.value ?? Data()).base64EncodedString()) }
    }
    if c.isNotifying && error == nil { sink?(["type": "notification", "key": key(c), "value": (c.value ?? Data()).base64EncodedString()]) }
  }
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
    guard peripheral === peer && operation == "write" && pendingKey == key(c) else { return }
    finish(error.map { self.error("ble_error", $0.localizedDescription) })
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
    guard peripheral === peer && operation == "subscribe" && pendingKey == key(c) else { return }
    finish(error.map { self.error("ble_error", $0.localizedDescription) })
  }
  deinit { manager?.delegate = nil; manager?.stopScan(); if let p = peer { p.delegate = nil; manager?.cancelPeripheralConnection(p) } }
}
