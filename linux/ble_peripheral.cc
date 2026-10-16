#include "ble_peripheral.h"
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib-unix.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <algorithm>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

// BlueZ callbacks and Flutter channels are confined to the GLib main context.
// A private bus connection makes registration and teardown independent of the
// central sessions. AcquireNotify supplies device identity and per-peer sockets;
// ordinary StartNotify cannot safely implement private message delivery.
namespace {
const char* kRoot = "/org/universal_ble_server/app";
const char* kAdvert = "/org/universal_ble_server/advertisement";
const char* kXml = R"XML(<node>
<interface name="org.freedesktop.DBus.ObjectManager">
 <method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method>
</interface>
<interface name="org.bluez.GattService1">
 <property name="UUID" type="s" access="read"/><property name="Primary" type="b" access="read"/>
</interface>
<interface name="org.bluez.GattCharacteristic1">
 <method name="ReadValue"><arg type="a{sv}" direction="in"/><arg type="ay" direction="out"/></method>
 <method name="WriteValue"><arg type="ay" direction="in"/><arg type="a{sv}" direction="in"/></method>
 <method name="AcquireNotify"><arg type="a{sv}" direction="in"/><arg type="h" direction="out"/><arg type="q" direction="out"/></method>
 <method name="StartNotify"/><method name="StopNotify"/>
 <property name="UUID" type="s" access="read"/><property name="Service" type="o" access="read"/>
 <property name="Flags" type="as" access="read"/><property name="Value" type="ay" access="read"/>
 <property name="NotifyAcquired" type="b" access="read"/>
</interface>
<interface name="org.bluez.LEAdvertisement1">
 <method name="Release"/>
 <property name="Type" type="s" access="read"/><property name="ServiceUUIDs" type="as" access="read"/>
 <property name="LocalName" type="s" access="read"/>
</interface>
</node>)XML";
struct Peripheral;
using State = std::shared_ptr<Peripheral>;
struct Peer { int fd; guint source; guint16 mtu; };
struct Field {
  std::string uuid, path, service;
  std::vector<std::string> flags;
  std::vector<guint8> value;
  std::map<std::string, Peer> peers;
  ~Field() {
    for (auto& p : peers) { if (p.second.source) g_source_remove(p.second.source); close(p.second.fd); }
  }
};
struct Request {
  GDBusMethodInvocation* invocation;
  std::weak_ptr<Peripheral> state;
  std::string uuid, device, type;
  int generation, offset;
  guint timer = 0;
  bool replied = false;
  ~Request() { if (timer) g_source_remove(timer); g_object_unref(invocation); }
  void Fail(const char* name, const char* message) {
    if (replied) return;
    replied = true;
    g_dbus_method_invocation_return_dbus_error(invocation, name, message);
  }
};
struct Notification {
  FlMethodCall* call;
  std::weak_ptr<Peripheral> state;
  std::string uuid;
  std::vector<std::pair<std::string, guint>> targets;
  std::vector<guint8> value;
  size_t next = 0;
  int generation;
  guint timer = 0, source = 0;
  bool done = false;
  ~Notification() { if (timer) g_source_remove(timer); if (source) g_source_remove(source); g_object_unref(call); }
  void Finish(const char* code = nullptr, const char* message = nullptr) {
    if (done) return;
    done = true;
    if (timer) { g_source_remove(timer); timer = 0; }
    if (source) { g_source_remove(source); source = 0; }
    if (code) fl_method_call_respond_error(call, code, message, nullptr, nullptr);
    else fl_method_call_respond_success(call, nullptr, nullptr);
  }
};
struct Peripheral {
  GDBusConnection* bus = nullptr;
  GDBusNodeInfo* info = nullptr;
  FlMethodChannel* channel = nullptr;
  FlEventChannel* events = nullptr;
  bool listening = false, running = false, starting = false, checking = false;
  bool powered = false, supported = false;
  int generation = 0;
  guint signal = 0, ownerWatch = 0;
  std::string adapter, name, advertised, bluezOwner;
  std::map<std::string, std::string> services;
  std::map<std::string, std::unique_ptr<Field>> fields;
  std::vector<guint> registrations;
  std::vector<std::weak_ptr<Request>> requests;
  std::vector<std::weak_ptr<Notification>> notifications;
  ~Peripheral();
};
static void Set(FlValue* map, const char* name, FlValue* value) { fl_value_set_string_take(map, name, value); }
static std::string Text(FlValue* value) { return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : ""; }
static FlValue* Get(FlValue* map, const char* key) { return map && fl_value_get_type(map) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(map, key) : nullptr; }
static std::string Arg(FlValue* map, const char* key) { return Text(Get(map, key)); }
static GVariant* Empty() { GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}")); return g_variant_builder_end(&b); }
static bool Has(const Field& field, const char* flag) { return std::find(field.flags.begin(), field.flags.end(), flag) != field.flags.end(); }
static GVariant* Bytes(const std::vector<guint8>& bytes) { return g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, bytes.data(), bytes.size(), 1); }
static std::vector<guint8> Decode(const std::string& encoded) {
  gsize size; g_autofree guchar* data = g_base64_decode(encoded.c_str(), &size);
  return std::vector<guint8>(data, data + size);
}
static void Emit(Peripheral& s, FlValue* event) { if (s.listening) fl_event_channel_send(s.events, event, nullptr, nullptr); }
static void Event(Peripheral& s, const char* type, const std::string& uuid, const std::string& device, int mtu = 23) {
  g_autoptr(FlValue) e = fl_value_new_map(); Set(e, "type", fl_value_new_string(type));
  Set(e, "uuid", fl_value_new_string(uuid.c_str())); Set(e, "clientId", fl_value_new_string(device.c_str()));
  Set(e, "maxNotificationBytes", fl_value_new_int(mtu - 3)); Emit(s, e);
}
static void ErrorEvent(Peripheral& s, const char* message) {
  g_autoptr(FlValue) e = fl_value_new_map(); Set(e, "type", fl_value_new_string("error"));
  Set(e, "message", fl_value_new_string(message)); Emit(s, e);
}
static void Reset(Peripheral& s) {
  ++s.generation; s.running = false; s.starting = false; s.checking = false;
  for (auto& weak : s.requests) if (auto r = weak.lock()) r->Fail("org.bluez.Error.Failed", "Server stopped");
  s.requests.clear();
  for (auto& weak : s.notifications) if (auto n = weak.lock()) n->Finish("disconnected", "Server stopped");
  s.notifications.clear();
  if (s.bus) {
    if (s.signal) g_dbus_connection_signal_unsubscribe(s.bus, s.signal);
    if (s.ownerWatch) { g_bus_unwatch_name(s.ownerWatch); s.ownerWatch = 0; }
    for (auto id : s.registrations) g_dbus_connection_unregister_object(s.bus, id);
    // Closing this unique bus owner unregisters its application and advertisement.
    g_dbus_connection_close(s.bus, nullptr, nullptr, nullptr);
    g_clear_object(&s.bus);
  }
  s.signal = 0; s.registrations.clear(); s.fields.clear(); s.services.clear();
  s.adapter.clear(); s.supported = false; s.powered = false;
}
Peripheral::~Peripheral() {
  Reset(*this);
  if (channel) g_object_remove_weak_pointer(G_OBJECT(channel), reinterpret_cast<gpointer*>(&channel));
  if (info) g_dbus_node_info_unref(info);
  if (events) g_object_unref(events);
}
using Reply = std::function<void(GVariant*, GError*)>;
static void Call(const State& s, const std::string& path, const char* iface, const char* method, GVariant* args, Reply reply) {
  auto done = new Reply(std::move(reply));
  g_dbus_connection_call(s->bus, "org.bluez", path.c_str(), iface, method, args, nullptr,
    G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, [](GObject* object, GAsyncResult* result, gpointer data) {
      std::unique_ptr<Reply> callback(static_cast<Reply*>(data));
      g_autoptr(GError) error = nullptr;
      g_autoptr(GVariant) value = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
      (*callback)(value, error);
    }, done);
}
static void RemovePeer(Peripheral& s, Field& field, const std::string& device, bool from_source = false) {
  auto found = field.peers.find(device); if (found == field.peers.end()) return;
  const auto peer = found->second;
  if (!from_source && peer.source) g_source_remove(peer.source);
  close(peer.fd); field.peers.erase(found);
  Event(s, "unsubscribed", field.uuid, device, peer.mtu);
}
struct PeerWatch { std::weak_ptr<Peripheral> state; std::string uuid, device; };
static void Acquire(const State& s, Field& field, GVariant* options, GDBusMethodInvocation* invocation) {
  const char* device = nullptr; guint16 mtu = 23;
  g_variant_lookup(options, "device", "&o", &device); g_variant_lookup(options, "mtu", "q", &mtu);
  if (!Has(field, "notify") || !device || mtu < 23 || mtu > 517) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.NotSupported", "Per-device notify requires a device and valid MTU"); return;
  }
  if (field.peers.count(device) || field.peers.size() >= 16) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.InProgress", "Notification session exists or limit reached"); return;
  }
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sockets) != 0) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.Failed", "Cannot create notification socket"); return;
  }
  for (int fd : sockets) {
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
      close(sockets[0]); close(sockets[1]);
      g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.Failed", "Cannot configure notification socket"); return;
    }
  }
  g_autoptr(GUnixFDList) fds = g_unix_fd_list_new();
  g_autoptr(GError) error = nullptr;
  int index = g_unix_fd_list_append(fds, sockets[1], &error); close(sockets[1]);
  if (index < 0) { close(sockets[0]); g_dbus_method_invocation_return_gerror(invocation, error); return; }
  auto watch = new PeerWatch{s, field.uuid, device};
  guint source = g_unix_fd_add_full(G_PRIORITY_DEFAULT, sockets[0], static_cast<GIOCondition>(G_IO_HUP | G_IO_ERR | G_IO_NVAL),
    [](gint, GIOCondition, gpointer data) -> gboolean {
      auto* w = static_cast<PeerWatch*>(data);
      if (auto state = w->state.lock()) {
        auto f = state->fields.find(w->uuid);
        if (f != state->fields.end()) RemovePeer(*state, *f->second, w->device, true);
      }
      return G_SOURCE_REMOVE;
    }, watch, [](gpointer p) { delete static_cast<PeerWatch*>(p); });
  field.peers.emplace(device, Peer{sockets[0], source, mtu});
  g_dbus_method_invocation_return_value_with_unix_fd_list(invocation, g_variant_new("(hq)", index, mtu), fds);
  Event(*s, "subscribed", field.uuid, device, mtu);
}
static const char* AttError(int status) {
  switch (status) {
    case 2: case 3: return "org.bluez.Error.NotPermitted";
    case 5: case 8: case 15: return "org.bluez.Error.NotAuthorized";
    case 7: return "org.bluez.Error.InvalidOffset";
    case 13: return "org.bluez.Error.InvalidValueLength";
    case 6: return "org.bluez.Error.NotSupported";
    default: return "org.bluez.Error.Failed";
  }
}
static void RequestValue(const State& s, Field& field, const char* type, GVariant* options, GVariant* value, GDBusMethodInvocation* invocation) {
  const char* device = nullptr; guint16 offset = 0; gboolean prepared = false;
  g_variant_lookup(options, "device", "&o", &device); g_variant_lookup(options, "offset", "q", &offset);
  g_variant_lookup(options, "prepare-authorize", "b", &prepared);
  if (!s->running || !device || prepared || !Has(field, type)) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.NotPermitted", "Request is unavailable or unsupported"); return;
  }
  if (s->requests.size() >= 128) {
    s->requests.erase(std::remove_if(s->requests.begin(), s->requests.end(), [](const std::weak_ptr<Request>& r) { return r.expired(); }), s->requests.end());
    if (s->requests.size() >= 128) { g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.InProgress", "Request queue full"); return; }
  }
  auto r = std::make_shared<Request>();
  r->invocation = G_DBUS_METHOD_INVOCATION(g_object_ref(invocation)); r->state = s;
  r->uuid = field.uuid; r->device = device; r->type = type; r->offset = offset; r->generation = s->generation;
  s->requests.push_back(r);
  r->timer = g_timeout_add_full(G_PRIORITY_DEFAULT, 5000, [](gpointer data) -> gboolean {
    auto r = *static_cast<std::shared_ptr<Request>*>(data); r->timer = 0;
    r->Fail("org.bluez.Error.Failed", "Dart request timed out"); return G_SOURCE_REMOVE;
  }, new std::shared_ptr<Request>(r), [](gpointer p) { delete static_cast<std::shared_ptr<Request>*>(p); });
  g_autoptr(FlValue) args = fl_value_new_map();
  Set(args, "type", fl_value_new_string(type)); Set(args, "uuid", fl_value_new_string(field.uuid.c_str()));
  Set(args, "clientId", fl_value_new_string(device)); Set(args, "offset", fl_value_new_int(offset));
  if (value) {
    gsize size; auto bytes = static_cast<const guchar*>(g_variant_get_fixed_array(value, &size, 1));
    if (size > 512) { r->Fail("org.bluez.Error.InvalidValueLength", "Value exceeds 512 bytes"); return; }
    g_autofree gchar* b64 = g_base64_encode(bytes, size); Set(args, "value", fl_value_new_string(b64));
  }
  fl_method_channel_invoke_method(s->channel, "request", args, nullptr, [](GObject* object, GAsyncResult* result, gpointer data) {
    std::unique_ptr<std::shared_ptr<Request>> holder(static_cast<std::shared_ptr<Request>*>(data)); auto r = *holder;
    if (r->timer) { g_source_remove(r->timer); r->timer = 0; }
    g_autoptr(GError) error = nullptr;
    g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object), result, &error);
    auto s = r->state.lock(); if (r->replied) return;
    if (!s || !s->running || s->generation != r->generation || !response || !FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
      r->Fail("org.bluez.Error.Failed", "Server request cancelled or failed"); return;
    }
    FlValue* answer = fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response));
    auto statusValue = Get(answer, "status");
    int status = statusValue && fl_value_get_type(statusValue) == FL_VALUE_TYPE_INT ? fl_value_get_int(statusValue) : 14;
    if (status != 0) { r->Fail(AttError(status), "Dart rejected the request"); return; }
    auto value = Decode(Arg(answer, "value"));
    if (value.size() > 512 || r->offset > static_cast<int>(value.size())) { r->Fail("org.bluez.Error.InvalidValueLength", "Invalid read response"); return; }
    auto f = s->fields.find(r->uuid); if (f == s->fields.end()) { r->Fail("org.bluez.Error.Failed", "Field removed"); return; }
    r->replied = true;
    if (r->type == "read") {
      std::vector<guint8> part(value.begin() + r->offset, value.end());
      g_dbus_method_invocation_return_value(r->invocation, g_variant_new("(@ay)", Bytes(part)));
    } else {
      f->second->value = value;
      g_dbus_method_invocation_return_value(r->invocation, nullptr);
    }
    g_autoptr(FlValue) e = fl_value_new_map();
    Set(e, "type", fl_value_new_string(r->type.c_str())); Set(e, "uuid", fl_value_new_string(r->uuid.c_str()));
    Set(e, "clientId", fl_value_new_string(r->device.c_str())); Set(e, "offset", fl_value_new_int(r->offset));
    g_autofree gchar* b64 = g_base64_encode(value.data(), value.size()); Set(e, "value", fl_value_new_string(b64)); Emit(*s, e);
  }, new std::shared_ptr<Request>(r));
}
static GVariant* Properties(Peripheral& s, const std::string& path, const std::string& iface) {
  GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  if (iface == "org.bluez.GattService1") {
    g_variant_builder_add(&b, "{sv}", "UUID", g_variant_new_string(s.services.at(path).c_str()));
    g_variant_builder_add(&b, "{sv}", "Primary", g_variant_new_boolean(true));
  } else if (iface == "org.bluez.GattCharacteristic1") {
    for (auto& entry : s.fields) if (entry.second->path == path) {
      auto& f = *entry.second;
      g_variant_builder_add(&b, "{sv}", "UUID", g_variant_new_string(f.uuid.c_str()));
      g_variant_builder_add(&b, "{sv}", "Service", g_variant_new_object_path(f.service.c_str()));
      GVariantBuilder flags; g_variant_builder_init(&flags, G_VARIANT_TYPE("as"));
      for (const auto& flag : f.flags) g_variant_builder_add(&flags, "s", flag.c_str());
      g_variant_builder_add(&b, "{sv}", "Flags", g_variant_builder_end(&flags));
      g_variant_builder_add(&b, "{sv}", "Value", Bytes(f.value));
      if (Has(f, "notify")) g_variant_builder_add(&b, "{sv}", "NotifyAcquired", g_variant_new_boolean(!f.peers.empty()));
    }
  } else if (iface == "org.bluez.LEAdvertisement1") {
    g_variant_builder_add(&b, "{sv}", "Type", g_variant_new_string("peripheral"));
    const char* uuids[] = {s.advertised.c_str(), nullptr};
    g_variant_builder_add(&b, "{sv}", "ServiceUUIDs", g_variant_new_strv(uuids, -1));
    if (!s.name.empty()) g_variant_builder_add(&b, "{sv}", "LocalName", g_variant_new_string(s.name.c_str()));
  }
  return g_variant_builder_end(&b);
}
static void Method(GDBusConnection*, const gchar*, const gchar* path, const gchar* iface, const gchar* method, GVariant* args, GDBusMethodInvocation* invocation, gpointer data) {
  auto s = static_cast<std::weak_ptr<Peripheral>*>(data)->lock();
  if (!s) { g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.Failed", "Server gone"); return; }
  if (s->bluezOwner != g_dbus_method_invocation_get_sender(invocation)) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.NotAuthorized", "Only BlueZ may access the local GATT application"); return;
  }
  const std::string op = method;
  if (op == "GetManagedObjects") {
    GVariantBuilder objects; g_variant_builder_init(&objects, G_VARIANT_TYPE("a{oa{sa{sv}}}"));
    auto add = [&](const std::string& p, const char* interface) {
      GVariantBuilder interfaces; g_variant_builder_init(&interfaces, G_VARIANT_TYPE("a{sa{sv}}"));
      g_variant_builder_add(&interfaces, "{s@a{sv}}", interface, Properties(*s, p, interface));
      g_variant_builder_add(&objects, "{o@a{sa{sv}}}", p.c_str(), g_variant_builder_end(&interfaces));
    };
    for (const auto& service : s->services) add(service.first, "org.bluez.GattService1");
    for (const auto& field : s->fields) add(field.second->path, "org.bluez.GattCharacteristic1");
    g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a{oa{sa{sv}}})", g_variant_builder_end(&objects))); return;
  }
  if (std::string(iface) == "org.bluez.LEAdvertisement1" && op == "Release") {
    g_dbus_method_invocation_return_value(invocation, nullptr);
    if (s->running) { ErrorEvent(*s, "BlueZ released the advertisement"); Reset(*s); } return;
  }
  for (auto& item : s->fields) if (item.second->path == path) {
    auto& field = *item.second;
    if (op == "AcquireNotify") {
      g_autoptr(GVariant) options = g_variant_get_child_value(args, 0); Acquire(s, field, options, invocation); return;
    }
    if (op == "ReadValue" || op == "WriteValue") {
      g_autoptr(GVariant) options = g_variant_get_child_value(args, op == "ReadValue" ? 0 : 1);
      g_autoptr(GVariant) value = op == "WriteValue" ? g_variant_get_child_value(args, 0) : nullptr;
      RequestValue(s, field, op == "ReadValue" ? "read" : "write", options, value, invocation); return;
    }
  }
  g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.NotSupported", "This backend requires per-device AcquireNotify");
}
static GVariant* Property(GDBusConnection*, const gchar*, const gchar* path, const gchar* iface, const gchar* name, GError** error, gpointer data) {
  auto s = static_cast<std::weak_ptr<Peripheral>*>(data)->lock();
  if (!s) { g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CLOSED, "Server gone"); return nullptr; }
  g_autoptr(GVariant) props = g_variant_ref_sink(Properties(*s, path, iface));
  auto value = g_variant_lookup_value(props, name, nullptr);
  if (!value) g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Property unavailable");
  return value;
}
static const GDBusInterfaceVTable kVtable = {Method, Property, nullptr, {nullptr}};
static bool Export(const State& s, const char* path, const char* interface, GError** error) {
  auto weak = new std::weak_ptr<Peripheral>(s);
  auto id = g_dbus_connection_register_object(s->bus, path, g_dbus_node_info_lookup_interface(s->info, interface), &kVtable,
    weak, [](gpointer p) { delete static_cast<std::weak_ptr<Peripheral>*>(p); }, error);
  if (!id) { delete weak; return false; }
  s->registrations.push_back(id); return true;
}
static void Capability(const State& s, std::function<void(GError*)> done) {
  if (!s->bus) {
    g_autoptr(GError) error = nullptr;
    g_autofree gchar* address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SYSTEM, nullptr, &error);
    if (address) s->bus = g_dbus_connection_new_for_address_sync(address,
      static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION), nullptr, nullptr, &error);
    if (!s->bus) { done(error); return; }
    g_autoptr(GVariant) owner = g_dbus_connection_call_sync(s->bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "GetNameOwner", g_variant_new("(s)", "org.bluez"), G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, &error);
    if (!owner) { Reset(*s); done(error); return; }
    const char* unique = nullptr; g_variant_get(owner, "(&s)", &unique); s->bluezOwner = unique;
    s->ownerWatch = g_bus_watch_name_on_connection(s->bus, "org.bluez", G_BUS_NAME_WATCHER_FLAGS_NONE,
      [](GDBusConnection*, const gchar*, const gchar* owner, gpointer data) {
        if (auto state = static_cast<std::weak_ptr<Peripheral>*>(data)->lock()) {
          if (state->bluezOwner != owner) { ErrorEvent(*state, "BlueZ restarted"); Reset(*state); }
        }
      },
      [](GDBusConnection*, const gchar*, gpointer data) {
        if (auto state = static_cast<std::weak_ptr<Peripheral>*>(data)->lock()) { ErrorEvent(*state, "BlueZ stopped"); Reset(*state); }
      }, new std::weak_ptr<Peripheral>(s), [](gpointer p) { delete static_cast<std::weak_ptr<Peripheral>*>(p); });
    s->signal = g_dbus_connection_signal_subscribe(s->bus, "org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged", nullptr,
      "org.bluez.Adapter1", G_DBUS_SIGNAL_FLAGS_NONE,
      [](GDBusConnection*, const gchar*, const gchar* path, const gchar*, const gchar*, GVariant* args, gpointer data) {
        if (auto s = static_cast<std::weak_ptr<Peripheral>*>(data)->lock()) {
          if (s->adapter != path) return;
          g_autoptr(GVariant) props = g_variant_get_child_value(args, 1); gboolean powered = true;
          if (g_variant_lookup(props, "Powered", "b", &powered) && !powered && (s->running || s->starting)) {
            ErrorEvent(*s, "Bluetooth powered off"); Reset(*s);
          }
        }
      }, new std::weak_ptr<Peripheral>(s), [](gpointer p) { delete static_cast<std::weak_ptr<Peripheral>*>(p); });
  }
  const auto generation = s->generation;
  Call(s, "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", nullptr, [s, generation, done](GVariant* reply, GError* error) {
    if (generation != s->generation) { g_autoptr(GError) cancelled = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_CANCELLED, "Server operation cancelled"); done(cancelled); return; }
    const auto activeAdapter = s->running ? s->adapter : std::string();
    s->supported = false; s->powered = false; s->adapter.clear();
    if (reply) {
      g_autoptr(GVariant) objects = g_variant_get_child_value(reply, 0);
      GVariantIter it; const char* path; GVariant* interfaces; g_variant_iter_init(&it, objects);
      while (g_variant_iter_next(&it, "{&o@a{sa{sv}}}", &path, &interfaces)) {
        g_autoptr(GVariant) owned = interfaces;
        g_autoptr(GVariant) adapter = g_variant_lookup_value(interfaces, "org.bluez.Adapter1", G_VARIANT_TYPE("a{sv}"));
        g_autoptr(GVariant) gatt = g_variant_lookup_value(interfaces, "org.bluez.GattManager1", G_VARIANT_TYPE("a{sv}"));
        g_autoptr(GVariant) adv = g_variant_lookup_value(interfaces, "org.bluez.LEAdvertisingManager1", G_VARIANT_TYPE("a{sv}"));
        if (!adapter || !gatt || !adv || (!activeAdapter.empty() && activeAdapter != path)) continue;
        gboolean on = false; g_variant_lookup(adapter, "Powered", "b", &on);
        if (s->adapter.empty() || on) { s->adapter = path; s->supported = true; s->powered = on; }
        if (on) break;
      }
    }
    done(error);
  });
}
static void MethodError(FlMethodCall* call, const char* code, const char* message) { fl_method_call_respond_error(call, code, message, nullptr, nullptr); }
static bool Parse(const State& s, FlValue* args) {
  s->name = Arg(args, "name"); s->advertised = Arg(args, "advertisedServiceUuid");
  auto services = Get(args, "services");
  if (!services || fl_value_get_type(services) != FL_VALUE_TYPE_LIST || fl_value_get_length(services) == 0 || fl_value_get_length(services) > 64) return false;
  for (size_t i = 0; i < fl_value_get_length(services); ++i) {
    auto service = fl_value_get_list_value(services, i);
    std::string path = std::string(kRoot) + "/service" + std::to_string(i);
    auto uuid = Arg(service, "uuid"); if (uuid.empty()) return false;
    s->services[path] = uuid;
    auto fields = Get(service, "characteristics");
    if (!fields || fl_value_get_type(fields) != FL_VALUE_TYPE_LIST) return false;
    for (size_t n = 0; n < fl_value_get_length(fields); ++n) {
      if (s->fields.size() >= 256) return false;
      auto input = fl_value_get_list_value(fields, n); auto field = std::make_unique<Field>();
      field->uuid = Arg(input, "uuid"); field->path = path + "/char" + std::to_string(n); field->service = path;
      if (field->uuid.empty() || s->fields.count(field->uuid)) return false;
      field->value = Decode(Arg(input, "value")); if (field->value.size() > 512) return false;
      auto properties = Get(input, "properties"); if (!properties || fl_value_get_type(properties) != FL_VALUE_TYPE_LIST) return false;
      for (size_t k = 0; k < fl_value_get_length(properties); ++k) {
        auto property = Text(fl_value_get_list_value(properties, k));
        if (property != "read" && property != "write" && property != "notify") return false;
        field->flags.push_back(property);
        if (Arg(input, "security") == "encryptedReadWrite" && property != "notify") field->flags.push_back("encrypt-" + property);
      }
      s->fields[field->uuid] = std::move(field);
    }
  }
  return !s->fields.empty() && !s->advertised.empty();
}
static void Advertise(const State& s, const std::shared_ptr<FlMethodCall>& call, int generation, bool retryWithoutName) {
  Call(s, s->adapter, "org.bluez.LEAdvertisingManager1", "RegisterAdvertisement", g_variant_new("(o@a{sv})", kAdvert, Empty()),
    [s, call, generation, retryWithoutName](GVariant* reply, GError* error) {
      if (!reply || generation != s->generation) {
        g_autofree gchar* remote = error ? g_dbus_error_get_remote_error(error) : nullptr;
        if (generation == s->generation && retryWithoutName && !s->name.empty() && remote && std::string(remote) == "org.bluez.Error.InvalidLength") {
          s->name.clear(); Advertise(s, call, generation, false); return;
        }
        if (generation == s->generation) Reset(*s);
        MethodError(call.get(), "ble_error", error ? error->message : "Start cancelled"); return;
      }
      s->starting = false; s->running = true; fl_method_call_respond_success(call.get(), nullptr, nullptr);
    });
}
static void Start(const State& s, FlMethodCall* raw) {
  if (s->running || s->starting || s->checking) { MethodError(raw, "busy", "Server operation active"); return; }
  s->starting = true;
  const auto generation = s->generation;
  auto call = std::shared_ptr<FlMethodCall>(FL_METHOD_CALL(g_object_ref(raw)), [](FlMethodCall* c) { g_object_unref(c); });
  Capability(s, [s, call, generation](GError* error) {
    auto fail = [s, call, generation](const char* code, const char* message) {
      if (s->generation == generation) Reset(*s);
      MethodError(call.get(), code, message);
    };
    if (error || generation != s->generation) { fail("ble_error", error ? error->message : "Start cancelled"); return; }
    if (!s->supported || !s->powered) { fail(!s->supported ? "unsupported" : "bluetooth_off", "No powered BlueZ GATT/advertising adapter"); return; }
    if (!Parse(s, fl_method_call_get_args(call.get()))) { fail("invalid_data", "Invalid GATT profile"); return; }
    g_autoptr(GError) exportError = nullptr;
    if (!Export(s, kRoot, "org.freedesktop.DBus.ObjectManager", &exportError)) { fail("ble_error", exportError->message); return; }
    for (const auto& service : s->services) if (!Export(s, service.first.c_str(), "org.bluez.GattService1", &exportError)) { fail("ble_error", exportError->message); return; }
    for (const auto& field : s->fields) if (!Export(s, field.second->path.c_str(), "org.bluez.GattCharacteristic1", &exportError)) { fail("ble_error", exportError->message); return; }
    if (!Export(s, kAdvert, "org.bluez.LEAdvertisement1", &exportError)) { fail("ble_error", exportError->message); return; }
    Call(s, s->adapter, "org.bluez.GattManager1", "RegisterApplication", g_variant_new("(o@a{sv})", kRoot, Empty()),
      [s, call, generation, fail](GVariant* reply, GError* error) {
        if (!reply || generation != s->generation) { fail("ble_error", error ? error->message : "Start cancelled"); return; }
        auto required = Get(fl_method_call_get_args(call.get()), "requireAdvertisedName");
        const bool strictName = required && fl_value_get_type(required) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(required);
        Advertise(s, call, generation, !strictName);
      });
  });
}
static void SendPending(const std::shared_ptr<Notification>& n) {
  if (n->done) return;
  auto s = n->state.lock();
  if (!s || !s->running || s->generation != n->generation) { n->Finish("disconnected", "Server stopped"); return; }
  auto found = s->fields.find(n->uuid);
  if (found == s->fields.end()) { n->Finish("disconnected", "Field removed"); return; }
  while (n->next < n->targets.size()) {
    const auto& target = n->targets[n->next];
    auto peer = found->second->peers.find(target.first);
    if (peer == found->second->peers.end() || peer->second.source != target.second) { n->Finish("disconnected", "Client subscription changed"); return; }
    auto sent = send(peer->second.fd, n->value.data(), n->value.size(), MSG_DONTWAIT | MSG_NOSIGNAL);
    if (sent < 0 && errno == EINTR) continue;
    if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      n->source = g_unix_fd_add_full(G_PRIORITY_DEFAULT, peer->second.fd, static_cast<GIOCondition>(G_IO_OUT | G_IO_HUP | G_IO_ERR),
        [](gint, GIOCondition condition, gpointer p) -> gboolean {
          auto n = *static_cast<std::shared_ptr<Notification>*>(p); n->source = 0;
          if (condition & (G_IO_HUP | G_IO_ERR)) n->Finish("disconnected", "Notification socket closed"); else SendPending(n);
          return G_SOURCE_REMOVE;
        }, new std::shared_ptr<Notification>(n), [](gpointer p) { delete static_cast<std::shared_ptr<Notification>*>(p); });
      return;
    }
    if (sent < 0 || static_cast<size_t>(sent) != n->value.size()) { n->Finish("disconnected", "Notification socket failed"); return; }
    ++n->next;
  }
  n->Finish();
}
static void Handle(const State& s, FlMethodCall* call) {
  const std::string method = fl_method_call_get_name(call); auto args = fl_method_call_get_args(call);
  if (method == "stopServer") { Reset(*s); fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (method == "startServer") { Start(s, call); return; }
  if (method == "checkSupport" || method == "requestPermissions") {
    if (s->checking || s->starting) { MethodError(call, "busy", "Capability check pending"); return; }
    s->checking = true;
    const auto generation = s->generation;
    auto retained = std::shared_ptr<FlMethodCall>(FL_METHOD_CALL(g_object_ref(call)), [](FlMethodCall* c) { g_object_unref(c); });
    Capability(s, [s, retained, generation](GError* error) {
      if (generation != s->generation) { MethodError(retained.get(), "disconnected", "Capability check cancelled"); return; }
      s->checking = false;
      g_autoptr(FlValue) value = fl_value_new_map();
      Set(value, "platform", fl_value_new_string("linux")); Set(value, "peripheral", fl_value_new_bool(s->supported && !error));
      Set(value, "poweredOn", fl_value_new_bool(s->powered)); Set(value, "authorized", fl_value_new_bool(!error));
      Set(value, "nameSupport", fl_value_new_string("local")); Set(value, "connectionEvents", fl_value_new_bool(false));
      Set(value, "reason", fl_value_new_string(error ? error->message : !s->supported ? "BlueZ GATT/advertising interfaces unavailable" : !s->powered ? "Enable Bluetooth" : ""));
      fl_method_call_respond_success(retained.get(), value, nullptr);
    }); return;
  }
  if (!s->running) { MethodError(call, "disconnected", "Server is not running"); return; }
  auto found = s->fields.find(Arg(args, "characteristicUuid"));
  if (found == s->fields.end()) { MethodError(call, "invalid_data", "Unknown characteristic"); return; }
  auto& field = *found->second; auto value = Decode(Arg(args, "value"));
  if (value.size() > 512) { MethodError(call, "too_large", "Value exceeds ATT limit"); return; }
  if (method == "setValue") { field.value = std::move(value); fl_method_call_respond_success(call, nullptr, nullptr); return; }
  if (method == "notify") {
    if (!Has(field, "notify")) { MethodError(call, "unsupported", "Notifications unavailable"); return; }
    auto target = Arg(args, "clientId");
    if (!target.empty() && !field.peers.count(target)) { MethodError(call, "disconnected", "Client is not subscribed"); return; }
    for (const auto& peer : field.peers) if (target.empty() || target == peer.first) {
      if (value.size() > static_cast<size_t>(peer.second.mtu - 3)) { MethodError(call, "too_large", "Notification exceeds peer MTU"); return; }
    }
    s->notifications.erase(std::remove_if(s->notifications.begin(), s->notifications.end(), [](const std::weak_ptr<Notification>& n) { return n.expired(); }), s->notifications.end());
    if (s->notifications.size() >= 128) { MethodError(call, "busy", "Notification queue full"); return; }
    auto n = std::make_shared<Notification>(); n->state = s; n->call = FL_METHOD_CALL(g_object_ref(call));
    n->uuid = field.uuid; n->value = std::move(value); n->generation = s->generation;
    for (const auto& peer : field.peers) if (target.empty() || target == peer.first) n->targets.emplace_back(peer.first, peer.second.source);
    s->notifications.push_back(n);
    n->timer = g_timeout_add_full(G_PRIORITY_DEFAULT, 5000, [](gpointer p) -> gboolean {
      auto n = *static_cast<std::shared_ptr<Notification>*>(p); n->timer = 0;
      n->Finish("timeout", "Notification backpressure deadline exceeded"); return G_SOURCE_REMOVE;
    }, new std::shared_ptr<Notification>(n), [](gpointer p) { delete static_cast<std::shared_ptr<Notification>*>(p); });
    SendPending(n); return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}
} // namespace
void register_ble_peripheral(FlBinaryMessenger* messenger) {
  auto state = std::make_shared<Peripheral>();
  state->info = g_dbus_node_info_new_for_xml(kXml, nullptr);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(messenger, "universal_ble_server/methods", FL_METHOD_CODEC(codec));
  state->channel = channel;
  g_object_add_weak_pointer(G_OBJECT(channel), reinterpret_cast<gpointer*>(&state->channel));
  state->events = fl_event_channel_new(messenger, "universal_ble_server/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(state->events,
    [](FlEventChannel*, FlValue*, gpointer p) -> FlMethodErrorResponse* { if (auto s = static_cast<std::weak_ptr<Peripheral>*>(p)->lock()) s->listening = true; return nullptr; },
    [](FlEventChannel*, FlValue*, gpointer p) -> FlMethodErrorResponse* { if (auto s = static_cast<std::weak_ptr<Peripheral>*>(p)->lock()) s->listening = false; return nullptr; },
    new std::weak_ptr<Peripheral>(state), [](gpointer p) { delete static_cast<std::weak_ptr<Peripheral>*>(p); });
  fl_method_channel_set_method_call_handler(channel,
    [](FlMethodChannel*, FlMethodCall* call, gpointer p) { Handle(*static_cast<State*>(p), call); },
    new State(state), [](gpointer p) { delete static_cast<State*>(p); });
}
