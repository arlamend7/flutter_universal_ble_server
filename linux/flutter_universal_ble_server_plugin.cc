#include "include/universal_ble_server/flutter_universal_ble_server_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>
#include "ble_central.h"
#include "ble_peripheral.h"


#define FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_universal_ble_server_plugin_get_type(), \
                              FlutterUniversalBleServerPlugin))

struct _FlutterUniversalBleServerPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(FlutterUniversalBleServerPlugin, flutter_universal_ble_server_plugin, g_object_get_type())

static void flutter_universal_ble_server_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(flutter_universal_ble_server_plugin_parent_class)->dispose(object);
}

static void flutter_universal_ble_server_plugin_class_init(FlutterUniversalBleServerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_universal_ble_server_plugin_dispose;
}

static void flutter_universal_ble_server_plugin_init(FlutterUniversalBleServerPlugin* self) {}

void flutter_universal_ble_server_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto messenger = fl_plugin_registrar_get_messenger(registrar);
  register_ble_central(messenger);
  register_ble_peripheral(messenger);
}
