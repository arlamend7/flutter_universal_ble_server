package com.example.universal_ble_server

import android.Manifest
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import java.util.UUID

/** All state and Flutter channel calls are confined to the main thread. */
class UniversalBleServerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
  private lateinit var central: BleCentral
  private lateinit var context: Context
  private lateinit var channel: MethodChannel
  private lateinit var events: EventChannel
  private val main = Handler(Looper.getMainLooper())
  private var activityBinding: ActivityPluginBinding? = null
  private var permissionResult: MethodChannel.Result? = null
  private var sink: EventChannel.EventSink? = null
  private var server: BluetoothGattServer? = null
  private var advertiser: BluetoothLeAdvertiser? = null
  private var advertisingCallback: AdvertiseCallback? = null
  private var startResult: MethodChannel.Result? = null
  private var epoch = 0
  private val characteristics = mutableMapOf<UUID, BluetoothGattCharacteristic>()
  private val values = mutableMapOf<UUID, ByteArray>()
  private val devices = mutableMapOf<String, BluetoothDevice>()
  private val subscribers = mutableMapOf<UUID, MutableSet<String>>()
  private val serviceQueue = java.util.ArrayDeque<BluetoothGattService>()
  private var advertisedUuid: UUID? = null
  private var requestedName: String? = null
  private var originalName: String? = null
  private var renamedTo: String? = null
  private var includeName = false
  private var notifyResult: MethodChannel.Result? = null
  private val notifyQueue = java.util.ArrayDeque<Pair<BluetoothDevice, BluetoothGattCharacteristic>>()
  private var notifyValue = byteArrayOf()
  private val mtus = mutableMapOf<String, Int>()
  private val cccd = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
  private val manager get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
  private val adapter get() = manager.adapter
  private fun authorized(): Boolean = Build.VERSION.SDK_INT < 31 ||
    listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
      .all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
  private fun capabilities(): Map<String, Any> {
    val allowed = authorized()
    val supported = adapter != null && adapter.isMultipleAdvertisementSupported
    val powered = allowed && adapter?.isEnabled == true
    return mapOf("platform" to "android", "peripheral" to supported, "nameSupport" to "adapterName", "connectionEvents" to true,
      "authorized" to allowed, "poweredOn" to powered,
      "reason" to when { !supported -> "BLE advertising is not supported by this adapter"
        !allowed -> "Bluetooth permissions are required"; !powered -> "Bluetooth is off"; else -> "" })
  }
  private val receiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      if (intent?.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) == BluetoothAdapter.STATE_OFF && server != null) {
        emit(mapOf("type" to "error", "message" to "Bluetooth was turned off"))
        stop()
      }
    }
  }
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    central = BleCentral(context, binding.binaryMessenger) { activityBinding?.activity }
    channel = MethodChannel(binding.binaryMessenger, "universal_ble_server/methods")
    channel.setMethodCallHandler(this)
    events = EventChannel(binding.binaryMessenger, "universal_ble_server/events")
    events.setStreamHandler(this)
    if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED)
    else context.registerReceiver(receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    central.dispose()
    stop(); channel.setMethodCallHandler(null); events.setStreamHandler(null)
    context.unregisterReceiver(receiver); sink = null; detachActivity()
  }
  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
  override fun onCancel(arguments: Any?) { sink = null }
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activityBinding = binding; binding.addRequestPermissionsResultListener(this)
  }
  private fun detachActivity() {
    central.detachActivity()
    activityBinding?.removeRequestPermissionsResultListener(this); activityBinding = null
    permissionResult?.error("activity_detached", "Permission request interrupted", null); permissionResult = null
  }
  override fun onDetachedFromActivity() = detachActivity()
  override fun onDetachedFromActivityForConfigChanges() = detachActivity()
  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    if (central.permissionResult(requestCode)) return true
    if (requestCode != 41872) return false
    permissionResult?.success(capabilities()); permissionResult = null; return true
  }
  private fun emit(value: Map<String, Any>) { sink?.success(value) }
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "checkSupport" -> result.success(capabilities())
        "requestPermissions" -> {
          if (authorized()) result.success(capabilities())
          else {
            check(permissionResult == null) { "Permission request already pending" }
            val activity = activityBinding?.activity ?: throw IllegalStateException("A foreground Activity is required")
            permissionResult = result
            if (Build.VERSION.SDK_INT >= 31) activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE), 41872)
          }
        }
        "startServer" -> start(call, result)
        "stopServer" -> { stop(); result.success(null) }
        "setValue", "notify" -> {
          check(server != null && startResult == null) { "Server is not running" }
          val uuid = UUID.fromString(call.argument<String>("characteristicUuid"))
          val ch = characteristics[uuid] ?: throw IllegalArgumentException("Unknown characteristic")
          val bytes = Base64.decode(call.argument<String>("value"), Base64.DEFAULT)
          require(bytes.size <= 512) { "Attribute value exceeds 512 bytes" }
          if (call.method == "setValue") { values[uuid] = bytes; result.success(null) }
          else {
            require(ch.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) { "Notifications are not supported" }
            check(notifyResult == null) { "A notification is already pending" }
            val clientId = call.argument<String>("clientId")
            if (clientId != null) check(subscribers[uuid]?.contains(clientId) == true && devices.containsKey(clientId)) { "Client disconnected or not subscribed" }
            val targets = subscribers[uuid].orEmpty().filter { clientId == null || it == clientId }.mapNotNull { devices[it] }
            require(targets.all { bytes.size <= (mtus[it.address] ?: 23) - 3 }) { "Notification exceeds a subscriber MTU; fragmentation requires a shared protocol" }
            if (targets.isEmpty()) { result.success(null); return }
            notifyResult = result; notifyValue = bytes
            targets.forEach { notifyQueue.add(it to ch) }
            sendNext()
            val current = epoch
            main.postDelayed({
              if (epoch == current && notifyResult === result) {
                // Callback has no operation ID. Close this generation so a late
                // callback cannot accidentally complete a later notification.
                finishNotify("Notification timed out; restart the server")
                emit(mapOf("type" to "error", "message" to "Notification timed out; restart the server"))
                stop()
              }
            }, 8000)
          }
        }
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      if (call.method == "startServer") { if (startResult === result) startResult = null; stop() }
      result.error(if (e is SecurityException) "permission_denied" else "ble_error", e.message, null)
    }
  }
  private fun start(call: MethodCall, result: MethodChannel.Result) {
    check(server == null) { "Server already started" }
    check(authorized()) { "Bluetooth permissions are required" }
    check(adapter?.isEnabled == true && adapter.isMultipleAdvertisementSupported) { "BLE peripheral is unavailable" }
    val services = call.argument<List<Map<String, Any>>>("services") ?: throw IllegalArgumentException("Missing services")
    require(services.isNotEmpty())
    advertisedUuid = UUID.fromString(call.argument<String>("advertisedServiceUuid"))
    for (entry in services) {
      val service = BluetoothGattService(UUID.fromString(entry["uuid"] as String), BluetoothGattService.SERVICE_TYPE_PRIMARY)
      @Suppress("UNCHECKED_CAST") val fields = entry["characteristics"] as List<Map<String, Any>>
      for (field in fields) {
        val uuid = UUID.fromString(field["uuid"] as String)
        require(!characteristics.containsKey(uuid))
        @Suppress("UNCHECKED_CAST") val props = field["properties"] as List<String>
        var properties = 0; var permissions = 0
        if ("read" in props) { properties = properties or BluetoothGattCharacteristic.PROPERTY_READ; permissions = permissions or BluetoothGattCharacteristic.PERMISSION_READ }
        if ("write" in props) { properties = properties or BluetoothGattCharacteristic.PROPERTY_WRITE; permissions = permissions or BluetoothGattCharacteristic.PERMISSION_WRITE }
        if ("notify" in props) properties = properties or BluetoothGattCharacteristic.PROPERTY_NOTIFY
        if (field["security"] == "encryptedReadWrite") {
          permissions = 0
          if ("read" in props) permissions = permissions or BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED
          if ("write" in props) permissions = permissions or BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED
        }
        val ch = BluetoothGattCharacteristic(uuid, properties, permissions)
        if ("notify" in props) {
          ch.addDescriptor(BluetoothGattDescriptor(cccd, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
          subscribers[uuid] = mutableSetOf()
        }
        characteristics[uuid] = ch
        values[uuid] = Base64.decode(field["value"] as String, Base64.DEFAULT)
        service.addCharacteristic(ch)
      }
      serviceQueue.add(service)
    }
    requestedName = call.argument<String>("name")
    includeName = false
    requestedName?.let { name ->
      require(name.isNotBlank() && name.toByteArray(Charsets.UTF_8).size <= 29 && !name.contains('\u0000')) { "Name must contain 1..29 UTF-8 bytes" }
      if (adapter.name == name) includeName = true
      else if (call.argument<Boolean>("allowAndroidAdapterNameChange") == true) {
        originalName = adapter.name
        check(originalName != null) { "Cannot preserve original adapter name" }
        check(adapter.setName(name)) { "Cannot change adapter name" }
        renamedTo = name; includeName = true
      } else {
        check(call.argument<Boolean>("requireAdvertisedName") != true) { "A custom Android name requires allowAndroidAdapterNameChange" }
        emit(mapOf("type" to "warning", "code" to "name_not_advertised", "message" to "Custom Android name was not advertised: adapter renaming was not permitted"))
      }
    }
    val current = ++epoch
    server = manager.openGattServer(context, callback(current)) ?: throw IllegalStateException("Cannot open GATT server")
    // Assign only after synchronous operations that can throw, to complete result once.
    startResult = result
    if (!server!!.addService(serviceQueue.removeFirst())) failStart("Cannot register service")
    main.postDelayed({ if (epoch == current && startResult != null) failStart("Server startup timed out") }, 15000)
  }
  private fun failStart(message: String) { val result = startResult; startResult = null; stop(); result?.error("start_failed", message, null) }
  private fun advertise(current: Int) {
    advertiser = adapter?.bluetoothLeAdvertiser
    if (advertiser == null) { failStart("BLE advertiser unavailable"); return }
    advertisingCallback = object : AdvertiseCallback() {
      override fun onStartSuccess(settings: AdvertiseSettings) { main.post { if (epoch == current) { val r = startResult; startResult = null; r?.success(null) } } }
      override fun onStartFailure(errorCode: Int) { main.post { if (epoch == current) failStart("Advertising failed: $errorCode") } }
    }
    fun beginWhenNameReady() {
      if (epoch != current || startResult == null) return
      if (includeName && adapter?.name != requestedName) {
        main.postDelayed({ beginWhenNameReady() }, 50)
        return
      }
      try {
        val settings = AdvertiseSettings.Builder().setConnectable(true).setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED).build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(advertisedUuid)).build()
        // Keep the service UUID in the advertisement and name in scan response.
        val scanResponse = AdvertiseData.Builder().setIncludeDeviceName(includeName).build()
        advertiser!!.startAdvertising(settings, data, scanResponse, advertisingCallback)
      } catch (e: Exception) { failStart(e.message ?: "Cannot start advertising") }
    }
    beginWhenNameReady()
  }
  private fun request(data: Map<String, Any>, current: Int, completion: (Int, ByteArray?) -> Unit) {
    var completed = false
    fun finish(status: Int, bytes: ByteArray?) {
      if (completed) return
      completed = true
      if (epoch == current) completion(status, bytes)
    }
    main.postDelayed({ finish(14, null) }, 6000)
    channel.invokeMethod("request", data, object : MethodChannel.Result {
      override fun success(result: Any?) {
        try {
          val map = result as Map<*, *>
          finish((map["status"] as Number).toInt(), (map["value"] as? String)?.let { Base64.decode(it, Base64.DEFAULT) })
        } catch (_: Exception) { finish(14, null) }
      }
      override fun error(code: String, message: String?, details: Any?) = finish(14, null)
      override fun notImplemented() = finish(14, null)
    })
  }
  private fun callback(current: Int) = object : BluetoothGattServerCallback() {
    private fun dispatch(action: () -> Unit) { main.post { if (epoch == current) { try { action() } catch (e: Exception) { emit(mapOf("type" to "error", "message" to (e.message ?: "Bluetooth failure"))); stop() } } } }
    override fun onServiceAdded(status: Int, service: BluetoothGattService) = dispatch {
      if (status != BluetoothGatt.GATT_SUCCESS) failStart("Service registration failed: $status")
      else if (serviceQueue.isNotEmpty()) { if (server?.addService(serviceQueue.removeFirst()) != true) failStart("Cannot register service") }
      else advertise(current)
    }
    override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) = dispatch {
      val id = device.address
      if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
        devices[id] = device; mtus[id] = 23; emit(mapOf("type" to "connected", "clientId" to id, "maxNotificationBytes" to 20))
      } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
        devices.remove(id); mtus.remove(id); subscribers.values.forEach { it.remove(id) }
        if (notifyQueue.any { it.first.address == id }) finishNotify("Subscriber disconnected")
        emit(mapOf("type" to "disconnected", "clientId" to id))
      }
    }
    override fun onMtuChanged(device: BluetoothDevice, mtu: Int) = dispatch {
      mtus[device.address] = mtu
      emit(mapOf("type" to "mtu", "clientId" to device.address, "maxNotificationBytes" to mtu - 3))
    }
    override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) = dispatch {
      val data = mapOf("type" to "read", "uuid" to characteristic.uuid.toString(), "clientId" to device.address, "offset" to offset)
      request(data, current) { status, value ->
        val bytes = value ?: byteArrayOf()
        val code = if (status == 0 && (offset < 0 || offset > bytes.size)) 7 else status
        val part = if (code == 0) bytes.copyOfRange(offset, minOf(bytes.size, offset + (mtus[device.address] ?: 23) - 1)) else null
        server?.sendResponse(device, requestId, code, offset, part)
        if (code == 0) emit(data)
      }
    }
    override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) = dispatch {
      if (preparedWrite || offset != 0 || value.size > 512) {
        if (responseNeeded) server?.sendResponse(device, requestId, if (preparedWrite) 6 else if (offset != 0) 7 else 13, offset, null)
      } else {
        val data = mapOf("type" to "write", "uuid" to characteristic.uuid.toString(), "clientId" to device.address, "offset" to offset, "value" to Base64.encodeToString(value, Base64.NO_WRAP))
        request(data, current) { status, bytes ->
          if (status == 0 && bytes != null) { values[characteristic.uuid] = bytes; emit(data) }
          if (responseNeeded) server?.sendResponse(device, requestId, status, 0, null)
        }
      }
    }
    override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) = dispatch { server?.sendResponse(device, requestId, if (execute) 6 else 0, 0, null) }
    override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) = dispatch {
      val enabled = subscribers[descriptor.characteristic.uuid]?.contains(device.address) == true
      val bytes = if (enabled) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
      server?.sendResponse(device, requestId, if (offset in 0..2) 0 else 7, offset, if (offset in 0..2) bytes.copyOfRange(offset, 2) else null)
    }
    override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) = dispatch {
      val uuid = descriptor.characteristic.uuid
      val valid = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) || value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
      val status = if (preparedWrite) 6 else if (offset != 0) 7 else if (!valid || descriptor.uuid != cccd) 13 else 0
      if (status == 0) {
        val enabled = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        devices[device.address] = device
        if (enabled) subscribers[uuid]?.add(device.address) else subscribers[uuid]?.remove(device.address)
        emit(mapOf("type" to if (enabled) "subscribed" else "unsubscribed", "uuid" to uuid.toString(), "clientId" to device.address, "maxNotificationBytes" to (mtus[device.address] ?: 23) - 3))
      }
      if (responseNeeded) server?.sendResponse(device, requestId, status, offset, null)
    }
    override fun onNotificationSent(device: BluetoothDevice, status: Int) = dispatch {
      if (notifyQueue.peekFirst()?.first?.address == device.address) {
        if (status != BluetoothGatt.GATT_SUCCESS) finishNotify("Notification failed: $status")
        else { notifyQueue.removeFirst(); sendNext() }
      }
    }
  }
  private fun sendNext() {
    val item = notifyQueue.peekFirst()
    if (item == null) { finishNotify(null); return }
    val accepted = if (Build.VERSION.SDK_INT >= 33) server?.notifyCharacteristicChanged(item.first, item.second, false, notifyValue) == BluetoothStatusCodes.SUCCESS
      else { @Suppress("DEPRECATION") item.second.value = notifyValue; @Suppress("DEPRECATION") (server?.notifyCharacteristicChanged(item.first, item.second, false) == true) }
    if (!accepted) finishNotify("Notification was rejected by Bluetooth stack")
  }
  private fun finishNotify(error: String?) {
    val result = notifyResult; notifyResult = null; notifyQueue.clear()
    if (error == null) result?.success(null) else result?.error("notify_failed", error, null)
  }
  private fun stop() {
    epoch++
    val pendingStart = startResult; startResult = null
    pendingStart?.error("cancelled", "Server stopped", null)
    finishNotify("Server stopped")
    try { advertisingCallback?.let { advertiser?.stopAdvertising(it) } } catch (_: SecurityException) {}
    try { server?.close() } catch (_: SecurityException) {}
    try {
      if (renamedTo != null && adapter?.name == renamedTo && originalName != null) {
        if (adapter?.setName(originalName) != true) emit(mapOf("type" to "warning", "message" to "Could not restore the original Bluetooth adapter name"))
      }
    } catch (_: SecurityException) {
      emit(mapOf("type" to "warning", "message" to "Permission revoked before adapter name could be restored"))
    }
    requestedName = null; originalName = null; renamedTo = null; includeName = false
    advertisingCallback = null; advertiser = null; server = null
    characteristics.clear(); values.clear(); subscribers.clear(); devices.clear(); mtus.clear(); serviceQueue.clear()
  }
}
