package com.example.universal_ble_server

import android.bluetooth.*
import android.content.Context
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** UniversalBleServerPlugin */
class UniversalBleServerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var methodChannel: MethodChannel
  private lateinit var writeChannel: EventChannel
  private lateinit var readChannel: EventChannel
  private var writeSink: EventChannel.EventSink? = null
  private var readSink: EventChannel.EventSink? = null
  private var gattServer: BluetoothGattServer? = null
  private var bluetoothManager: BluetoothManager? = null
  private var context: Context? = null
  private var device: BluetoothDevice? = null
  private val values = mutableMapOf<UUID, ByteArray>()
  private var serviceUuid: UUID? = null

  private val gattCallback = object : BluetoothGattServerCallback() {
    override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
      if (newState == BluetoothProfile.STATE_CONNECTED) {
        this@UniversalBleServerPlugin.device = device
      }
    }

    override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
      val value = values[characteristic.uuid]
      gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
      readSink?.success(mapOf("uuid" to characteristic.uuid.toString()))
    }

    override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
      values[characteristic.uuid] = value
      writeSink?.success(mapOf("uuid" to characteristic.uuid.toString(), "value" to Base64.encodeToString(value, Base64.NO_WRAP)))
      if (responseNeeded) {
        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
      }
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    bluetoothManager = context?.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    methodChannel = MethodChannel(binding.binaryMessenger, "universal_ble_server/methods")
    methodChannel.setMethodCallHandler(this)
    writeChannel = EventChannel(binding.binaryMessenger, "universal_ble_server/onWrite")
    writeChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { writeSink = events }
      override fun onCancel(arguments: Any?) { writeSink = null }
    })
    readChannel = EventChannel(binding.binaryMessenger, "universal_ble_server/onRead")
    readChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { readSink = events }
      override fun onCancel(arguments: Any?) { readSink = null }
    })
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    stopServer()
    methodChannel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "startServer" -> {
        val serviceId = call.argument<String>("serviceUuid")
        val chars = call.argument<List<Map<String, Any>>>("characteristics") ?: emptyList()
        startServer(serviceId, chars)
        result.success(null)
      }
      "stopServer" -> {
        stopServer()
        result.success(null)
      }
      "notify" -> {
        val charUuid = UUID.fromString(call.argument<String>("characteristicUuid"))
        val value = Base64.decode(call.argument<String>("value"), Base64.DEFAULT)
        values[charUuid] = value
        val service = gattServer?.getService(serviceUuid)
        val characteristic = service?.getCharacteristic(charUuid)
        characteristic?.value = value
        device?.let { gattServer?.notifyCharacteristicChanged(it, characteristic, false) }
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun startServer(service: String?, characteristics: List<Map<String, Any>>) {
    serviceUuid = UUID.fromString(service)
    gattServer = bluetoothManager?.openGattServer(context, gattCallback)
    val serviceObj = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
    for (c in characteristics) {
      val uuid = UUID.fromString(c["uuid"] as String)
      val propsList = c["properties"] as List<String>
      var props = 0
      var perms = 0
      if (propsList.contains("read")) { props = props or BluetoothGattCharacteristic.PROPERTY_READ; perms = perms or BluetoothGattCharacteristic.PERMISSION_READ }
      if (propsList.contains("write")) { props = props or BluetoothGattCharacteristic.PROPERTY_WRITE; perms = perms or BluetoothGattCharacteristic.PERMISSION_WRITE }
      if (propsList.contains("notify")) { props = props or BluetoothGattCharacteristic.PROPERTY_NOTIFY }
      val value = Base64.decode(c["value"] as String, Base64.DEFAULT)
      val characteristic = BluetoothGattCharacteristic(uuid, props, perms)
      characteristic.value = value
      serviceObj.addCharacteristic(characteristic)
      values[uuid] = value
    }
    gattServer?.addService(serviceObj)
  }

  private fun stopServer() {
    gattServer?.close()
    gattServer = null
    values.clear()
  }
}
