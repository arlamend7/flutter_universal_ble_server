#include "universal_ble_server_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Foundation.h>

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace flutter;

namespace universal_ble_server {

// ---- Globais ----
std::unique_ptr<EventSink<EncodableValue>> g_write_sink;
std::unique_ptr<EventSink<EncodableValue>> g_read_sink;
GattServiceProvider g_service_provider{nullptr};
std::map<std::string, GattLocalCharacteristic> g_characteristics;

// ---- StreamHandler custom ----
class SimpleStreamHandler : public StreamHandler<EncodableValue> {
public:
  SimpleStreamHandler(std::unique_ptr<EventSink<EncodableValue>> *sink)
      : sink_(sink) {}

protected:
  std::unique_ptr<StreamHandlerError<EncodableValue>> OnListenInternal(
      const EncodableValue *arguments,
      std::unique_ptr<EventSink<EncodableValue>> &&events) override {
    *sink_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<StreamHandlerError<EncodableValue>>
  OnCancelInternal(const EncodableValue *arguments) override {
    sink_->reset();
    return nullptr;
  }

private:
  std::unique_ptr<EventSink<EncodableValue>> *sink_;
};

// ---- Registrar plugin ----
void UniversalBleServerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto plugin = std::make_unique<UniversalBleServerPlugin>();

  // Method channel
  auto channel = std::make_unique<MethodChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/methods",
      &StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  // Event channel (on_write)
  auto writeChannel = std::make_unique<EventChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/onWrite",
      &StandardMethodCodec::GetInstance());
  writeChannel->SetStreamHandler(
      std::make_unique<SimpleStreamHandler>(&g_write_sink));

  // Event channel (on_read)
  auto readChannel = std::make_unique<EventChannel<EncodableValue>>(
      registrar->messenger(), "universal_ble_server/onRead",
      &StandardMethodCodec::GetInstance());
  readChannel->SetStreamHandler(
      std::make_unique<SimpleStreamHandler>(&g_read_sink));

  registrar->AddPlugin(std::move(plugin));
}

// ---- Construtores ----
UniversalBleServerPlugin::UniversalBleServerPlugin() {}
UniversalBleServerPlugin::~UniversalBleServerPlugin() {}

// ---- Métodos ----
void UniversalBleServerPlugin::HandleMethodCall(
    const MethodCall<EncodableValue> &call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (call.method_name() == "startServer") {
    const auto *args = std::get_if<EncodableMap>(call.arguments());
    if (!args) {
      result->Error("bad_args");
      return;
    }

    auto serviceUuid =
        std::get<std::string>(args->at(EncodableValue("serviceUuid")));
    auto serviceGuid = winrt::guid(serviceUuid);

    auto op = GattServiceProvider::CreateAsync(serviceGuid);
    op.Completed([result = std::move(result)](auto &&op, auto status) mutable {
      if (status != AsyncStatus::Completed) {
        result->Error("gatt_error", "Failed to create GattServiceProvider");
        return;
      }
      auto provider_result = op.GetResults();
      if (provider_result.Error() != BluetoothError::Success) {
        result->Error("gatt_error", "Failed to create GattServiceProvider");
        return;
      }

      g_service_provider = provider_result.ServiceProvider();
      g_service_provider.StartAdvertising(
          GattServiceProviderAdvertisingParameters{});

      result->Success();
    });

  } else if (call.method_name() == "stopServer") {
    if (g_service_provider) {
      g_service_provider.StopAdvertising();
      g_service_provider = nullptr;
    }
    result->Success();

  } else if (call.method_name() == "notify") {
    // TODO: Implementar notify real
    result->Success();

  } else {
    result->NotImplemented();
  }
}

} // namespace universal_ble_server
