#include "include/flutter_universal_ble_server/flutter_universal_ble_server_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_universal_ble_server_plugin.h"

void FlutterUniversalBleServerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_universal_ble_server::FlutterUniversalBleServerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
