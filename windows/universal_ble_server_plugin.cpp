#include "universal_ble_server_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Security.Cryptography.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <unordered_map>

namespace universal_ble_server {

// static
void UniversalBleServerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "universal_ble_server/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<UniversalBleServerPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  plugin->write_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "universal_ble_server/onWrite", &flutter::StandardMethodCodec::GetInstance());
  auto write_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_pointer](const flutter::EncodableValue*, std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink) {
        plugin_pointer->write_sink_ = std::move(sink);
        return nullptr;
      },
      [plugin_pointer](const flutter::EncodableValue*) {
        plugin_pointer->write_sink_.reset();
        return nullptr;
      });
  plugin->write_channel_->SetStreamHandler(std::move(write_handler));

  plugin->read_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "universal_ble_server/onRead", &flutter::StandardMethodCodec::GetInstance());
  auto read_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_pointer](const flutter::EncodableValue*, std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink) {
        plugin_pointer->read_sink_ = std::move(sink);
        return nullptr;
      },
      [plugin_pointer](const flutter::EncodableValue*) {
        plugin_pointer->read_sink_.reset();
        return nullptr;
      });
  plugin->read_channel_->SetStreamHandler(std::move(read_handler));

  registrar->AddPlugin(std::move(plugin));
}

using namespace winrt;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;

UniversalBleServerPlugin::UniversalBleServerPlugin() {}

UniversalBleServerPlugin::~UniversalBleServerPlugin() {}

void UniversalBleServerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& args = method_call.arguments() ? *method_call.arguments() : flutter::EncodableValue();
  if (method_call.method_name().compare("startServer") == 0) {
    if (const auto* map = std::get_if<flutter::EncodableMap>(&args)) {
      auto service_uuid = winrt::guid(std::get<std::string>((*map).at(flutter::EncodableValue("serviceUuid"))));
      auto provider_result = GattServiceProvider::CreateAsync(service_uuid).get();
      provider = provider_result.ServiceProvider();
      auto service = provider.Service();
      characteristics.clear();
      if (auto* list = std::get_if<flutter::EncodableList>(&(*map).at(flutter::EncodableValue("characteristics")))) {
        for (auto& item : *list) {
          auto charMap = std::get<flutter::EncodableMap>(item);
          auto cuuid = winrt::guid(std::get<std::string>(charMap[flutter::EncodableValue("uuid")]));
          auto propsList = std::get<flutter::EncodableList>(charMap[flutter::EncodableValue("properties")]);
          auto params = GattLocalCharacteristicParameters();
          GattCharacteristicProperties props = GattCharacteristicProperties::None;
          for (auto& p : propsList) {
            auto name = std::get<std::string>(p);
            if (name == "read") props |= GattCharacteristicProperties::Read;
            if (name == "write") props |= GattCharacteristicProperties::Write;
            if (name == "notify") props |= GattCharacteristicProperties::Notify;
          }
          params.CharacteristicProperties(props);
          auto valueB64 = std::get<std::string>(charMap[flutter::EncodableValue("value")]);
          if (!valueB64.empty()) {
            auto buffer = Windows::Security::Cryptography::CryptographicBuffer::DecodeFromBase64String(winrt::to_hstring(valueB64));
            params.StaticValue(buffer);
          }
          auto createRes = service.CreateCharacteristicAsync(cuuid, params).get();
          auto ch = createRes.Characteristic();
          ch.WriteRequested([&](auto&&, GattWriteRequestedEventArgs args) {
            auto deferral = args.GetDeferral();
            auto request = args.GetRequestAsync().get();
            auto reader = DataReader::FromBuffer(request.Value());
            std::vector<uint8_t> data(reader.UnconsumedBufferLength());
            reader.ReadBytes(data);
            if (write_sink_) {
              flutter::EncodableMap evt{
                {flutter::EncodableValue("uuid"), flutter::EncodableValue(winrt::to_string(cuuid))},
                {flutter::EncodableValue("value"), flutter::EncodableValue(std::string((char*)data.data(), data.size()))}
              };
              write_sink_->Success(evt);
            }
            deferral.Complete();
          });
          ch.ReadRequested([&](auto&&, GattReadRequestedEventArgs args) {
            if (read_sink_) {
              flutter::EncodableMap evt{{flutter::EncodableValue("uuid"), flutter::EncodableValue(winrt::to_string(cuuid))}};
              read_sink_->Success(evt);
            }
          });
          characteristics[cuuid] = ch;
        }
      }
      provider.StartAdvertising();
      result->Success();
      return;
    }
    result->Error("args", "Invalid arguments");
  } else if (method_call.method_name().compare("stopServer") == 0) {
    if (provider) {
      provider.StopAdvertising();
      provider = nullptr;
      characteristics.clear();
    }
    result->Success();
  } else if (method_call.method_name().compare("notify") == 0) {
    if (const auto* map = std::get_if<flutter::EncodableMap>(&args)) {
      auto cuuid = winrt::guid(std::get<std::string>(map->at(flutter::EncodableValue("characteristicUuid"))));
      auto valueStr = std::get<std::string>(map->at(flutter::EncodableValue("value")));
      if (characteristics.count(cuuid)) {
        auto ch = characteristics[cuuid];
        auto buffer = Windows::Security::Cryptography::CryptographicBuffer::DecodeFromBase64String(winrt::to_hstring(valueStr));
        ch.NotifyValueAsync(buffer);
      }
      result->Success();
    } else {
      result->Error("args", "Invalid arguments");
    }
  } else {
    result->NotImplemented();
  }
}

}  // namespace universal_ble_server
