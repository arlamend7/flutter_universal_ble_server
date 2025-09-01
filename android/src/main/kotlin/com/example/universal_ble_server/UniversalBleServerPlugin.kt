package com.example.universal_ble_server

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet

/** Android implementation of the UniversalBleServer plugin. */
class UniversalBleServerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var writeChannel: EventChannel
  private lateinit var readChannel: EventChannel
  private var writeSink: EventChannel.EventSink? = null
  private var readSink: EventChannel.EventSink? = null

  private var context: Context? = null
  private var bluetoothManager: BluetoothManager? = null
  private var gattServer: BluetoothGattServer? = null
  private var advertiser: BluetoothLeAdvertiser? = null
  private val devices = CopyOnWriteArraySet<BluetoothDevice>()
  private val characteristics = HashMap<String, BluetoothGattCharacteristic>()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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

    bluetoothManager = context?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    advertiser = bluetoothManager?.adapter?.bluetoothLeAdvertiser
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    stopServer()
    channel.setMethodCallHandler(null)
    writeChannel.setStreamHandler(null)
    readChannel.setStreamHandler(null)
    context = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "startServer" -> {
        val args = call.arguments as? Map<*, *> ?: run {
          result.error("bad_args", null, null)
          return
        }
        val serviceUuid = args["serviceUuid"] as? String ?: return
        val chars = (args["characteristics"] as? List<*>)?.mapNotNull { it as? Map<*, *> } ?: emptyList()
        startServer(serviceUuid, chars)
        result.success(null)
      }
      "stopServer" -> {
        stopServer()
        result.success(null)
      }
      "notify" -> {
        val args = call.arguments as? Map<*, *> ?: run {
          result.error("bad_args", null, null)
          return
        }
        val uuid = args["characteristicUuid"] as? String ?: return
        val valueList = args["value"] as? List<*>
        val value = valueList?.map { (it as Int).toByte() }?.toByteArray() ?: byteArrayOf()
        notify(uuid, value)
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun startServer(serviceUuid: String, chars: List<Map<*, *>>) {
    val adapter = bluetoothManager?.adapter ?: return
    gattServer = bluetoothManager?.openGattServer(context, gattCallback)
    val service = BluetoothGattService(UUID.fromString(serviceUuid), BluetoothGattService.SERVICE_TYPE_PRIMARY)
    for (c in chars) {
      val uuid = c["uuid"] as? String ?: continue
      val props = c["properties"] as? List<*> ?: continue
      var properties = 0
      var permissions = 0
      if (props.contains("read")) {
        properties = properties or BluetoothGattCharacteristic.PROPERTY_READ
        permissions = permissions or BluetoothGattCharacteristic.PERMISSION_READ
      }
      if (props.contains("write")) {
        properties = properties or BluetoothGattCharacteristic.PROPERTY_WRITE
        permissions = permissions or BluetoothGattCharacteristic.PERMISSION_WRITE
      }
      if (props.contains("notify")) {
        properties = properties or BluetoothGattCharacteristic.PROPERTY_NOTIFY
      }
      val characteristic = BluetoothGattCharacteristic(UUID.fromString(uuid), properties, permissions)
      val value = c["value"] as? List<*>
      if (value != null) {
        characteristic.value = value.map { (it as Int).toByte() }.toByteArray()
      }
      characteristics[uuid] = characteristic
      service.addCharacteristic(characteristic)
    }
    gattServer?.addService(service)
    advertiser?.startAdvertising(
      AdvertiseSettings.Builder().setConnectable(true).setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY).build(),
      AdvertiseData.Builder().addServiceUuid(ParcelUuid(UUID.fromString(serviceUuid))).build(),
      AdvertiseData.Builder().build(),
      advertiseCallback
    )
  }

  private fun stopServer() {
    advertiser?.stopAdvertising(advertiseCallback)
    gattServer?.close()
    gattServer = null
    devices.clear()
    characteristics.clear()
  }

  private fun notify(uuid: String, value: ByteArray) {
    val characteristic = characteristics[uuid] ?: return
    characteristic.value = value
    devices.forEach { device ->
      gattServer?.notifyCharacteristicChanged(device, characteristic, false)
    }
  }

  private val advertiseCallback = object : AdvertiseCallback() {}

  private val gattCallback = object : BluetoothGattServerCallback() {
    override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
      if (newState == BluetoothProfile.STATE_CONNECTED) {
        devices.add(device)
      } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
        devices.remove(device)
      }
    }

    override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
      gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, characteristic.value)
      readSink?.success(mapOf("characteristicUuid" to characteristic.uuid.toString()))
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
      if (responseNeeded) {
        gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
      }
      writeSink?.success(
        mapOf(
          "characteristicUuid" to characteristic.uuid.toString(),
          "value" to value.toList()
        )
      )
    }
  }
}

