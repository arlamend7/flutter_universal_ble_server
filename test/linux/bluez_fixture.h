#pragma once
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <functional>
#include <string>
#include <vector>

inline void Spin(const std::function<bool()>& ready) {
  const auto until = g_get_monotonic_time() + 10000000;
  while (!ready() && g_get_monotonic_time() < until) {
    while (g_main_context_iteration(nullptr, false)) {}
    g_usleep(1000);
  }
  g_assert_true(ready());
}
struct DBusReply {
  GVariant* value = nullptr; GError* error = nullptr; GUnixFDList* fds = nullptr; bool done = false;
  ~DBusReply() { if (value) g_variant_unref(value); if (error) g_error_free(error); if (fds) g_object_unref(fds); }
};
inline void Invoke(GDBusConnection* bus, const std::string& dest, const std::string& path, const char* iface, const char* method, GVariant* args, DBusReply& r) {
  g_dbus_connection_call_with_unix_fd_list(bus, dest.c_str(), path.c_str(), iface, method, args, nullptr,
    G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, nullptr, [](GObject* object, GAsyncResult* result, gpointer p) {
      auto& r = *static_cast<DBusReply*>(p);
      r.value = g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(object), &r.fds, result, &r.error); r.done = true;
    }, &r);
  Spin([&] { return r.done; });
}
inline GDBusConnection* Bus(const char* address) {
  GError* error = nullptr;
  auto bus = g_dbus_connection_new_for_address_sync(address,
    static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION), nullptr, nullptr, &error);
  g_assert_no_error(error); return bus;
}
struct BluezFixture {
  GTestDBus* daemon;
  GDBusConnection* bus;
  GDBusNodeInfo* xml;
  std::vector<guint> registrations;
  std::string application, applicationPath;
  bool powered = true, rejectAdvertisement = false;
  int applications = 0, advertisements = 0, advertisementRejections = 0;
  std::vector<std::string> disconnected, connected;
  std::vector<guint8> written;
  const char* adapter = "/org/bluez/hci0";
  const char* deviceA = "/org/bluez/hci0/dev_AA";
  const char* deviceB = "/org/bluez/hci0/dev_BB";
  BluezFixture() {
    daemon = g_test_dbus_new(G_TEST_DBUS_NONE); g_test_dbus_up(daemon);
    g_setenv("DBUS_SYSTEM_BUS_ADDRESS", g_test_dbus_get_bus_address(daemon), true);
    bus = Bus(g_test_dbus_get_bus_address(daemon));
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) name = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
      g_variant_new("(su)", "org.bluez", 0), nullptr, G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, &error); g_assert_no_error(error);
    xml = g_dbus_node_info_new_for_xml(R"XML(<node>
      <interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method></interface>
      <interface name="org.bluez.GattManager1"><method name="RegisterApplication"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/></method></interface>
      <interface name="org.bluez.LEAdvertisingManager1"><method name="RegisterAdvertisement"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/></method></interface>
      <interface name="org.bluez.Adapter1">
        <method name="SetDiscoveryFilter"><arg type="a{sv}" direction="in"/></method><method name="StartDiscovery"/><method name="StopDiscovery"/>
        <property name="Powered" type="b" access="read"/>
      </interface>
      <interface name="org.bluez.Device1"><method name="Connect"/><method name="Disconnect"/><property name="ServicesResolved" type="b" access="read"/></interface>
      <interface name="org.bluez.GattCharacteristic1">
        <method name="ReadValue"><arg type="a{sv}" direction="in"/><arg type="ay" direction="out"/></method>
        <method name="WriteValue"><arg type="ay" direction="in"/><arg type="a{sv}" direction="in"/></method>
        <method name="StartNotify"/><method name="StopNotify"/>
      </interface>
    </node>)XML", &error); g_assert_no_error(error);
    Export("/", "org.freedesktop.DBus.ObjectManager");
    Export(adapter, "org.bluez.Adapter1"); Export(adapter, "org.bluez.GattManager1"); Export(adapter, "org.bluez.LEAdvertisingManager1");
    for (const char* device : {deviceA, deviceB}) {
      Export(device, "org.bluez.Device1"); Export(std::string(device) + "/service0/char0", "org.bluez.GattCharacteristic1");
    }
  }
  void Export(const std::string& path, const char* iface) {
    static const GDBusInterfaceVTable vtable = {
      [](GDBusConnection*, const gchar* sender, const gchar* path, const gchar*, const gchar* method, GVariant* args, GDBusMethodInvocation* call, gpointer p) {
        static_cast<BluezFixture*>(p)->Method(sender, path, method, args, call);
      },
      [](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar* property, GError**, gpointer p) -> GVariant* {
        if (std::string(property) == "ServicesResolved") return g_variant_new_boolean(true);
        return g_variant_new_boolean(static_cast<BluezFixture*>(p)->powered);
      }, nullptr, {nullptr}};
    GError* error = nullptr;
    auto id = g_dbus_connection_register_object(bus, path.c_str(), g_dbus_node_info_lookup_interface(xml, iface), &vtable, this, nullptr, &error);
    g_assert_no_error(error); registrations.push_back(id);
  }
  GVariant* Objects() {
    GVariantBuilder objects; g_variant_builder_init(&objects, G_VARIANT_TYPE("a{oa{sa{sv}}}"));
    GVariantBuilder interfaces, props;
    g_variant_builder_init(&interfaces, G_VARIANT_TYPE("a{sa{sv}}"));
    for (const char* iface : {"org.bluez.Adapter1", "org.bluez.GattManager1", "org.bluez.LEAdvertisingManager1"}) {
      g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
      if (std::string(iface) == "org.bluez.Adapter1") g_variant_builder_add(&props, "{sv}", "Powered", g_variant_new_boolean(powered));
      g_variant_builder_add(&interfaces, "{s@a{sv}}", iface, g_variant_builder_end(&props));
    }
    g_variant_builder_add(&objects, "{o@a{sa{sv}}}", adapter, g_variant_builder_end(&interfaces));
    auto add = [&](const std::string& path, const char* iface) {
      g_variant_builder_init(&interfaces, G_VARIANT_TYPE("a{sa{sv}}"));
      g_variant_builder_add(&interfaces, "{s@a{sv}}", iface, g_variant_builder_end(&props));
      g_variant_builder_add(&objects, "{o@a{sa{sv}}}", path.c_str(), g_variant_builder_end(&interfaces));
    };
    for (const char* device : {deviceA, deviceB}) {
      g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
      g_variant_builder_add(&props, "{sv}", "Name", g_variant_new_string(device));
      const char* ids[] = {"0000abcd-0000-1000-8000-00805f9b34fb", nullptr};
      g_variant_builder_add(&props, "{sv}", "UUIDs", g_variant_new_strv(ids, -1));
      add(device, "org.bluez.Device1");
      auto service = std::string(device) + "/service0";
      g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
      g_variant_builder_add(&props, "{sv}", "UUID", g_variant_new_string(ids[0]));
      g_variant_builder_add(&props, "{sv}", "Device", g_variant_new_object_path(device));
      add(service, "org.bluez.GattService1");
      g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
      g_variant_builder_add(&props, "{sv}", "UUID", g_variant_new_string("0000abce-0000-1000-8000-00805f9b34fb"));
      g_variant_builder_add(&props, "{sv}", "Service", g_variant_new_object_path(service.c_str()));
      const char* flags[] = {"read", "write", "notify", nullptr}; g_variant_builder_add(&props, "{sv}", "Flags", g_variant_new_strv(flags, -1));
      add(service + "/char0", "org.bluez.GattCharacteristic1");
    }
    return g_variant_builder_end(&objects);
  }
  void Method(const char* sender, const char* path, const std::string& method, GVariant* args, GDBusMethodInvocation* call) {
    if (method == "GetManagedObjects") { g_dbus_method_invocation_return_value(call, g_variant_new("(@a{oa{sa{sv}}})", Objects())); return; }
    if (method == "RegisterApplication") {
      applications++; application = sender;
      g_autoptr(GVariant) p = g_variant_get_child_value(args, 0); applicationPath = g_variant_get_string(p, nullptr);
      // BlueZ introspects during registration. An implementation blocking its
      // main loop waiting for RegisterApplication would deadlock here.
      g_dbus_connection_call(bus, sender, applicationPath.c_str(), "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", nullptr, nullptr,
        G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, [](GObject* object, GAsyncResult* result, gpointer p) {
          auto call = G_DBUS_METHOD_INVOCATION(p); g_autoptr(GError) error = nullptr;
          g_autoptr(GVariant) reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
          if (reply) g_dbus_method_invocation_return_value(call, nullptr); else g_dbus_method_invocation_return_gerror(call, error);
          g_object_unref(call);
        }, g_object_ref(call)); return;
    }
    if (method == "RegisterAdvertisement") {
      advertisements++;
      if (rejectAdvertisement || advertisementRejections > 0) {
        if (advertisementRejections > 0) --advertisementRejections;
        g_dbus_method_invocation_return_dbus_error(call, "org.bluez.Error.InvalidLength", "Advertisement too large"); return;
      }
    }
    if (method == "Connect") connected.emplace_back(path);
    if (method == "Disconnect") disconnected.emplace_back(path);
    if (method == "ReadValue") { const guint8 v[] = {0, 1, 255}; g_dbus_method_invocation_return_value(call, g_variant_new("(@ay)", g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, v, 3, 1))); return; }
    if (method == "WriteValue") { g_autoptr(GVariant) v = g_variant_get_child_value(args, 0); gsize n; auto bytes = static_cast<const guint8*>(g_variant_get_fixed_array(v, &n, 1)); written.assign(bytes, bytes + n); }
    g_dbus_method_invocation_return_value(call, nullptr);
  }
  void PowerOff() {
    powered = false; GVariantBuilder props; g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&props, "{sv}", "Powered", g_variant_new_boolean(false));
    g_dbus_connection_emit_signal(bus, nullptr, adapter, "org.freedesktop.DBus.Properties", "PropertiesChanged",
      g_variant_new("(s@a{sv}@as)", "org.bluez.Adapter1", g_variant_builder_end(&props), g_variant_new_strv(nullptr, 0)), nullptr);
  }
  ~BluezFixture() {
    for (auto id : registrations) g_dbus_connection_unregister_object(bus, id);
    g_dbus_connection_close_sync(bus, nullptr, nullptr); g_object_unref(bus); g_dbus_node_info_unref(xml);
    g_test_dbus_down(daemon); g_object_unref(daemon);
  }
};
