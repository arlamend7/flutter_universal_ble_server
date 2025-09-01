#include "universal_ble_server_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/stream_handler_functions.h>
#include <map>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Foundation.h>

using namespace winrt;
using namespace winrt::Windows::Devices::Bluetooth;
using namespace winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace flutter;

namespace universal_ble_server {

std::unique_ptr<EventSink<EncodableValue>> g_write_sink;
std::unique_ptr<EventSink<EncodableValue>> g_read_sink;
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
  auto write_handler = std::make_unique<StreamHandlerFunctions<EncodableValue>>(
      [](const EncodableValue* arguments,
         std::unique_ptr<EventSink<EncodableValue>>&& events) {
        g_write_sink = std::move(events);
        return nullptr;
      },
      [](const EncodableValue* arguments) {
        g_write_sink.reset();
        return nullptr;
      });
  writeChannel->SetStreamHandler(std::move(write_handler));

  auto readChannel = std::make_unique<EventChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/on_read",
      &StandardMethodCodec::GetInstance());
  auto read_handler = std::make_unique<StreamHandlerFunctions<EncodableValue>>(
      [](const EncodableValue* arguments,
         std::unique_ptr<EventSink<EncodableValue>>&& events) {
        g_read_sink = std::move(events);
        return nullptr;
      },
      [](const EncodableValue* arguments) {
        g_read_sink.reset();
        return nullptr;
      });
  readChannel->SetStreamHandler(std::move(read_handler));

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
    auto provider_result = GattServiceProvider::CreateAsync(serviceGuid).get();
    if (provider_result.Error() != BluetoothError::Success) {
      result->Error("gatt_error", "Failed to create GattServiceProvider");
      return;
    }
    g_service_provider = provider_result.ServiceProvider();
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
