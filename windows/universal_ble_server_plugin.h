#ifndef FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_
#define FLUTTER_PLUGIN_UNIVERSAL_BLE_SERVER_PLUGIN_H_
#include <flutter/plugin_registrar_windows.h>
#include <memory>
namespace universal_ble_server {
struct BleState;
class UniversalBleServerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  explicit UniversalBleServerPlugin(flutter::PluginRegistrarWindows* registrar);
  ~UniversalBleServerPlugin() override;
  UniversalBleServerPlugin(const UniversalBleServerPlugin&) = delete;
  UniversalBleServerPlugin& operator=(const UniversalBleServerPlugin&) = delete;
 private:
  std::shared_ptr<BleState> state_;
  flutter::PluginRegistrarWindows* registrar_;
  int delegate_id_ = -1;
};
}
#endif
