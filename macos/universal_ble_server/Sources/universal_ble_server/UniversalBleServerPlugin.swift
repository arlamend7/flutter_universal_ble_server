import FlutterMacOS
import CoreBluetooth

/// CoreBluetooth callbacks and Flutter messages use the main queue.
public class UniversalBleServerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CBPeripheralManagerDelegate {
  private var centralClient: BleCentral?
  private var peripheral: CBPeripheralManager?
  private var channel: FlutterMethodChannel!
  private var sink: FlutterEventSink?
  private var fields: [CBUUID: CBMutableCharacteristic] = [:]
  private var values: [CBUUID: Data] = [:]
  private var subscribers: [CBUUID: [UUID: CBCentral]] = [:]
  private var supportResults: [FlutterResult] = []
  private var startResult: FlutterResult?
  private var pendingServices: [CBMutableService] = []
  private var registeringService: CBMutableService?
  private var advertisedName: String?
  private var advertisedUuid: CBUUID?
  private var notifySequence = 0
  private var running = false
  private var epoch = 0
  private var pendingNotify: (CBMutableCharacteristic, Data, FlutterResult, String?)?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = UniversalBleServerPlugin()
    let messenger = registrar.messenger
    instance.centralClient = BleCentral(messenger: messenger)
    instance.channel = FlutterMethodChannel(name: "universal_ble_server/methods", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
    FlutterEventChannel(name: "universal_ble_server/events", binaryMessenger: messenger).setStreamHandler(instance)
  }
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func error(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
  private func capabilities() -> [String: Any] {
    let state = peripheral?.state ?? .unknown
    return ["platform": "macos", "peripheral": state != .unsupported,
      "nameSupport": "local", "connectionEvents": false, "poweredOn": state == .poweredOn, "authorized": state != .unauthorized && state != .unknown,
      "reason": state == .poweredOn ? "" : "Bluetooth state: \(state.rawValue). Check permission and power."]
  }
  private func support(_ result: @escaping FlutterResult) {
    if let p = peripheral, p.state != .unknown && p.state != .resetting { result(capabilities()); return }
    supportResults.append(result)
    if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: .main) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self = self, !self.supportResults.isEmpty else { return }
      let results = self.supportResults; self.supportResults.removeAll()
      results.forEach { $0(self.capabilities()) }
    }
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkSupport", "requestPermissions": support(result)
    case "stopServer": stop(); result(nil)
    case "startServer":
      guard !running, startResult == nil else { result(error("already_running", "Stop before starting another profile")); return }
      guard peripheral?.state == .poweredOn else { result(error("unavailable", "Bluetooth is not powered on; call checkSupport first")); return }
      guard let args = call.arguments as? [String: Any], let services = args["services"] as? [[String: Any]],
        !services.isEmpty, let advertised = args["advertisedServiceUuid"] as? String else { result(error("bad_args", "Missing services")); return }
      fields.removeAll(); values.removeAll(); subscribers.removeAll(); pendingServices.removeAll()
      for entry in services {
        guard let uuid = entry["uuid"] as? String, let chars = entry["characteristics"] as? [[String: Any]], !chars.isEmpty else { result(error("bad_args", "Invalid service")); return }
        let service = CBMutableService(type: CBUUID(string: uuid), primary: true)
        var characteristics: [CBMutableCharacteristic] = []
        for c in chars {
          guard let uuid = c["uuid"] as? String, let props = c["properties"] as? [String],
            let encoded = c["value"] as? String, let value = Data(base64Encoded: encoded), value.count <= 512 else { result(error("bad_args", "Invalid characteristic")); return }
          let id = CBUUID(string: uuid)
          guard fields[id] == nil else { result(error("bad_args", "Duplicate characteristic UUID")); return }
          var properties: CBCharacteristicProperties = []
          var permissions: CBAttributePermissions = []
          if props.contains("read") { properties.insert(.read); permissions.insert(.readable) }
          if props.contains("write") { properties.insert(.write); permissions.insert(.writeable) }
          if props.contains("notify") { properties.insert(.notify) }
          if c["security"] as? String == "encryptedReadWrite" {
            permissions = []
            if props.contains("read") { permissions.insert(.readEncryptionRequired) }
            if props.contains("write") { permissions.insert(.writeEncryptionRequired) }
          }
          // nil is required for dynamic (writable/notifiable) characteristics.
          let ch = CBMutableCharacteristic(type: id, properties: properties, value: nil, permissions: permissions)
          fields[id] = ch; values[id] = value; characteristics.append(ch)
        }
        service.characteristics = characteristics; pendingServices.append(service)
      }
      advertisedName = args["name"] as? String
      if let name = advertisedName, name.utf8.count > 29 || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.contains("\0") { result(error("bad_args", "Invalid advertised name")); return }
      advertisedUuid = CBUUID(string: advertised)
      epoch += 1; let current = epoch
      startResult = result
      registeringService = pendingServices.removeFirst()
      peripheral?.add(registeringService!)
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
        guard let self = self, self.epoch == current, self.startResult != nil else { return }
        self.failStart("Startup timed out")
      }
    case "setValue", "notify":
      guard running else { result(error("not_running", "Server is not running")); return }
      guard let args = call.arguments as? [String: Any], let uuid = args["characteristicUuid"] as? String,
        let encoded = args["value"] as? String, let data = Data(base64Encoded: encoded), data.count <= 512,
        let field = fields[CBUUID(string: uuid)] else { result(error("bad_args", "Invalid value or unknown characteristic")); return }
      if call.method == "setValue" { values[field.uuid] = data; result(nil); return }
      guard field.properties.contains(.notify) else { result(error("not_notifiable", "Characteristic does not support notifications")); return }
      guard pendingNotify == nil else { result(error("busy", "Notification pending")); return }
      let clientId = args["clientId"] as? String
      let clients = Array((subscribers[field.uuid] ?? [:]).values).filter { clientId == nil || $0.identifier.uuidString == clientId }
      if clientId != nil && clients.isEmpty { result(error("disconnected", "Client disconnected or not subscribed")); return }
      guard clients.allSatisfy({ data.count <= $0.maximumUpdateValueLength }) else { result(error("value_too_large", "Value exceeds a subscriber MTU; use an agreed framing protocol")); return }
      if clients.isEmpty { result(nil); return }
      notifySequence += 1; let sequence = notifySequence
      pendingNotify = (field, data, result, clientId); flushNotification()
      let current = epoch
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
        guard let self = self, self.epoch == current, self.notifySequence == sequence, let pending = self.pendingNotify else { return }
        self.pendingNotify = nil; pending.2(self.error("timeout", "Notification queue remained full"))
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func failStart(_ message: String) {
    let result = startResult; startResult = nil; stop(); result?(error("start_failed", message))
  }
  private func stop() {
    epoch += 1; running = false
    let start = startResult; startResult = nil; start?(error("cancelled", "Server stopped"))
    let notification = pendingNotify; pendingNotify = nil; notification?.2(error("cancelled", "Server stopped"))
    if peripheral?.state == .poweredOn { peripheral?.stopAdvertising(); peripheral?.removeAllServices() }
    fields.removeAll(); values.removeAll(); subscribers.removeAll(); pendingServices.removeAll()
    registeringService = nil
    peripheral?.delegate = nil; peripheral = nil
    let checks = supportResults; supportResults.removeAll()
    checks.forEach { $0(error("cancelled", "Server stopped")) }
  }
  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    guard peripheral === self.peripheral else { return }
    let results = supportResults; supportResults.removeAll(); results.forEach { $0(capabilities()) }
    if peripheral.state != .poweredOn && (running || startResult != nil) {
      sink?(["type": "error", "message": "Bluetooth is unavailable"]); stop()
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    guard peripheral === self.peripheral, startResult != nil, service === registeringService else { return }
    if let error = error { failStart(error.localizedDescription); return }
    if !pendingServices.isEmpty { registeringService = pendingServices.removeFirst(); peripheral.add(registeringService!) }
    else if let uuid = advertisedUuid {
      var data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [uuid]]
      if let name = advertisedName { data[CBAdvertisementDataLocalNameKey] = name }
      peripheral.startAdvertising(data)
    }
  }
  public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    guard peripheral === self.peripheral, startResult != nil else { return }
    if let error = error { failStart(error.localizedDescription); return }
    running = true; let result = startResult; startResult = nil; result?(nil)
  }
  private func request(_ args: [String: Any], completion: @escaping (CBATTError.Code, Data?) -> Void) {
    let current = epoch
    var completed = false
    let finish: (CBATTError.Code, Data?) -> Void = { [weak self] status, bytes in
      guard let self = self, !completed else { return }; completed = true
      if self.epoch == current { completion(status, bytes) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish(.unlikelyError, nil) }
    channel.invokeMethod("request", arguments: args) { response in
      guard let map = response as? [String: Any], let code = map["status"] as? Int else { finish(.unlikelyError, nil); return }
      let bytes = (map["value"] as? String).flatMap { Data(base64Encoded: $0) }
      finish(CBATTError.Code(rawValue: code) ?? .unlikelyError, bytes)
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard running else { peripheral.respond(to: request, withResult: .unlikelyError); return }
    let args: [String: Any] = ["type": "read", "uuid": request.characteristic.uuid.uuidString.lowercased(),
      "clientId": request.central.identifier.uuidString, "offset": request.offset]
    self.request(args) { [weak self] status, data in
      guard let self = self else { return }
      var status = status
      if status == .success {
        if let data = data, request.offset <= data.count {
          request.value = data.subdata(in: request.offset..<data.count)
        } else { status = .invalidOffset }
      }
      peripheral.respond(to: request, withResult: status)
      if status == .success { self.sink?(args) }
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    // Atomic multi-attribute/prepared writes are outside the portable contract.
    // Reject the entire batch and respond exactly once, as CoreBluetooth requires.
    guard running, requests.count == 1 else { peripheral.respond(to: first, withResult: .requestNotSupported); return }
    guard first.offset == 0 else { peripheral.respond(to: first, withResult: .invalidOffset); return }
    let bytes = first.value ?? Data()
    let args: [String: Any] = ["type": "write", "uuid": first.characteristic.uuid.uuidString.lowercased(),
      "clientId": first.central.identifier.uuidString, "offset": 0, "value": bytes.base64EncodedString()]
    request(args) { [weak self] status, data in
      guard let self = self else { return }
      if status == .success, let data = data { self.values[first.characteristic.uuid] = data; self.sink?(args) }
      peripheral.respond(to: first, withResult: status)
    }
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
    subscribers[characteristic.uuid, default: [:]][central.identifier] = central
    sink?(["type": "subscribed", "uuid": characteristic.uuid.uuidString.lowercased(), "clientId": central.identifier.uuidString, "maxNotificationBytes": central.maximumUpdateValueLength])
  }
  public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
    subscribers[characteristic.uuid]?.removeValue(forKey: central.identifier)
    sink?(["type": "unsubscribed", "uuid": characteristic.uuid.uuidString.lowercased(), "clientId": central.identifier.uuidString])
  }
  private func flushNotification() {
    guard let pending = pendingNotify else { return }
    let clients = Array((subscribers[pending.0.uuid] ?? [:]).values).filter { pending.3 == nil || $0.identifier.uuidString == pending.3 }
    if pending.3 != nil && clients.isEmpty { pendingNotify = nil; pending.2(error("disconnected", "Client unsubscribed")); return }
    if clients.isEmpty || peripheral?.updateValue(pending.1, for: pending.0, onSubscribedCentrals: clients) == true {
      pendingNotify = nil; pending.2(nil)
    }
  }
  public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flushNotification() }
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) { stop(); peripheral?.delegate = nil; peripheral = nil; sink = nil }
}
