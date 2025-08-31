#include "universal_ble_server_plugin.h"

#include <windows.devices.bluetooth.genericattributeprofile.h>
#include <flutter/event_channel.h>
#include <flutter/standard_method_codec.h>

using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace flutter;

namespace universal_ble_server {

class WriteStreamHandler : public StreamHandler<EncodableValue> {
 public:
  std::unique_ptr<StreamHandlerError<EncodableValue>> OnListen(
      const EncodableValue* arguments,
      std::unique_ptr<EventSink<EncodableValue>>&& events) override {
    sink_ = std::move(events);
    return nullptr;
  }
  std::unique_ptr<StreamHandlerError<EncodableValue>> OnCancel(
      const EncodableValue* arguments) override {
    sink_ = nullptr;
    return nullptr;
  }
  std::unique_ptr<EventSink<EncodableValue>> sink_;
};

class ReadStreamHandler : public StreamHandler<EncodableValue> {
 public:
  std::unique_ptr<StreamHandlerError<EncodableValue>> OnListen(
      const EncodableValue* arguments,
      std::unique_ptr<EventSink<EncodableValue>>&& events) override {
    sink_ = std::move(events);
    return nullptr;
  }
  std::unique_ptr<StreamHandlerError<EncodableValue>> OnCancel(
      const EncodableValue* arguments) override {
    sink_ = nullptr;
    return nullptr;
  }
  std::unique_ptr<EventSink<EncodableValue>> sink_;
};

std::unique_ptr<WriteStreamHandler> g_write_handler;
std::unique_ptr<ReadStreamHandler> g_read_handler;
GattServiceProvider g_service_provider{nullptr};
std::map<std::string, GattLocalCharacteristic> g_characteristics;

// static
void UniversalBleServerPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<UniversalBleServerPlugin>();

  auto channel = std::make_unique<MethodChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/methods",
      &StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto writeChannel = std::make_unique<EventChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/on_write",
      &StandardMethodCodec::GetInstance());
  g_write_handler = std::make_unique<WriteStreamHandler>();
  writeChannel->SetStreamHandler(std::move(g_write_handler));

  auto readChannel = std::make_unique<EventChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/on_read",
      &StandardMethodCodec::GetInstance());
  g_read_handler = std::make_unique<ReadStreamHandler>();
  readChannel->SetStreamHandler(std::move(g_read_handler));

  registrar->AddPlugin(std::move(plugin));
}

UniversalBleServerPlugin::UniversalBleServerPlugin() {}

UniversalBleServerPlugin::~UniversalBleServerPlugin() {}

void UniversalBleServerPlugin::HandleMethodCall(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (call.method_name() == "startServer") {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (!args) { result->Error("bad_args"); return; }
    auto serviceUuid = std::get<std::string>(args->at(EncodableValue("serviceUuid")));
    auto serviceGuid = winrt::guid(serviceUuid);
    g_service_provider = GattServiceProvider::CreateAsync(serviceGuid).get();
    g_service_provider.StartAdvertising(GattServiceProviderAdvertisingParameters{});
    result->Success();
  } else if (call.method_name() == "stopServer") {
    if (g_service_provider) { g_service_provider.StopAdvertising(); g_service_provider = nullptr; }
    result->Success();
  } else if (call.method_name() == "notify") {
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace universal_ble_server
