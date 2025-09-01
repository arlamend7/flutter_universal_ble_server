#include "include/universal_ble_server/universal_ble_server_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "universal_ble_server_plugin.h"

void UniversalBleServerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  universal_ble_server::UniversalBleServerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
