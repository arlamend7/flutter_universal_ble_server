package com.example.universal_ble_server

import android.Manifest
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import android.util.Base64
import io.flutter.plugin.common.*
import java.util.UUID

/** Direct Android central. A single operation owns GATT until its callback. */
@Suppress("DEPRECATION")
class BleCentral(private val context: Context, messenger: BinaryMessenger,
                 private val activity: () -> Activity?) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private val channel = MethodChannel(messenger, "universal_ble_server/client/methods")
  private val events = EventChannel(messenger, "universal_ble_server/client/events")
  private val main = Handler(Looper.getMainLooper())
  private var sink: EventChannel.EventSink? = null
  private val adapter get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
  private var gatt: BluetoothGatt? = null
  private var operation: String? = null
  private var pending: MethodChannel.Result? = null
  private var permission: MethodChannel.Result? = null
  private var scanning = false
  private var mtu = 23
  private var epoch = 0
  private val found = mutableMapOf<String, BluetoothDevice>()
  private val fields = mutableMapOf<String, BluetoothGattCharacteristic>()
  private fun permissions() = if (Build.VERSION.SDK_INT >= 31)
    arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
  private fun allowed() = Build.VERSION.SDK_INT < 23 || permissions().all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
  private fun state(): String = when {
    adapter == null || !context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) -> "unsupported"
    !allowed() -> "unauthorized"
    !adapter.isEnabled -> "poweredOff"
    else -> "poweredOn"
  }
  private fun emit(data: Map<String, Any>) { sink?.success(data) }
  private val receiver = object: BroadcastReceiver() {
    override fun onReceive(c: Context?, i: Intent?) {
      emit(mapOf("type" to "state", "state" to state()))
      if (state() != "poweredOn") { stopScan(); close(); emit(mapOf("type" to "disconnected")) }
    }
  }
  init {
    channel.setMethodCallHandler(this); events.setStreamHandler(this)
    if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), Context.RECEIVER_EXPORTED)
    else context.registerReceiver(receiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
  }
  override fun onListen(args: Any?, sink: EventChannel.EventSink?) { this.sink = sink }
  override fun onCancel(args: Any?) { sink = null }
  fun permissionResult(code: Int): Boolean {
    if (code != 41873) return false
    permission?.success(state()); permission = null; return true
  }
  fun detachActivity() { permission?.error("permission_denied", "Activity detached", null); permission = null }
  private fun begin(name: String, result: MethodChannel.Result) {
    check(pending == null) { "Operation already pending" }
    operation = name; pending = result
    val generation = epoch
    main.postDelayed({ if (epoch == generation && pending === result) {
      pending = null; operation = null; result.error("timeout", "BLE operation timed out", null)
      close(); emit(mapOf("type" to "disconnected"))
    } }, 10000)
  }
  private fun finish(name: String, status: Int, value: Any? = null) {
    if (operation != name) return
    val result = pending; pending = null; operation = null
    if (status == BluetoothGatt.GATT_SUCCESS) result?.success(value)
    else result?.error("ble_error", "GATT status $status", status)
  }
  private fun key(c: BluetoothGattCharacteristic) = "${c.service.uuid}/${c.uuid}"
  private val scan = object: ScanCallback() {
    override fun onScanResult(type: Int, r: ScanResult) { main.post {
      if (!scanning || (found.size >= 1024 && !found.containsKey(r.device.address))) return@post
      found[r.device.address] = r.device
      val event = mutableMapOf<String, Any>("type" to "discovered", "id" to r.device.address, "rssi" to r.rssi)
      r.scanRecord?.deviceName?.let { event["name"] = it }; emit(event)
    } }
    override fun onScanFailed(code: Int) { main.post { scanning = false; sink?.error("ble_error", "Scan failed: $code", null) } }
  }
  private fun callback(generation: Int) = object: BluetoothGattCallback() {
    private fun run(g: BluetoothGatt, action: () -> Unit) { main.post { if (epoch == generation && g === gatt) action() } }
    override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = run(g) {
      if (newState == BluetoothProfile.STATE_CONNECTED && status == 0) finish("connect", 0)
      else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != 0) {
        close(); emit(mapOf("type" to "disconnected"))
      }
    }
    override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = run(g) {
      fields.clear()
      if (g.services.flatMap { it.characteristics }.map { key(it) }.let { it.size != it.toSet().size }) {
        finish("discover", BluetoothGatt.GATT_FAILURE); return@run
      }
      val list = g.services.flatMap { s -> s.characteristics.map { c ->
        fields[key(c)] = c
        val access = mutableListOf<String>()
        if (c.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) access.add("read")
        if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) access.add("write")
        if (c.properties and (BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) access.add("notify")
        mapOf("service" to s.uuid.toString(), "uuid" to c.uuid.toString(), "access" to access)
      } }
      finish("discover", status, list)
    }
    override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = run(g) {
      finish("read", status, Base64.encodeToString(c.value ?: byteArrayOf(), Base64.NO_WRAP))
    }
    override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) = run(g) {
      finish("read", status, Base64.encodeToString(value, Base64.NO_WRAP))
    }
    override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = run(g) { finish("write", status) }
    override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) = run(g) { finish("subscribe", status) }
    override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) = run(g) { if (status == 0) mtu = value }
    override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) = run(g) {
      emit(mapOf("type" to "notification", "key" to key(c), "value" to Base64.encodeToString(c.value ?: byteArrayOf(), Base64.NO_WRAP)))
    }
    override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) = run(g) {
      emit(mapOf("type" to "notification", "key" to key(c), "value" to Base64.encodeToString(value, Base64.NO_WRAP)))
    }
  }
  private fun stopScan() {
    try { if (scanning) adapter?.bluetoothLeScanner?.stopScan(scan) } catch (_: SecurityException) { }
    scanning = false
  }
  private fun close() {
    epoch++; pending?.error("disconnected", "Connection closed", null); pending = null; operation = null
    try { gatt?.disconnect() } catch (_: SecurityException) { }
    gatt?.close(); gatt = null; fields.clear(); mtu = 23
  }
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "checkSupport" -> result.success(state())
        "requestPermissions" -> {
          if (allowed()) result.success(state()) else {
            check(permission == null)
            val host = activity() ?: throw IllegalStateException("Foreground Activity required")
            permission = result; host.requestPermissions(permissions(), 41873)
          }
        }
        "stopScan" -> { stopScan(); result.success(null) }
        "disconnect" -> { close(); result.success(null) }
        "dispose" -> { stopScan(); close(); result.success(null) }
        else -> {
          if (!allowed()) { result.error("permission_denied", "Bluetooth permissions required", null); return }
          if (adapter?.isEnabled != true) { result.error("bluetooth_off", "Enable Bluetooth", null); return }
          when (call.method) {
            "startScan" -> {
              stopScan(); found.clear()
              val filters = call.argument<List<String>>("services").orEmpty().map { ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(it))).build() }
              scanning = true
              adapter.bluetoothLeScanner.startScan(filters, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scan)
              result.success(null)
            }
            "connect" -> {
              check(gatt == null) { "Disconnect first" }
              val device = found[call.argument<String>("id")] ?: throw IllegalArgumentException("Scan before connect")
              begin("connect", result)
              gatt = if (Build.VERSION.SDK_INT >= 23) device.connectGatt(context, false, callback(epoch), BluetoothDevice.TRANSPORT_LE)
                else device.connectGatt(context, false, callback(epoch))
            }
            "maximumWriteBytes" -> result.success(mtu - 3)
            "discover" -> { begin("discover", result); check(gatt?.discoverServices() == true) }
            "read", "write", "subscribe" -> {
              val g = gatt ?: throw IllegalStateException("Disconnected")
              val c = fields[call.argument<String>("key")] ?: throw IllegalArgumentException("Characteristic missing")
              begin(call.method, result)
              when(call.method) {
                "read" -> check(g.readCharacteristic(c))
                "write" -> {
                  val bytes = Base64.decode(call.argument<String>("value"), Base64.DEFAULT)
                  require(bytes.size <= mtu - 3)
                  c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; c.value = bytes
                  check(g.writeCharacteristic(c))
                }
                "subscribe" -> {
                  val enabled = call.argument<Boolean>("enabled") == true
                  check(g.setCharacteristicNotification(c, enabled))
                  val d = c.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")) ?: throw IllegalArgumentException("CCCD missing")
                  d.value = if (!enabled) BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                    else if (c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
                  check(g.writeDescriptor(d))
                }
              }
            }
            else -> result.notImplemented()
          }
        }
      }
    } catch (e: Exception) {
      if (pending === result) { pending = null; operation = null }
      result.error(if (e is SecurityException) "permission_denied" else "ble_error", e.message, null)
    }
  }
  fun dispose() {
    stopScan(); close(); detachActivity(); context.unregisterReceiver(receiver)
    channel.setMethodCallHandler(null); events.setStreamHandler(null); sink = null
  }
}
