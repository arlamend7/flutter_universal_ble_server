#ifndef FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_
#define FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>

namespace universal_ble_server {

class UniversalBleServerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  UniversalBleServerPlugin();
  virtual ~UniversalBleServerPlugin();

 private:
  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue> &call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace universal_ble_server

#endif  // FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_
