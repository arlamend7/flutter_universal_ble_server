// Included in the plugin namespace; uses WinRT directly and the UI dispatcher.
struct CentralState {
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink;
  Windows::Devices::Bluetooth::Advertisement::BluetoothLEAdvertisementWatcher watcher{nullptr};
  event_token scan_token{}, connection_token{};
  BluetoothLEDevice device{nullptr};
  std::vector<GattDeviceService> services;
  std::map<std::string, GattCharacteristic> fields;
  std::map<std::string, event_token> notify_tokens;
  std::set<uint64_t> discovered;
  int epoch = 0;
  bool busy = false;
  void Emit(Map map) { if (sink) sink->Success(EncodableValue(map)); }
  void StopScan() {
    if (watcher) { watcher.Received(scan_token); watcher.Stop(); watcher = nullptr; }
  }
  void Close() {
    ++epoch; busy = false;
    for (auto& [key, token] : notify_tokens) { try { fields.at(key).ValueChanged(token); } catch (...) {} }
    notify_tokens.clear(); fields.clear();
    for (auto& s : services) { try { s.Close(); } catch (...) {} }
    services.clear();
    if (device) { try { device.ConnectionStatusChanged(connection_token); device.Close(); } catch (...) {} device = nullptr; }
  }
};
using CentralDone = std::function<void(EncodableValue, std::string, std::string)>;
static fire_and_forget CentralCall(std::shared_ptr<BleState> host, std::shared_ptr<CentralState> c,
    std::string method, Map args, CentralDone done, int epoch) {
  // Snapshot WinRT handles on the UI thread before awaiting background work.
  auto device = c->device;
  auto fields = c->fields;
  try {
    co_await resume_background();
    if (method == "checkSupport" || method == "requestPermissions") {
      auto adapter = co_await BluetoothAdapter::GetDefaultAsync();
      std::string status = "unsupported";
      if (adapter && adapter.IsCentralRoleSupported()) {
        auto radio = co_await adapter.GetRadioAsync();
        status = !radio ? "unauthorized" : radio.State() == Windows::Devices::Radios::RadioState::On ? "poweredOn" : "poweredOff";
      }
      host->Post([done, status] { done(EncodableValue(status), "", ""); }); co_return;
    }
    if (method == "connect") {
      auto address = std::stoull(Str(args, "id"));
      auto connected = co_await BluetoothLEDevice::FromBluetoothAddressAsync(address);
      if (!connected) throw hresult_error(E_ACCESSDENIED, L"Device unavailable or access denied");
      host->Post([host, c, connected, epoch, done] {
        if (c->epoch != epoch) { connected.Close(); done({}, "disconnected", "Connection changed"); return; }
        c->device = connected;
        c->connection_token = connected.ConnectionStatusChanged([weak = std::weak_ptr<BleState>(host), weakc = std::weak_ptr<CentralState>(c), epoch](auto sender, auto) {
          if (sender.ConnectionStatus() != BluetoothConnectionStatus::Disconnected) return;
          if (auto h = weak.lock()) h->Post([weakc, epoch] { if (auto cc = weakc.lock(); cc && cc->epoch == epoch) { cc->Close(); cc->Emit(Map{{V("type"), V("disconnected")}}); } });
        });
        done({}, "", "");
      }); co_return;
    }
    if (!device) throw hresult_error(E_FAIL, L"No connected device");
    if (method == "discover") {
      auto response = co_await device.GetGattServicesAsync(BluetoothCacheMode::Uncached);
      if (response.Status() != GattCommunicationStatus::Success) throw hresult_error(E_FAIL, L"Service discovery failed");
      std::vector<GattDeviceService> services;
      std::map<std::string, GattCharacteristic> discovered;
      EncodableList list;
      for (auto service : response.Services()) {
        services.push_back(service);
        auto chars = co_await service.GetCharacteristicsAsync(BluetoothCacheMode::Uncached);
        if (chars.Status() != GattCommunicationStatus::Success) throw hresult_error(E_FAIL, L"Characteristic discovery failed");
        for (auto ch : chars.Characteristics()) {
          auto service_id = Uuid(service.Uuid()), uuid = Uuid(ch.Uuid()), key = service_id + "/" + uuid;
          if (discovered.count(key)) throw hresult_invalid_argument(L"Ambiguous characteristic");
          discovered.emplace(key, ch);
          EncodableList access;
          auto props = ch.CharacteristicProperties();
          if ((props & GattCharacteristicProperties::Read) != GattCharacteristicProperties::None) access.push_back(V("read"));
          if ((props & GattCharacteristicProperties::Write) != GattCharacteristicProperties::None) access.push_back(V("write"));
          if ((props & (GattCharacteristicProperties::Notify | GattCharacteristicProperties::Indicate)) != GattCharacteristicProperties::None) access.push_back(V("notify"));
          list.emplace_back(Map{{V("service"), EncodableValue(service_id)}, {V("uuid"), EncodableValue(uuid)}, {V("access"), EncodableValue(access)}});
        }
      }
      host->Post([c, services, discovered, list, done, epoch] {
        if (c->epoch != epoch) { for (auto s : services) s.Close(); done({}, "disconnected", "Connection changed"); return; }
        c->services = services; c->fields = discovered; done(EncodableValue(list), "", "");
      }); co_return;
    }
    if (method == "maximumWriteBytes") {
      auto session = co_await GattSession::FromDeviceIdAsync(device.BluetoothDeviceId());
      auto size = session ? int32_t(session.MaxPduSize() - 3) : 20;
      host->Post([done, size] { done(EncodableValue(size), "", ""); }); co_return;
    }
    auto key = Str(args, "key");
    auto field = fields.at(key);
    if (method == "read") {
      auto response = co_await field.ReadValueAsync(BluetoothCacheMode::Uncached);
      if (response.Status() != GattCommunicationStatus::Success) throw hresult_error(E_FAIL, L"Read failed");
      auto value = Encode(response.Value());
      host->Post([done, value] { done(EncodableValue(value), "", ""); });
    } else if (method == "write") {
      auto status = co_await field.WriteValueAsync(Decode(Str(args, "value")), GattWriteOption::WriteWithResponse);
      if (status != GattCommunicationStatus::Success) throw hresult_error(E_FAIL, L"Write failed");
      host->Post([done] { done({}, "", ""); });
    } else if (method == "subscribe") {
      bool enabled = std::get<bool>(At(args, "enabled"));
      event_token token{};
      if (enabled) token = field.ValueChanged([weak = std::weak_ptr<BleState>(host), weakc = std::weak_ptr<CentralState>(c), epoch, key](auto, auto args) {
        auto value = Encode(args.CharacteristicValue());
        if (auto h = weak.lock()) h->Post([weakc, epoch, key, value] {
          if (auto cc = weakc.lock(); cc && cc->epoch == epoch) cc->Emit(Map{{V("type"), V("notification")}, {V("key"), EncodableValue(key)}, {V("value"), EncodableValue(value)}});
        });
      });
      auto mode = !enabled ? GattClientCharacteristicConfigurationDescriptorValue::None :
        (field.CharacteristicProperties() & GattCharacteristicProperties::Notify) != GattCharacteristicProperties::None ?
          GattClientCharacteristicConfigurationDescriptorValue::Notify : GattClientCharacteristicConfigurationDescriptorValue::Indicate;
      GattCommunicationStatus status;
      try { status = co_await field.WriteClientCharacteristicConfigurationDescriptorAsync(mode); }
      catch (...) { if (enabled) field.ValueChanged(token); throw; }
      if (status != GattCommunicationStatus::Success) { if (enabled) field.ValueChanged(token); throw hresult_error(E_FAIL, L"Subscription failed"); }
      host->Post([c, field, token, enabled, key, done, epoch] {
        if (c->epoch != epoch) { if (enabled) field.ValueChanged(token); done({}, "disconnected", "Connection changed"); return; }
        if (c->notify_tokens.count(key)) { field.ValueChanged(c->notify_tokens[key]); c->notify_tokens.erase(key); }
        if (enabled) c->notify_tokens[key] = token;
        done({}, "", "");
      });
    } else { host->Post([done] { done({}, "unsupported", "Unknown operation"); }); }
  } catch (const hresult_error& e) {
    auto message = to_string(e.message()); auto code = e.code() == E_ACCESSDENIED ? "permission_denied" : "ble_error";
    host->Post([done, message, code] { done({}, code, message); });
  } catch (const std::exception& e) {
    auto message = std::string(e.what()); host->Post([done, message] { done({}, "ble_error", message); });
  }
}
static void InitCentral(std::shared_ptr<BleState> host, flutter::BinaryMessenger* messenger) {
  auto c = std::make_shared<CentralState>(); host->central = c;
  c->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "universal_ble_server/client/methods", &flutter::StandardMethodCodec::GetInstance());
  c->events = std::make_unique<flutter::EventChannel<EncodableValue>>(messenger, "universal_ble_server/client/events", &flutter::StandardMethodCodec::GetInstance());
  std::weak_ptr<CentralState> weakc = c; std::weak_ptr<BleState> weak = host;
  c->events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
    [weakc](auto, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> { if (auto s = weakc.lock()) s->sink = std::move(sink); return nullptr; },
    [weakc](auto) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> { if (auto s = weakc.lock()) s->sink.reset(); return nullptr; }));
  c->channel->SetMethodCallHandler([weak, weakc](const auto& call, std::unique_ptr<Result> owned) {
    auto h = weak.lock(); auto cc = weakc.lock(); if (!h || !cc) return;
    std::shared_ptr<Result> result(std::move(owned));
    try {
      auto method = call.method_name();
      Map args = call.arguments() && std::holds_alternative<Map>(*call.arguments()) ? std::get<Map>(*call.arguments()) : Map{};
      if (method == "stopScan") { cc->StopScan(); result->Success(); return; }
      if (method == "disconnect" || method == "dispose") { cc->Close(); if (method == "dispose") cc->StopScan(); result->Success(); return; }
      if (method == "startScan") {
        using namespace Windows::Devices::Bluetooth::Advertisement;
        cc->StopScan(); cc->discovered.clear();
        cc->watcher = BluetoothLEAdvertisementWatcher(); cc->watcher.ScanningMode(BluetoothLEScanningMode::Active);
        for (const auto& id : std::get<EncodableList>(At(args, "services"))) cc->watcher.AdvertisementFilter().Advertisement().ServiceUuids().Append(guid(to_hstring(std::get<std::string>(id))));
        cc->scan_token = cc->watcher.Received([weak, weakc](auto, auto event) {
          auto address = event.BluetoothAddress(); auto name = to_string(event.Advertisement().LocalName()); auto rssi = int32_t(event.RawSignalStrengthInDBm());
          if (auto h = weak.lock()) h->Post([weakc, address, name, rssi] {
            if (auto c = weakc.lock(); c && c->watcher) {
              if (c->discovered.size() >= 1024 && !c->discovered.count(address)) return;
              c->discovered.insert(address);
              c->Emit(Map{{V("type"), V("discovered")}, {V("id"), EncodableValue(std::to_string(address))}, {V("name"), EncodableValue(name)}, {V("rssi"), EncodableValue(rssi)}});
            }
          });
        });
        cc->watcher.Start(); result->Success(); return;
      }
      if (cc->busy) { result->Error("busy", "Operation pending"); return; }
      if (method == "connect" && !cc->discovered.count(std::stoull(Str(args, "id")))) { result->Error("ble_error", "Scan first"); return; }
      cc->busy = true; const int epoch = cc->epoch; auto completed = std::make_shared<bool>(false);
      CentralDone done = [cc, completed, epoch, result](EncodableValue value, std::string code, std::string message) {
        if (*completed) return; *completed = true;
        if (cc->epoch != epoch) { result->Error("disconnected", "Connection changed"); return; }
        cc->busy = false;
        if (code.empty()) result->Success(value); else result->Error(code, message);
      };
      Deadline(h, std::chrono::seconds(10), [cc, done, completed, epoch] {
        if (!*completed) { done({}, "timeout", "BLE operation timed out"); if (cc->epoch == epoch) cc->Close(); }
      });
      CentralCall(h, cc, method, args, done, epoch);
    } catch (const hresult_error& e) { result->Error("ble_error", to_string(e.message())); }
      catch (const std::exception& e) { result->Error("ble_error", e.what()); }
  });
}
