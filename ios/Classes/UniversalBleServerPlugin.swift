import Flutter
import CoreBluetooth
import UIKit

class EventStreamHandler: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

public class UniversalBleServerPlugin: NSObject, FlutterPlugin, CBPeripheralManagerDelegate {
  private var peripheral: CBPeripheralManager?
  private var characteristics: [CBUUID: CBMutableCharacteristic] = [:]
  private let writeHandler = EventStreamHandler()
  private let readHandler = EventStreamHandler()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = UniversalBleServerPlugin()
    let method = FlutterMethodChannel(name: "universal_ble_server/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: method)
    FlutterEventChannel(name: "universal_ble_server/onWrite", binaryMessenger: registrar.messenger()).setStreamHandler(instance.writeHandler)
    FlutterEventChannel(name: "universal_ble_server/onRead", binaryMessenger: registrar.messenger()).setStreamHandler(instance.readHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startServer":
      guard let args = call.arguments as? [String: Any],
            let serviceUuid = args["serviceUuid"] as? String,
            let chars = args["characteristics"] as? [[String: Any]] else {
        result(FlutterError(code: "args", message: "Invalid arguments", details: nil))
        return
      }
      start(serviceUuid: serviceUuid, characteristics: chars)
      result(nil)
    case "stopServer":
      stop()
      result(nil)
    case "notify":
      guard let args = call.arguments as? [String: Any],
            let uuid = args["characteristicUuid"] as? String,
            let valueB64 = args["value"] as? String,
            let value = Data(base64Encoded: valueB64) else {
        result(FlutterError(code: "args", message: "Invalid arguments", details: nil))
        return
      }
      if let ch = characteristics[CBUUID(string: uuid)] {
        peripheral?.updateValue(value, for: ch, onSubscribedCentrals: nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(serviceUuid: String, characteristics chars: [[String: Any]]) {
    peripheral = CBPeripheralManager(delegate: self, queue: nil)
    characteristics.removeAll()
    let service = CBMutableService(type: CBUUID(string: serviceUuid), primary: true)
    var cbChars: [CBMutableCharacteristic] = []
    for c in chars {
      guard let uuid = c["uuid"] as? String,
            let props = c["properties"] as? [String],
            let valueB64 = c["value"] as? String,
            let value = Data(base64Encoded: valueB64) else { continue }
      var properties: CBCharacteristicProperties = []
      var permissions: CBAttributePermissions = []
      if props.contains("read") { properties.insert(.read); permissions.insert(.readable) }
      if props.contains("write") { properties.insert(.write); permissions.insert(.writeable) }
      if props.contains("notify") { properties.insert(.notify) }
      let ch = CBMutableCharacteristic(type: CBUUID(string: uuid), properties: properties, value: value, permissions: permissions)
      cbChars.append(ch)
      characteristics[CBUUID(string: uuid)] = ch
    }
    service.characteristics = cbChars
    peripheral?.add(service)
    peripheral?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid]])
  }

  private func stop() {
    peripheral?.stopAdvertising()
    peripheral?.removeAllServices()
    peripheral = nil
    characteristics.removeAll()
  }

  // MARK: - CBPeripheralManagerDelegate

  public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {}

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for r in requests {
      if let ch = characteristics[r.characteristic.uuid] {
        ch.value = r.value
        if let data = r.value {
          writeHandler.sink?(["uuid": r.characteristic.uuid.uuidString, "value": data.base64EncodedString()])
        }
      }
      peripheral.respond(to: r, withResult: .success)
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    if let ch = characteristics[request.characteristic.uuid] {
      request.value = ch.value
      readHandler.sink?(["uuid": request.characteristic.uuid.uuidString])
      peripheral.respond(to: request, withResult: .success)
    } else {
      peripheral.respond(to: request, withResult: .attributeNotFound)
    }
  }
}
