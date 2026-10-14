#include "include/universal_ble_server/flutter_universal_ble_server_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>
#include "ble_central.h"


#define FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_universal_ble_server_plugin_get_type(), \
                              FlutterUniversalBleServerPlugin))

struct _FlutterUniversalBleServerPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(FlutterUniversalBleServerPlugin, flutter_universal_ble_server_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void flutter_universal_ble_server_plugin_handle_method_call(
    FlutterUniversalBleServerPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "checkSupport") == 0 || strcmp(method, "requestPermissions") == 0) {
    g_autoptr(FlValue) value = fl_value_new_map();
    fl_value_set_string_take(value, "platform", fl_value_new_string("linux"));
    fl_value_set_string_take(value, "peripheral", fl_value_new_bool(false));
    fl_value_set_string_take(value, "poweredOn", fl_value_new_bool(false));
    fl_value_set_string_take(value, "authorized", fl_value_new_bool(false));
    fl_value_set_string_take(value, "reason", fl_value_new_string("Linux BlueZ peripheral backend is not implemented"));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  } else if (strcmp(method, "stopServer") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new("unsupported", "Linux peripheral backend is not implemented", nullptr));
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void flutter_universal_ble_server_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(flutter_universal_ble_server_plugin_parent_class)->dispose(object);
}

static void flutter_universal_ble_server_plugin_class_init(FlutterUniversalBleServerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_universal_ble_server_plugin_dispose;
}

static void flutter_universal_ble_server_plugin_init(FlutterUniversalBleServerPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  FlutterUniversalBleServerPlugin* plugin = FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN(user_data);
  flutter_universal_ble_server_plugin_handle_method_call(plugin, method_call);
}

void flutter_universal_ble_server_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  register_ble_central(fl_plugin_registrar_get_messenger(registrar));
  FlutterUniversalBleServerPlugin* plugin = FLUTTER_UNIVERSAL_BLE_SERVER_PLUGIN(
      g_object_new(flutter_universal_ble_server_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "universal_ble_server/methods",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
