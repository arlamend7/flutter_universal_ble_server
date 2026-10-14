#include "ble_central.h"
#include <gio/gio.h>
#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <deque>
#include <functional>

namespace {
struct Central {
  GDBusConnection* bus = nullptr;
  FlEventChannel* events = nullptr;
  bool listening = false, scanning = false;
  std::map<std::string, GVariant*> device_properties;
  std::deque<std::function<void()>> deferred;
  int jobs = 0;
  GCancellable* active = nullptr;
  GCancellable* worker_cancel = nullptr;
  guint signal = 0;
  std::string adapter, device;
  std::map<std::string, std::string> fields;
  std::vector<std::string> filters;
  std::mutex mutex;
  ~Central() {
    if (bus && signal) g_dbus_connection_signal_unsubscribe(bus, signal);
    for (auto& entry : device_properties) g_variant_unref(entry.second);
    if (active) g_object_unref(active);
    if (events) g_object_unref(events);
    if (bus) g_object_unref(bus);
  }
};
using State = std::shared_ptr<Central>;
static void Set(FlValue* map, const char* key, FlValue* v) { fl_value_set_string_take(map, key, v); }
static GVariant* Call(Central& s, const std::string& path, const char* iface, const char* method, GVariant* args, GError** error) {
  return g_dbus_connection_call_sync(s.bus, "org.bluez", path.c_str(), iface, method, args, nullptr, G_DBUS_CALL_FLAGS_NONE, 5000, s.worker_cancel, error);
}
static std::string String(GVariant* props, const char* key) {
  const gchar* value = nullptr; g_variant_lookup(props, key, "&s", &value);
  return value ? value : "";
}
static std::string Path(GVariant* props, const char* key) {
  const gchar* value = nullptr; g_variant_lookup(props, key, "&o", &value);
  return value ? value : "";
}
static bool Bool(GVariant* props, const char* key) { gboolean value = false; g_variant_lookup(props, key, "b", &value); return value; }
static GVariant* Objects(Central& s, GError** error) {
  g_autoptr(GVariant) reply = Call(s, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", nullptr, error);
  return reply ? g_variant_get_child_value(reply, 0) : nullptr;
}
static void Emit(Central& s, FlValue* event) {
  if (s.listening) fl_event_channel_send(s.events, event, nullptr, nullptr);
}
static void DeviceEvent(Central& s, const std::string& path, GVariant* props) {
  if (!s.scanning) return;
  g_autoptr(GVariant) uuids = g_variant_lookup_value(props, "UUIDs", G_VARIANT_TYPE("as"));
  bool match = s.filters.empty();
  if (uuids) {
    GVariantIter it; const char* id; g_variant_iter_init(&it, uuids);
    while (g_variant_iter_next(&it, "&s", &id)) if (std::find(s.filters.begin(), s.filters.end(), id) != s.filters.end()) match = true;
  }
  if (!match) return;
  g_autoptr(FlValue) e = fl_value_new_map();
  Set(e, "type", fl_value_new_string("discovered")); Set(e, "id", fl_value_new_string(path.c_str()));
  auto name = String(props, "Name"); if (name.empty()) name = String(props, "Alias");
  Set(e, "name", fl_value_new_string(name.c_str()));
  gint16 rssi = 0; if (g_variant_lookup(props, "RSSI", "n", &rssi)) Set(e, "rssi", fl_value_new_int(rssi));
  Emit(s, e);
}
static void RememberDevice(Central& s, const std::string& path, GVariant* props) {
  if (s.device_properties.size() >= 1024 && !s.device_properties.count(path)) return;
  GVariantDict merged;
  g_variant_dict_init(&merged, s.device_properties.count(path) ? s.device_properties[path] : nullptr);
  GVariantIter iter; const char* key; GVariant* value; g_variant_iter_init(&iter, props);
  while (g_variant_iter_next(&iter, "{&sv}", &key, &value)) {
    g_variant_dict_insert_value(&merged, key, value); g_variant_unref(value);
  }
  if (s.device_properties.count(path)) g_variant_unref(s.device_properties[path]);
  s.device_properties[path] = g_variant_ref_sink(g_variant_dict_end(&merged));
  DeviceEvent(s, path, s.device_properties[path]);
}
static void Signal(GDBusConnection*, const gchar*, const gchar* path, const gchar* iface, const gchar* name, GVariant* args, gpointer data) {
  auto weak = static_cast<std::weak_ptr<Central>*>(data); auto s = weak->lock(); if (!s) return;
  std::unique_lock<std::mutex> lock(s->mutex, std::try_to_lock);
  if (!lock.owns_lock()) {
    if (s->deferred.size() >= 1024) {
      if (s->listening) fl_event_channel_send_error(s->events, "busy", "Native event queue overflow", nullptr, nullptr, nullptr);
      return;
    }
    auto copy = std::shared_ptr<GVariant>(g_variant_ref(args), g_variant_unref);
    const std::string copied_path = path, copied_iface = iface, copied_name = name;
    s->deferred.push_back([weak = std::weak_ptr<Central>(s), copy, copied_path, copied_iface, copied_name]() mutable {
      Signal(nullptr, nullptr, copied_path.c_str(), copied_iface.c_str(), copied_name.c_str(), copy.get(), &weak);
    });
    return;
  }
  if (std::string(iface) == "org.freedesktop.DBus.ObjectManager" && std::string(name) == "InterfacesAdded") {
    const gchar* object; GVariant* interfaces;
    g_variant_get(args, "(&o@a{sa{sv}})", &object, &interfaces);
    g_autoptr(GVariant) owned = interfaces;
    g_autoptr(GVariant) props = g_variant_lookup_value(interfaces, "org.bluez.Device1", G_VARIANT_TYPE("a{sv}"));
    if (props) RememberDevice(*s, object, props);
    return;
  }
  if (std::string(name) != "PropertiesChanged") return;
  const gchar* changed; GVariant* props; GVariant* invalid;
  g_variant_get(args, "(&s@a{sv}@as)", &changed, &props, &invalid);
  g_autoptr(GVariant) p = props; g_autoptr(GVariant) i = invalid;
  if (std::string(changed) == "org.bluez.Device1") {
    RememberDevice(*s, path, props);
    g_autoptr(GVariant) connected = g_variant_lookup_value(props, "Connected", G_VARIANT_TYPE_BOOLEAN);
    if (s->device == path && connected && !g_variant_get_boolean(connected)) {
      g_autoptr(FlValue) e = fl_value_new_map(); Set(e, "type", fl_value_new_string("disconnected")); Emit(*s, e);
    }
  }
  if (std::string(changed) == "org.bluez.Adapter1") {
    g_autoptr(GVariant) powered = g_variant_lookup_value(props, "Powered", G_VARIANT_TYPE_BOOLEAN);
    if (powered) { g_autoptr(FlValue) e = fl_value_new_map(); Set(e, "type", fl_value_new_string("state")); Set(e, "state", fl_value_new_string(g_variant_get_boolean(powered) ? "poweredOn" : "poweredOff")); Emit(*s, e); }
  }
  if (std::string(changed) == "org.bluez.GattCharacteristic1") {
    g_autoptr(GVariant) value = g_variant_lookup_value(props, "Value", G_VARIANT_TYPE("ay"));
    if (!value) return;
    for (const auto& field : s->fields) if (field.second == path) {
      gsize length; auto bytes = static_cast<const guchar*>(g_variant_get_fixed_array(value, &length, 1));
      g_autofree gchar* encoded = g_base64_encode(bytes, length);
      g_autoptr(FlValue) e = fl_value_new_map(); Set(e, "type", fl_value_new_string("notification"));
      Set(e, "key", fl_value_new_string(field.first.c_str())); Set(e, "value", fl_value_new_string(encoded)); Emit(*s, e);
    }
  }
}
struct Job {
  State state; FlMethodCall* call; std::string method;
  FlValue* args; FlValue* value = nullptr; GError* error = nullptr;
  GCancellable* cancel = g_cancellable_new();
  GVariant* scan_objects = nullptr;
  ~Job() { g_object_unref(cancel); if (scan_objects) g_variant_unref(scan_objects); g_object_unref(call); if (args) fl_value_unref(args); if (value) fl_value_unref(value); if (error) g_error_free(error); }
};
static std::string Arg(Job& j, const char* key) {
  auto v = j.args ? fl_value_lookup_string(j.args, key) : nullptr;
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING ? fl_value_get_string(v) : "";
}
static GVariant* Options() { GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}")); return g_variant_builder_end(&b); }
static void Work(GTask* task, gpointer, gpointer data, GCancellable*) {
  auto& j = *static_cast<Job*>(data); auto& s = *j.state;
  std::lock_guard<std::mutex> lock(s.mutex);
  s.worker_cancel = j.cancel;
  if (!s.bus) s.bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &j.error);
  if (!s.bus) { g_task_return_boolean(task, false); return; }
  g_autoptr(GVariant) objects = Objects(s, &j.error);
  if (!objects) { g_task_return_boolean(task, false); return; }
  GVariantIter it; const char* path; GVariant* interfaces;
  g_variant_iter_init(&it, objects);
  bool powered = false;
  while (g_variant_iter_next(&it, "{&o@a{sa{sv}}}", &path, &interfaces)) {
    g_autoptr(GVariant) owned = interfaces;
    g_autoptr(GVariant) props = g_variant_lookup_value(interfaces, "org.bluez.Adapter1", G_VARIANT_TYPE("a{sv}"));
    if (props && s.adapter.empty()) s.adapter = path;
    if (props && s.adapter == path) powered = Bool(props, "Powered");
  }
  if (j.method == "checkSupport" || j.method == "requestPermissions") {
    j.value = fl_value_new_string(s.adapter.empty() ? "unsupported" : powered ? "poweredOn" : "poweredOff");
  } else if (j.method == "startScan") {
    j.scan_objects = g_variant_ref(objects);
    s.filters.clear(); auto ids = j.args ? fl_value_lookup_string(j.args, "services") : nullptr;
    if (ids) for (size_t n = 0; n < fl_value_get_length(ids); n++) s.filters.emplace_back(fl_value_get_string(fl_value_get_list_value(ids, n)));
    GVariantBuilder filter, uuids; g_variant_builder_init(&filter, G_VARIANT_TYPE("a{sv}")); g_variant_builder_init(&uuids, G_VARIANT_TYPE("as"));
    for (const auto& id : s.filters) g_variant_builder_add(&uuids, "s", id.c_str());
    g_variant_builder_add(&filter, "{sv}", "Transport", g_variant_new_string("le"));
    g_variant_builder_add(&filter, "{sv}", "UUIDs", g_variant_builder_end(&uuids));
    g_autoptr(GVariant) f = Call(s, s.adapter, "org.bluez.Adapter1", "SetDiscoveryFilter", g_variant_new("(@a{sv})", g_variant_builder_end(&filter)), &j.error);
    if (f) { g_autoptr(GVariant) r = Call(s, s.adapter, "org.bluez.Adapter1", "StartDiscovery", nullptr, &j.error); s.scanning = r != nullptr; }
  } else if (j.method == "stopScan" || j.method == "dispose") {
    if (s.scanning) { g_autoptr(GVariant) r = Call(s, s.adapter, "org.bluez.Adapter1", "StopDiscovery", nullptr, &j.error); s.scanning = false; }
    if (j.method == "dispose" && !s.device.empty()) { g_autoptr(GVariant) r = Call(s, s.device, "org.bluez.Device1", "Disconnect", nullptr, nullptr); s.device.clear(); s.fields.clear(); }
  } else if (j.method == "connect") {
    auto id = Arg(j, "id");
    g_autoptr(GVariant) obj = g_variant_lookup_value(objects, id.c_str(), G_VARIANT_TYPE("a{sa{sv}}"));
    if (!obj || id.rfind(s.adapter + "/dev_", 0) != 0) g_set_error_literal(&j.error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Device not discovered");
    else { s.device = id; g_autoptr(GVariant) r = Call(s, id, "org.bluez.Device1", "Connect", nullptr, &j.error); }
  } else if (j.method == "disconnect") {
    if (!s.device.empty()) { g_autoptr(GVariant) r = Call(s, s.device, "org.bluez.Device1", "Disconnect", nullptr, &j.error); }
    s.device.clear(); s.fields.clear();
  } else if (j.method == "maximumWriteBytes") { j.value = fl_value_new_int(20); }
  else if (j.method == "discover") {
    // BlueZ Connect completes before ServicesResolved; wait off the UI thread.
    bool resolved = false;
    const auto deadline = g_get_monotonic_time() + 5000000;
    for (int n = 0; n < 40 && g_get_monotonic_time() < deadline; ++n) {
      g_autoptr(GVariant) r = Call(s, s.device, "org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", "org.bluez.Device1", "ServicesResolved"), &j.error);
      if (!r) break;
      g_autoptr(GVariant) box = g_variant_get_child_value(r, 0); g_autoptr(GVariant) flag = g_variant_get_variant(box);
      if (g_variant_get_boolean(flag)) { resolved = true; break; }
      g_usleep(100000);
    }
    if (!resolved && !j.error) g_set_error_literal(&j.error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "Service discovery timed out");
    if (resolved) {
      g_clear_pointer(&objects, g_variant_unref); objects = Objects(s, &j.error);
      std::map<std::string, std::string> services; s.fields.clear();
      if (objects) {
        g_variant_iter_init(&it, objects);
        while (g_variant_iter_next(&it, "{&o@a{sa{sv}}}", &path, &interfaces)) {
          g_autoptr(GVariant) owned = interfaces; g_autoptr(GVariant) props = g_variant_lookup_value(interfaces, "org.bluez.GattService1", G_VARIANT_TYPE("a{sv}"));
          if (props && Path(props, "Device") == s.device) services[path] = String(props, "UUID");
        }
        j.value = fl_value_new_list(); g_variant_iter_init(&it, objects);
        while (g_variant_iter_next(&it, "{&o@a{sa{sv}}}", &path, &interfaces)) {
          g_autoptr(GVariant) owned = interfaces; g_autoptr(GVariant) props = g_variant_lookup_value(interfaces, "org.bluez.GattCharacteristic1", G_VARIANT_TYPE("a{sv}"));
          if (!props || !services.count(Path(props, "Service"))) continue;
          auto service = services[Path(props, "Service")], uuid = String(props, "UUID");
          s.fields[service + "/" + uuid] = path;
          auto item = fl_value_new_map(); Set(item, "service", fl_value_new_string(service.c_str())); Set(item, "uuid", fl_value_new_string(uuid.c_str()));
          auto access = fl_value_new_list(); g_autoptr(GVariant) flags = g_variant_lookup_value(props, "Flags", G_VARIANT_TYPE("as"));
          if (flags) { GVariantIter fi; const char* flag; g_variant_iter_init(&fi, flags); while (g_variant_iter_next(&fi, "&s", &flag)) {
            if (std::string(flag) == "read" || std::string(flag) == "write" || std::string(flag) == "notify") fl_value_append_take(access, fl_value_new_string(flag));
            else if (std::string(flag) == "indicate") fl_value_append_take(access, fl_value_new_string("notify"));
          } }
          Set(item, "access", access); fl_value_append_take(j.value, item);
        }
      }
    }
  } else {
    auto key = Arg(j, "key");
    if (!s.fields.count(key)) g_set_error_literal(&j.error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "Characteristic missing");
    else if (j.method == "read") {
      g_autoptr(GVariant) r = Call(s, s.fields[key], "org.bluez.GattCharacteristic1", "ReadValue", g_variant_new("(@a{sv})", Options()), &j.error);
      if (r) { g_autoptr(GVariant) bytes = g_variant_get_child_value(r, 0); gsize size; auto data = static_cast<const guchar*>(g_variant_get_fixed_array(bytes, &size, 1)); g_autofree gchar* b64 = g_base64_encode(data, size); j.value = fl_value_new_string(b64); }
    } else if (j.method == "write") {
      gsize size; g_autofree guchar* data = g_base64_decode(Arg(j, "value").c_str(), &size);
      GVariantBuilder options; g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}")); g_variant_builder_add(&options, "{sv}", "type", g_variant_new_string("request"));
      g_autoptr(GVariant) r = Call(s, s.fields[key], "org.bluez.GattCharacteristic1", "WriteValue", g_variant_new("(@ay@a{sv})", g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, data, size, 1), g_variant_builder_end(&options)), &j.error);
    } else if (j.method == "subscribe") {
      auto enabled = fl_value_get_bool(fl_value_lookup_string(j.args, "enabled"));
      g_autoptr(GVariant) r = Call(s, s.fields[key], "org.bluez.GattCharacteristic1", enabled ? "StartNotify" : "StopNotify", nullptr, &j.error);
    } else g_set_error_literal(&j.error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Unknown operation");
  }
  g_task_return_boolean(task, j.error == nullptr);
}
static void Complete(GObject*, GAsyncResult* result, gpointer) {
  auto* task = G_TASK(result); auto* j = static_cast<Job*>(g_task_get_task_data(task)); auto s = j->state;
  if (s->bus && !s->signal) s->signal = g_dbus_connection_signal_subscribe(s->bus, "org.bluez", nullptr, nullptr, nullptr, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, Signal, new std::weak_ptr<Central>(s), [](gpointer p) { delete static_cast<std::weak_ptr<Central>*>(p); });
  --s->jobs;
  if (s->active == j->cancel) { g_clear_object(&s->active); }
  auto pending = std::move(s->deferred); s->deferred.clear();
  for (auto& callback : pending) callback();
  if (j->scan_objects && !j->error) {
    GVariantIter iter; const char* path; GVariant* interfaces; g_variant_iter_init(&iter, j->scan_objects);
    while (g_variant_iter_next(&iter, "{&o@a{sa{sv}}}", &path, &interfaces)) {
      g_autoptr(GVariant) owned = interfaces;
      g_autoptr(GVariant) props = g_variant_lookup_value(interfaces, "org.bluez.Device1", G_VARIANT_TYPE("a{sv}"));
      if (props) {
        g_autoptr(GVariant) signal = g_variant_ref_sink(g_variant_new("(o@a{sa{sv}})", path, g_variant_ref(interfaces)));
        auto weak = std::weak_ptr<Central>(s);
        Signal(nullptr, nullptr, "/", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded", signal, &weak);
      }
    }
  }
  if (j->error) {
    g_autofree gchar* remote = g_dbus_error_get_remote_error(j->error);
    const auto message = std::string(remote ? remote : "");
    const char* code = message.find("NotAuthorized") != std::string::npos || message.find("AccessDenied") != std::string::npos ? "permission_denied" :
      g_error_matches(j->error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT) ? "timeout" : "ble_error";
    fl_method_call_respond_error(j->call, code, j->error->message, nullptr, nullptr);
  } else fl_method_call_respond_success(j->call, j->value, nullptr);
}
}
void register_ble_central(FlBinaryMessenger* messenger) {
  auto state = std::make_shared<Central>();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state->events = fl_event_channel_new(messenger, "universal_ble_server/client/events", FL_METHOD_CODEC(codec));
  auto weak = new std::weak_ptr<Central>(state);
  fl_event_channel_set_stream_handlers(state->events,
    [](FlEventChannel*, FlValue*, gpointer p) -> FlMethodErrorResponse* { if (auto s = static_cast<std::weak_ptr<Central>*>(p)->lock()) s->listening = true; return nullptr; },
    [](FlEventChannel*, FlValue*, gpointer p) -> FlMethodErrorResponse* { if (auto s = static_cast<std::weak_ptr<Central>*>(p)->lock()) s->listening = false; return nullptr; },
    weak, [](gpointer p) { delete static_cast<std::weak_ptr<Central>*>(p); });
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(messenger, "universal_ble_server/client/methods", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
    auto state = *static_cast<State*>(data); auto args = fl_method_call_get_args(call);
    const std::string method = fl_method_call_get_name(call);
    const bool cancel = method == "disconnect" || method == "dispose";
    if (state->jobs > 0 && !cancel) { fl_method_call_respond_error(call, "busy", "Native operation pending", nullptr, nullptr); return; }
    if (state->jobs >= 2) { fl_method_call_respond_error(call, "busy", "Cancellation pending", nullptr, nullptr); return; }
    if (cancel && state->active) g_cancellable_cancel(state->active);
    auto job = new Job{state, FL_METHOD_CALL(g_object_ref(call)), fl_method_call_get_name(call), args ? fl_value_ref(args) : nullptr};
    if (state->active) g_object_unref(state->active);
    state->active = G_CANCELLABLE(g_object_ref(job->cancel)); state->jobs++;
    g_autoptr(GTask) task = g_task_new(nullptr, nullptr, Complete, nullptr);
    g_task_set_task_data(task, job, [](gpointer p) { delete static_cast<Job*>(p); }); g_task_run_in_thread(task, Work);
  }, new State(state), [](gpointer p) { delete static_cast<State*>(p); });
}
