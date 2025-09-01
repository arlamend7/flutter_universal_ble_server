#ifndef FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_
#define FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <unordered_map>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>

namespace universal_ble_server {

class UniversalBleServerPlugin : public flutter::Plugin {
public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  UniversalBleServerPlugin();

  virtual ~UniversalBleServerPlugin();

  // Disallow copy and assign.
  UniversalBleServerPlugin(const UniversalBleServerPlugin &) = delete;
  UniversalBleServerPlugin &
  operator=(const UniversalBleServerPlugin &) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

private:
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> write_sink_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> read_sink_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      write_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> read_channel_;
  winrt::Windows::Devices::Bluetooth::GenericAttributeProfile::
      GattServiceProvider provider{nullptr};
  std::unordered_map<winrt::guid,
                     winrt::Windows::Devices::Bluetooth::
                         GenericAttributeProfile::GattLocalCharacteristic>
      characteristics;
};

} // namespace universal_ble_server

#endif // FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_
