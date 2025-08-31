package com.example.universal_ble_server

import android.bluetooth.*
import android.content.Context
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android implementation of the Universal BLE Server plugin.
 */
class UniversalBleServerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var writeChannel: EventChannel
  private lateinit var readChannel: EventChannel
  private var context: Context? = null
  private var gattServer: BluetoothGattServer? = null
  private val characteristics = mutableMapOf<String, BluetoothGattCharacteristic>()
  private var connectedDevice: BluetoothDevice? = null
  private var writeSink: EventChannel.EventSink? = null
  private var readSink: EventChannel.EventSink? = null

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "universal_ble_server/methods")
    channel.setMethodCallHandler(this)

    writeChannel = EventChannel(binding.binaryMessenger, "universal_ble_server/on_write")
    writeChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        writeSink = events
      }

      override fun onCancel(arguments: Any?) {
        writeSink = null
      }
    })

    readChannel = EventChannel(binding.binaryMessenger, "universal_ble_server/on_read")
    readChannel.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        readSink = events
      }

      override fun onCancel(arguments: Any?) {
        readSink = null
      }
    })
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "startServer" -> {
        val serviceUuid = call.argument<String>("serviceUuid")!!
        val chars = call.argument<List<Map<String, Any>>>("characteristics") ?: emptyList()
        startServer(serviceUuid, chars)
        result.success(null)
      }
      "stopServer" -> {
        stopServer()
        result.success(null)
      }
      "notify" -> {
        val uuid = call.argument<String>("characteristicUuid")!!
        val value = call.argument<ByteArray>("value")!!
        notify(uuid, value)
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun startServer(serviceUuid: String, characteristicMaps: List<Map<String, Any>>) {
    val bluetoothManager = context!!.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    gattServer = bluetoothManager.openGattServer(context, gattCallback)
    val service = BluetoothGattService(java.util.UUID.fromString(serviceUuid), BluetoothGattService.SERVICE_TYPE_PRIMARY)
    for (map in characteristicMaps) {
      val uuid = java.util.UUID.fromString(map["uuid"] as String)
      val propsList = map["properties"] as List<*>
      var props = 0
      var perms = 0
      if (propsList.contains("read")) {
        props = props or BluetoothGattCharacteristic.PROPERTY_READ
        perms = perms or BluetoothGattCharacteristic.PERMISSION_READ
      }
      if (propsList.contains("write")) {
        props = props or BluetoothGattCharacteristic.PROPERTY_WRITE
        perms = perms or BluetoothGattCharacteristic.PERMISSION_WRITE
      }
      if (propsList.contains("notify")) {
        props = props or BluetoothGattCharacteristic.PROPERTY_NOTIFY
      }
      val characteristic = BluetoothGattCharacteristic(uuid, props, perms)
      val value = map["value"] as? ByteArray
      if (value != null) characteristic.value = value
      service.addCharacteristic(characteristic)
      characteristics[uuid.toString()] = characteristic
    }
    gattServer?.addService(service)
  }

  private fun stopServer() {
    gattServer?.close()
    gattServer = null
    characteristics.clear()
    connectedDevice = null
  }

  private fun notify(uuid: String, value: ByteArray) {
    val characteristic = characteristics[uuid] ?: return
    characteristic.value = value
    connectedDevice?.let {
      gattServer?.notifyCharacteristicChanged(it, characteristic, false)
    }
  }

  private val gattCallback = object : BluetoothGattServerCallback() {
    override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
      if (newState == BluetoothProfile.STATE_CONNECTED) {
        connectedDevice = device
      } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
        connectedDevice = null
      }
    }

    override fun onCharacteristicReadRequest(
      device: BluetoothDevice,
      requestId: Int,
      offset: Int,
      characteristic: BluetoothGattCharacteristic
    ) {
      readSink?.success(mapOf("characteristicUuid" to characteristic.uuid.toString()))
      gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, characteristic.value)
    }

    override fun onCharacteristicWriteRequest(
      device: BluetoothDevice,
      requestId: Int,
      characteristic: BluetoothGattCharacteristic,
      preparedWrite: Boolean,
      responseNeeded: Boolean,
      offset: Int,
      value: ByteArray
    ) {
      characteristic.value = value
      writeSink?.success(mapOf("characteristicUuid" to characteristic.uuid.toString(), "value" to value))
      gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
    }
  }
}
