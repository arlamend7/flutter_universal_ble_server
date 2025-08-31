import Flutter
import UIKit
import CoreBluetooth

public class UniversalBleServerPlugin: NSObject, FlutterPlugin, CBPeripheralManagerDelegate {
  var peripheralManager: CBPeripheralManager?
  var characteristics: [String: CBMutableCharacteristic] = [:]
  var writeSink: FlutterEventSink?
  var readSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "universal_ble_server/methods", binaryMessenger: registrar.messenger())
    let instance = UniversalBleServerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    let writeChannel = FlutterEventChannel(name: "universal_ble_server/on_write", binaryMessenger: registrar.messenger())
    writeChannel.setStreamHandler(instance.writeStreamHandler)

    let readChannel = FlutterEventChannel(name: "universal_ble_server/on_read", binaryMessenger: registrar.messenger())
    readChannel.setStreamHandler(instance.readStreamHandler)
  }

  lazy var writeStreamHandler: StreamHandler = {
    StreamHandler(onListen: { sink in self.writeSink = sink }, onCancel: { _ in self.writeSink = nil })
  }()

  lazy var readStreamHandler: StreamHandler = {
    StreamHandler(onListen: { sink in self.readSink = sink }, onCancel: { _ in self.readSink = nil })
  }()

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startServer":
      if let args = call.arguments as? [String: Any],
         let serviceUuid = args["serviceUuid"] as? String,
         let chars = args["characteristics"] as? [[String: Any]] {
        startServer(serviceUuid: serviceUuid, characteristics: chars)
      }
      result(nil)
    case "stopServer":
      stopServer()
      result(nil)
    case "notify":
      if let args = call.arguments as? [String: Any],
         let uuid = args["characteristicUuid"] as? String,
         let value = args["value"] as? FlutterStandardTypedData {
        notify(uuid: uuid, value: Data(value.data))
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startServer(serviceUuid: String, characteristics: [[String: Any]]) {
    peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    let service = CBMutableService(type: CBUUID(string: serviceUuid), primary: true)
    var list: [CBMutableCharacteristic] = []
    for c in characteristics {
      guard let uuid = c["uuid"] as? String,
            let props = c["properties"] as? [String] else { continue }
      var properties: CBCharacteristicProperties = []
      var permissions: CBAttributePermissions = []
      if props.contains("read") {
        properties.insert(.read)
        permissions.insert(.readable)
      }
      if props.contains("write") {
        properties.insert(.write)
        permissions.insert(.writeable)
      }
      if props.contains("notify") {
        properties.insert(.notify)
      }
      let value = (c["value"] as? FlutterStandardTypedData)?.data
      let characteristic = CBMutableCharacteristic(type: CBUUID(string: uuid), properties: properties, value: value, permissions: permissions)
      list.append(characteristic)
      self.characteristics[uuid] = characteristic
    }
    service.characteristics = list
    peripheralManager?.add(service)
    peripheralManager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: serviceUuid)]])
  }

  private func stopServer() {
    peripheralManager?.stopAdvertising()
    peripheralManager?.removeAllServices()
    peripheralManager = nil
    characteristics.removeAll()
  }

  private func notify(uuid: String, value: Data) {
    guard let char = characteristics[uuid] else { return }
    char.value = value
    peripheralManager?.updateValue(value, for: char, onSubscribedCentrals: nil)
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests {
      if let value = request.value {
        let uuid = request.characteristic.uuid.uuidString
        writeSink?(["characteristicUuid": uuid, "value": value])
        request.characteristic.value = value
      }
      peripheral.respond(to: request, withResult: .success)
    }
  }

  public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    let uuid = request.characteristic.uuid.uuidString
    readSink?(["characteristicUuid": uuid])
    request.value = request.characteristic.value
    peripheral.respond(to: request, withResult: .success)
  }
}

/// Simple stream handler used for event channels.
class StreamHandler: NSObject, FlutterStreamHandler {
  let onListenCallback: (FlutterEventSink?) -> Void
  let onCancelCallback: (FlutterEventSink?) -> Void

  init(onListen: @escaping (FlutterEventSink?) -> Void, onCancel: @escaping (FlutterEventSink?) -> Void) {
    onListenCallback = onListen
    onCancelCallback = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onListenCallback(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onCancelCallback(nil)
    return nil
  }
}
