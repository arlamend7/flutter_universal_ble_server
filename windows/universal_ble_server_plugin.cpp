#include "universal_ble_server_plugin.h"
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <algorithm>
#include <cctype>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>
#include <windows.h>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>

namespace universal_ble_server {
using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Foundation;
using namespace Windows::Security::Cryptography;
using namespace Windows::Storage::Streams;
using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;
using Result = flutter::MethodResult<EncodableValue>;
using Map = EncodableMap;
constexpr UINT kDispatch = WM_APP + 0x4B1;
static EncodableValue V(const char* s) { return EncodableValue(std::string(s)); }
static const EncodableValue& At(const Map& m, const char* key) { return m.at(V(key)); }
static std::string Str(const Map& m, const char* key) { return std::get<std::string>(At(m, key)); }
static IBuffer Decode(const std::string& s) { return CryptographicBuffer::DecodeFromBase64String(to_hstring(s)); }
static std::string Encode(const IBuffer& b) { return to_string(CryptographicBuffer::EncodeToBase64String(b)); }
static std::string Uuid(guid id) {
  auto s = to_string(to_hstring(id));
  if (s.front() == '{') s = s.substr(1, s.size() - 2);
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return s;
}

struct CentralState;
struct BleState : std::enable_shared_from_this<BleState> {
  std::shared_ptr<CentralState> central;
  HWND window = nullptr;
  std::mutex mutex;
  bool alive = true;
  std::deque<std::function<void()>> tasks;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink;
  int epoch = 0;
  bool running = false;
  std::shared_ptr<Result> start;
  std::vector<GattServiceProvider> providers;
  std::vector<event_token> provider_tokens;
  std::map<std::string, GattLocalCharacteristic> fields;
  std::map<std::string, event_token> read_tokens, write_tokens, subscription_tokens;
  std::map<std::string, IBuffer> values;
  std::set<std::string> advertised;
  std::map<std::string, std::set<std::string>> subscribers;
  void Post(std::function<void()> task) {
    std::lock_guard<std::mutex> guard(mutex);
    if (!alive) return;
    tasks.push_back(std::move(task));
    // The registrar delegate runs on the runner's top-level window, not the
    // Flutter child view. Resolve its parent after runner initialization.
    PostMessage(GetAncestor(window, GA_ROOT), kDispatch, reinterpret_cast<WPARAM>(this), 0);
  }
  void Drain() {
    std::deque<std::function<void()>> ready;
    { std::lock_guard<std::mutex> guard(mutex); ready.swap(tasks); }
    for (auto& task : ready) task();
  }
  void Emit(Map event) { if (sink) sink->Success(EncodableValue(event)); }
  void Stop() {
    ++epoch; running = false;
    if (start) { start->Error("cancelled", "Server stopped"); start.reset(); }
    for (auto& [uuid, field] : fields) {
      try {
        if (read_tokens.count(uuid)) field.ReadRequested(read_tokens[uuid]);
        if (write_tokens.count(uuid)) field.WriteRequested(write_tokens[uuid]);
        if (subscription_tokens.count(uuid)) field.SubscribedClientsChanged(subscription_tokens[uuid]);
      } catch (const hresult_error&) {}
    }
    for (size_t i = 0; i < providers.size(); ++i) {
      try {
        if (i < provider_tokens.size()) providers[i].AdvertisementStatusChanged(provider_tokens[i]);
        providers[i].StopAdvertising();
      } catch (const hresult_error&) {}
    }
    providers.clear(); provider_tokens.clear(); fields.clear(); values.clear();
    read_tokens.clear(); write_tokens.clear(); subscription_tokens.clear(); subscribers.clear(); advertised.clear();
  }
};

static fire_and_forget Deadline(std::weak_ptr<BleState> weak, std::chrono::milliseconds delay, std::function<void()> action) {
  co_await resume_after(delay);
  if (auto state = weak.lock()) state->Post(std::move(action));
}
static fire_and_forget Support(std::shared_ptr<BleState> state, std::shared_ptr<Result> result) {
  try {
    co_await resume_background();
    auto adapter = co_await BluetoothAdapter::GetDefaultAsync();
    const bool supported = adapter && adapter.IsPeripheralRoleSupported();
    bool powered = false;
    bool authorized = false;
    if (adapter) {
      auto radio = co_await adapter.GetRadioAsync();
      authorized = bool(radio);
      powered = radio && radio.State() == Windows::Devices::Radios::RadioState::On;
    }
    state->Post([result, supported, powered, authorized] {
      result->Success(EncodableValue(Map{{V("platform"), V("windows")}, {V("nameSupport"), V("unavailable")}, {V("connectionEvents"), EncodableValue(false)}, {V("peripheral"), EncodableValue(supported)},
        {V("poweredOn"), EncodableValue(powered)}, {V("authorized"), EncodableValue(authorized)},
        {V("reason"), V(!supported ? "Adapter does not support peripheral mode" : !authorized ? "Bluetooth access unavailable" : !powered ? "Bluetooth is off" : "")}}));
    });
  } catch (const hresult_error& e) {
    auto message = to_string(e.message()); state->Post([result, message] { result->Error("unavailable", message); });
  }
}

using Response = std::function<void(uint8_t, IBuffer)>;
static void Request(std::shared_ptr<BleState> state, int epoch, Map args, Response response) {
  auto done = std::make_shared<bool>(false);
  std::weak_ptr<BleState> weak = state;
  auto finish = [weak, epoch, done, response](uint8_t status, IBuffer value) {
    if (*done) return; *done = true;
    auto s = weak.lock();
    // Always release the OS request/deferral, even when the server stopped.
    response(s && s->epoch == epoch ? status : uint8_t(14), value);
  };
  Deadline(weak, std::chrono::seconds(6), [finish] { finish(14, nullptr); });
  state->channel->InvokeMethod("request", std::make_unique<EncodableValue>(args),
    std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
      [finish](const EncodableValue* value) {
        try {
          const auto& map = std::get<Map>(*value);
          const auto status = static_cast<uint8_t>(std::get<int32_t>(At(map, "status")));
          finish(status, status == 0 ? Decode(Str(map, "value")) : nullptr);
        } catch (...) { finish(14, nullptr); }
      }, [finish](const std::string&, const std::string&, const EncodableValue*) { finish(14, nullptr); },
      [finish] { finish(14, nullptr); }));
}
static fire_and_forget Read(std::weak_ptr<BleState> weak, int epoch, std::string uuid, GattReadRequestedEventArgs args) {
  auto deferral = args.GetDeferral();
  try {
    auto request = co_await args.GetRequestAsync();
    if (!request) { deferral.Complete(); co_return; }
    auto state = weak.lock();
    if (!state) { request.RespondWithProtocolError(14); deferral.Complete(); co_return; }
    auto client = to_string(args.Session().DeviceId().Id());
    state->Post([state, epoch, uuid, request, deferral, client] {
      if (state->epoch != epoch || !state->running) { request.RespondWithProtocolError(14); deferral.Complete(); return; }
      Map event{{V("type"), V("read")}, {V("uuid"), EncodableValue(uuid)}, {V("clientId"), EncodableValue(client)}, {V("offset"), EncodableValue(int32_t(request.Offset()))}};
      Request(state, epoch, event, [state, request, deferral, event](uint8_t status, IBuffer bytes) {
        try {
          if (status == 0 && bytes) {
            com_array<uint8_t> data; CryptographicBuffer::CopyToByteArray(bytes, data);
            const auto offset = request.Offset();
            if (offset > data.size()) request.RespondWithProtocolError(7);
            else {
              auto length = (std::min)(uint32_t(data.size() - offset), request.Length());
              request.RespondWithValue(CryptographicBuffer::CreateFromByteArray(array_view<const uint8_t>(data.data() + offset, data.data() + offset + length)));
              state->Emit(event);
            }
          } else request.RespondWithProtocolError(status == 0 ? 14 : status);
        } catch (...) {}
        deferral.Complete();
      });
    });
  } catch (...) { deferral.Complete(); }
}
static fire_and_forget Write(std::weak_ptr<BleState> weak, int epoch, std::string uuid, GattWriteRequestedEventArgs args) {
  auto deferral = args.GetDeferral();
  try {
    auto request = co_await args.GetRequestAsync();
    if (!request) { deferral.Complete(); co_return; }
    auto state = weak.lock();
    if (!state) { deferral.Complete(); co_return; }
    auto client = to_string(args.Session().DeviceId().Id());
    state->Post([state, epoch, uuid, request, deferral, client] {
      if (state->epoch != epoch || !state->running) { request.RespondWithProtocolError(14); deferral.Complete(); return; }
      Map event{{V("type"), V("write")}, {V("uuid"), EncodableValue(uuid)}, {V("clientId"), EncodableValue(client)},
        {V("offset"), EncodableValue(int32_t(request.Offset()))}, {V("value"), EncodableValue(Encode(request.Value()))}};
      Request(state, epoch, event, [state, uuid, request, deferral, event](uint8_t status, IBuffer bytes) {
        try {
          if (status == 0 && bytes) { state->values[uuid] = bytes; state->Emit(event); }
          if (request.Option() == GattWriteOption::WriteWithResponse) {
            if (status == 0) request.Respond(); else request.RespondWithProtocolError(status);
          }
        } catch (...) {}
        deferral.Complete();
      });
    });
  } catch (...) { deferral.Complete(); }
}
static fire_and_forget Start(std::shared_ptr<BleState> state, Map config, int epoch) {
  try {
    co_await resume_background();
    std::vector<GattServiceProvider> providers;
    std::map<std::string, GattLocalCharacteristic> fields;
    std::map<std::string, IBuffer> values;
    if (config.count(V("name")) && config.count(V("requireAdvertisedName")) && std::get<bool>(At(config, "requireAdvertisedName"))) {
      throw hresult_invalid_argument(L"WinRT GATT server does not support a custom advertised local name");
    }
    if (config.count(V("name"))) state->Post([state, epoch] {
      if (state->epoch == epoch) state->Emit(Map{{V("type"), V("warning")}, {V("code"), V("name_not_advertised")}, {V("message"), V("Custom names cannot be advertised on Windows; read NAME after connecting")}});
    });
    const auto& services = std::get<EncodableList>(At(config, "services"));
    if (services.empty()) throw hresult_invalid_argument(L"No services");
    for (const auto& item : services) {
      const auto& service = std::get<Map>(item);
      auto created = co_await GattServiceProvider::CreateAsync(guid(to_hstring(Str(service, "uuid"))));
      if (created.Error() != BluetoothError::Success) throw hresult_error(E_FAIL, L"Cannot create GATT service");
      auto provider = created.ServiceProvider();
      for (const auto& entry : std::get<EncodableList>(At(service, "characteristics"))) {
        const auto& field = std::get<Map>(entry);
        auto uuid = Str(field, "uuid");
        GattLocalCharacteristicParameters parameters;
        GattCharacteristicProperties properties = GattCharacteristicProperties::None;
        for (const auto& prop : std::get<EncodableList>(At(field, "properties"))) {
          auto name = std::get<std::string>(prop);
          if (name == "read") properties = properties | GattCharacteristicProperties::Read;
          if (name == "write") properties = properties | GattCharacteristicProperties::Write;
          if (name == "notify") properties = properties | GattCharacteristicProperties::Notify;
        }
        parameters.CharacteristicProperties(properties);
        auto protection = Str(field, "security") == "encryptedReadWrite" ? GattProtectionLevel::EncryptionRequired : GattProtectionLevel::Plain;
        parameters.ReadProtectionLevel(protection);
        parameters.WriteProtectionLevel(protection);
        auto ch = co_await provider.Service().CreateCharacteristicAsync(guid(to_hstring(uuid)), parameters);
        if (ch.Error() != BluetoothError::Success) throw hresult_error(E_FAIL, L"Cannot create GATT characteristic");
        fields.emplace(uuid, ch.Characteristic()); values.emplace(uuid, Decode(Str(field, "value")));
      }
      providers.push_back(provider);
    }
    auto advertised = Str(config, "advertisedServiceUuid");
    state->Post([state, epoch, providers, fields, values, advertised] {
      if (state->epoch != epoch) return;
      try {
        state->providers = providers; state->fields = fields; state->values = values;
        std::weak_ptr<BleState> weak = state;
        for (const auto& [uuid, field] : fields) {
          state->read_tokens[uuid] = field.ReadRequested([weak, epoch, uuid](auto&&, auto args) { Read(weak, epoch, uuid, args); });
          state->write_tokens[uuid] = field.WriteRequested([weak, epoch, uuid](auto&&, auto args) { Write(weak, epoch, uuid, args); });
          state->subscription_tokens[uuid] = field.SubscribedClientsChanged([weak, epoch, uuid](auto ch, auto&&) {
            if (auto s = weak.lock()) s->Post([s, epoch, uuid, ch] {
              if (s->epoch != epoch) return;
              std::set<std::string> now;
              for (auto client : ch.SubscribedClients()) {
                auto id = to_string(client.Session().DeviceId().Id()); now.insert(id);
                if (!s->subscribers[uuid].count(id)) s->Emit(Map{{V("type"), V("subscribed")}, {V("uuid"), EncodableValue(uuid)}, {V("clientId"), EncodableValue(id)}, {V("maxNotificationBytes"), EncodableValue(int32_t(client.Session().MaxPduSize() - 3))}});
              }
              for (const auto& id : s->subscribers[uuid]) if (!now.count(id)) s->Emit(Map{{V("type"), V("unsubscribed")}, {V("uuid"), EncodableValue(uuid)}, {V("clientId"), EncodableValue(id)}});
              s->subscribers[uuid] = now;
            });
          });
        }
        for (auto provider : providers) {
          auto id = Uuid(provider.Service().Uuid());
          state->provider_tokens.push_back(provider.AdvertisementStatusChanged([weak, epoch, id](auto&&, auto args) {
            if (auto s = weak.lock()) s->Post([s, epoch, id, args] {
              if (s->epoch != epoch) return;
              if (args.Status() == GattServiceProviderAdvertisementStatus::Started) {
                s->advertised.insert(id);
                if (s->advertised.size() == s->providers.size() && s->start) { s->running = true; s->start->Success(); s->start.reset(); }
              } else if (args.Status() == GattServiceProviderAdvertisementStatus::Aborted || args.Status() == GattServiceProviderAdvertisementStatus::Stopped || args.Status() == GattServiceProviderAdvertisementStatus::StartedWithoutAllAdvertisementData) {
                if (s->start) { s->start->Error("start_failed", "Advertising stopped or failed"); s->start.reset(); }
                s->Emit(Map{{V("type"), V("error")}, {V("message"), V("Bluetooth advertising stopped")}}); s->Stop();
              }
            });
          }));
          GattServiceProviderAdvertisingParameters parameters;
          parameters.IsConnectable(true); parameters.IsDiscoverable(id == advertised);
          provider.StartAdvertising(parameters);
        }
      } catch (const hresult_error& e) {
        if (state->start) { state->start->Error("start_failed", to_string(e.message())); state->start.reset(); }
        state->Stop();
      }
    });
  } catch (const hresult_error& e) {
    auto message = to_string(e.message()); state->Post([state, epoch, message] {
      if (state->epoch == epoch && state->start) { state->start->Error("start_failed", message); state->start.reset(); state->Stop(); }
    });
  } catch (const std::exception& e) {
    auto message = std::string(e.what()); state->Post([state, epoch, message] {
      if (state->epoch == epoch && state->start) { state->start->Error("bad_args", message); state->start.reset(); state->Stop(); }
    });
  }
}
static fire_and_forget Notify(std::shared_ptr<BleState> state, GattLocalCharacteristic field, IBuffer value, std::shared_ptr<Result> result, int epoch, std::string clientId) {
  auto done = std::make_shared<bool>(false);
  auto finish = [state, epoch, result, done](const std::string& error) {
    if (*done) return;
    *done = true;
    if (state->epoch != epoch) result->Error("cancelled", "Server stopped");
    else if (error.empty()) result->Success(); else result->Error("notify_failed", error);
  };
  Deadline(state, std::chrono::seconds(8), [finish] { finish("Notification timed out"); });
  try {
    co_await resume_background();
    std::vector<GattSubscribedClient> clients;
    for (auto client : field.SubscribedClients()) {
      if (!clientId.empty() && to_string(client.Session().DeviceId().Id()) != clientId) continue;
      if (value.Length() > uint32_t(client.Session().MaxPduSize() - 3)) throw hresult_invalid_argument(L"Notification exceeds a subscriber MTU");
      clients.push_back(client);
    }
    if (!clientId.empty() && clients.empty()) throw hresult_error(E_FAIL, L"Client disconnected or not subscribed");
    bool success = true;
    for (auto client : clients) {
      auto response = co_await field.NotifyValueAsync(value, client);
      if (response.Status() != GattCommunicationStatus::Success) success = false;
    }
    state->Post([finish, success] { finish(success ? "" : "One or more subscribers could not be notified"); });
  } catch (const hresult_error& e) { auto message = to_string(e.message()); state->Post([finish, message] { finish(message); }); }
}

#include "ble_central.inc"

void UniversalBleServerPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<UniversalBleServerPlugin>(registrar));
}
UniversalBleServerPlugin::UniversalBleServerPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
  state_ = std::make_shared<BleState>();
  auto state = state_; state->window = registrar->GetView()->GetNativeWindow();
  delegate_id_ = registrar->RegisterTopLevelWindowProcDelegate([weak = std::weak_ptr<BleState>(state)](HWND, UINT message, WPARAM target, LPARAM) -> std::optional<LRESULT> {
    if (message != kDispatch) return std::nullopt;
    auto s = weak.lock();
    if (!s || reinterpret_cast<WPARAM>(s.get()) != target) return std::nullopt;
    s->Drain(); return 0;
  });
  state->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(registrar->messenger(), "universal_ble_server/methods", &flutter::StandardMethodCodec::GetInstance());
  state->events = std::make_unique<flutter::EventChannel<EncodableValue>>(registrar->messenger(), "universal_ble_server/events", &flutter::StandardMethodCodec::GetInstance());
  InitCentral(state, registrar->messenger());
  std::weak_ptr<BleState> weak = state;
  state->events->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
    [weak](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> { if (auto s = weak.lock()) s->sink = std::move(sink); return nullptr; },
    [weak](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> { if (auto s = weak.lock()) s->sink.reset(); return nullptr; }));
  state->channel->SetMethodCallHandler([weak](const auto& call, std::unique_ptr<Result> owned) {
    auto s = weak.lock(); if (!s) return;
    std::shared_ptr<Result> result(std::move(owned));
    try {
      if (call.method_name() == "checkSupport" || call.method_name() == "requestPermissions") { Support(s, result); return; }
      if (call.method_name() == "stopServer") { s->Stop(); result->Success(); return; }
      if (call.method_name() == "startServer") {
        if (s->running || s->start) { result->Error("already_running", "Server already started"); return; }
        auto config = std::get<Map>(*call.arguments()); int epoch = ++s->epoch; s->start = result;
        Start(s, config, epoch);
        Deadline(weak, std::chrono::seconds(15), [weak, epoch] { if (auto state = weak.lock(); state && state->epoch == epoch && state->start) {
          state->start->Error("timeout", "Startup timed out"); state->start.reset(); state->Stop();
        }}); return;
      }
      if (call.method_name() == "notify" || call.method_name() == "setValue") {
        if (!s->running) { result->Error("not_running", "Server is not running"); return; }
        const auto& args = std::get<Map>(*call.arguments()); auto uuid = Str(args, "characteristicUuid"); auto value = Decode(Str(args, "value"));
        if (!s->fields.count(uuid) || value.Length() > 512) { result->Error("bad_args", "Unknown characteristic or oversized value"); return; }
        if (call.method_name() == "setValue") { s->values[uuid] = value; result->Success(); }
        else Notify(s, s->fields.at(uuid), value, result, s->epoch, args.count(V("clientId")) ? Str(args, "clientId") : "");
        return;
      }
      result->NotImplemented();
    } catch (const hresult_error& e) { result->Error("ble_error", to_string(e.message())); }
      catch (const std::exception& e) { result->Error("bad_args", e.what()); }
  });
}
UniversalBleServerPlugin::~UniversalBleServerPlugin() {
  state_->central->StopScan(); state_->central->Close();
  state_->central->channel->SetMethodCallHandler(nullptr); state_->central->events->SetStreamHandler(nullptr);
  state_->Stop(); state_->channel->SetMethodCallHandler(nullptr); state_->events->SetStreamHandler(nullptr);
  registrar_->UnregisterTopLevelWindowProcDelegate(delegate_id_);
  std::lock_guard<std::mutex> guard(state_->mutex); state_->alive = false; state_->tasks.clear(); state_->sink.reset();
}
}
