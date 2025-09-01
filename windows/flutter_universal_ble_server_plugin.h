#ifndef FLUTTER_PLUGIN_FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace flutter_universal_ble_server {

class FlutterUniversalBleServerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterUniversalBleServerPlugin();

  virtual ~FlutterUniversalBleServerPlugin();

  // Disallow copy and assign.
  FlutterUniversalBleServerPlugin(const FlutterUniversalBleServerPlugin&) = delete;
  FlutterUniversalBleServerPlugin& operator=(const FlutterUniversalBleServerPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace flutter_universal_ble_server

#endif  // FLUTTER_PLUGIN_FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN_H_
