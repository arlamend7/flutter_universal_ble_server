#include <sys/socket.h>
#if defined(__APPLE__)
// macOS lacks Unix SOCK_SEQPACKET. CI on Linux exercises the real socket type;
// this local portability test preserves datagram boundaries and FD passing.
#undef SOCK_SEQPACKET
#define SOCK_SEQPACKET SOCK_DGRAM
#include <cerrno>
inline ssize_t PacketSend(int fd, const void* data, size_t size, int flags) {
  auto result = ::send(fd, data, size, flags);
  if (result < 0 && errno == ENOBUFS) errno = EAGAIN;
  return result;
}
#define send PacketSend
#endif
#include "../../linux/ble_peripheral.cc"
#include "bluez_fixture.h"

static FlValue* Profile() {
  auto profile = fl_value_new_map(); Set(profile, "name", fl_value_new_string("Pi host")); Set(profile, "advertisedServiceUuid", fl_value_new_string("0000abcd-0000-1000-8000-00805f9b34fb"));
  auto services = fl_value_new_list(); auto service = fl_value_new_map(); Set(service, "uuid", fl_value_new_string("0000abcd-0000-1000-8000-00805f9b34fb"));
  auto fields = fl_value_new_list(); auto field = fl_value_new_map(); Set(field, "uuid", fl_value_new_string("0000abce-0000-1000-8000-00805f9b34fb")); Set(field, "value", fl_value_new_string("AAH/"));
  auto flags = fl_value_new_list(); for (auto flag : {"read", "write", "notify"}) fl_value_append_take(flags, fl_value_new_string(flag)); Set(field, "properties", flags);
  fl_value_append_take(fields, field); Set(service, "characteristics", fields); fl_value_append_take(services, service); Set(profile, "services", services); return profile;
}
static void Done(FlMethodCall* call, bool success = true) {
  Spin([&] { return g_object_get_data(call, "done") != nullptr; });
  if (success && !g_object_get_data(call, "success")) g_error("Call failed: %s", static_cast<char*>(g_object_get_data(call, "message")));
  g_assert_cmpint(g_object_get_data(call, "success") != nullptr, ==, success);
}
static GVariant* Options(const char* device, int offset = 0) {
  GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&b, "{sv}", "device", g_variant_new_object_path(device));
  g_variant_builder_add(&b, "{sv}", "mtu", g_variant_new_uint16(23));
  g_variant_builder_add(&b, "{sv}", "offset", g_variant_new_uint16(offset)); return g_variant_builder_end(&b);
}
static State Server() {
  register_ble_peripheral(nullptr);
  auto channel = fake_flutter::channels.at("universal_ble_server/methods");
  auto handler = static_cast<fake_flutter::Handler*>(g_object_get_data(channel, "handler"));
  return *static_cast<State*>(handler->data);
}
static void RunServerTests() {
  BluezFixture bluez; auto s = Server();
  g_autoptr(FlValue) profile = Profile();
  g_autoptr(FlMethodCall) start = fake_flutter::Call("startServer", profile); Handle(s, start); Done(start);
  g_assert_true(s->running); g_assert_cmpint(bluez.applications, ==, 1); g_assert_cmpint(bluez.advertisements, ==, 1);
  auto& field = *s->fields.begin()->second;
  DBusReply advert;
  Invoke(bluez.bus, bluez.application, kAdvert, "org.freedesktop.DBus.Properties", "GetAll", g_variant_new("(s)", "org.bluez.LEAdvertisement1"), advert);
  g_assert_no_error(advert.error); g_autofree gchar* printed = g_variant_print(advert.value, true); g_assert_nonnull(strstr(printed, "Pi host"));
  g_test_message("GATT registration introspection, advertising name and service passed");

  fake_flutter::dart_request = [&](FlValue* args) {
    const auto device = Arg(args, "clientId");
    g_assert_cmpstr(device.c_str(), ==, bluez.deviceA);
    auto answer = fl_value_new_map(); Set(answer, "status", fl_value_new_int(0));
    Set(answer, "value", fl_value_new_string(Arg(args, "type") == "read" ? "AAH/" : Arg(args, "value").c_str())); return answer;
  };
  DBusReply read;
  Invoke(bluez.bus, bluez.application, field.path, "org.bluez.GattCharacteristic1", "ReadValue", g_variant_new("(@a{sv})", Options(bluez.deviceA, 1)), read);
  g_assert_no_error(read.error); g_autoptr(GVariant) bytes = g_variant_get_child_value(read.value, 0); gsize length;
  auto data = static_cast<const guint8*>(g_variant_get_fixed_array(bytes, &length, 1)); g_assert_cmpuint(length, ==, 2); g_assert_cmpuint(data[1], ==, 255);
  DBusReply write;
  Invoke(bluez.bus, bluez.application, field.path, "org.bluez.GattCharacteristic1", "WriteValue", g_variant_new("(@ay@a{sv})", Bytes({7, 8}), Options(bluez.deviceA)), write);
  g_assert_no_error(write.error); g_assert_true(field.value == std::vector<guint8>({7, 8}));
  fake_flutter::dart_request = [](FlValue*) { auto a = fl_value_new_map(); Set(a, "status", fl_value_new_int(8)); return a; };
  DBusReply denied;
  Invoke(bluez.bus, bluez.application, field.path, "org.bluez.GattCharacteristic1", "WriteValue", g_variant_new("(@ay@a{sv})", Bytes({9}), Options(bluez.deviceA)), denied);
  g_assert_nonnull(denied.error); g_assert_true(field.value == std::vector<guint8>({7, 8}));
  g_test_message("Dynamic read, offsets, accepted write and authorization rejection passed");

  int peers[2]; int index = 0;
  for (const char* device : {bluez.deviceA, bluez.deviceB}) {
    DBusReply acquire;
    Invoke(bluez.bus, bluez.application, field.path, "org.bluez.GattCharacteristic1", "AcquireNotify", g_variant_new("(@a{sv})", Options(device)), acquire);
    g_assert_no_error(acquire.error); gint32 fd; guint16 mtu; g_variant_get(acquire.value, "(hq)", &fd, &mtu); g_assert_cmpint(mtu, ==, 23);
    peers[index++] = g_unix_fd_list_get(acquire.fds, fd, nullptr); fcntl(peers[index - 1], F_SETFL, O_NONBLOCK);
  }
  g_assert_cmpuint(field.peers.size(), ==, 2);
  g_autoptr(FlValue) notify = fl_value_new_map(); Set(notify, "characteristicUuid", fl_value_new_string(field.uuid.c_str()));
  Set(notify, "value", fl_value_new_string("AQI=")); Set(notify, "clientId", fl_value_new_string(bluez.deviceA));
  g_autoptr(FlMethodCall) send = fake_flutter::Call("notify", notify); Handle(s, send); Done(send);
  guint8 packet[64]; g_assert_cmpint(recv(peers[0], packet, sizeof(packet), 0), ==, 2); g_assert_cmpint(packet[1], ==, 2);
  g_assert_cmpint(recv(peers[1], packet, sizeof(packet), 0), ==, -1); g_assert_cmpint(errno, ==, EAGAIN);
  Set(notify, "clientId", fl_value_new_string(""));
  g_autoptr(FlMethodCall) broadcast = fake_flutter::Call("notify", notify); Handle(s, broadcast); Done(broadcast);
  for (int fd : peers) g_assert_cmpint(recv(fd, packet, sizeof(packet), 0), ==, 2);
  // Fill one socket, then verify the method waits instead of dropping a frame.
  std::vector<guint8> filler(20, 9); auto fd = field.peers.at(bluez.deviceA).fd;
  int count = 0;
  while (::send(fd, filler.data(), filler.size(), MSG_DONTWAIT | MSG_NOSIGNAL) >= 0 && count < 10000) ++count;
  g_assert_cmpint(count, <, 10000); g_assert_cmpint(errno, ==, EAGAIN);
  Set(notify, "clientId", fl_value_new_string(bluez.deviceA));
  g_autoptr(FlMethodCall) blocked = fake_flutter::Call("notify", notify); Handle(s, blocked);
  g_assert_null(g_object_get_data(blocked, "done"));
  while (recv(peers[0], packet, sizeof(packet), 0) >= 0) {}
  Done(blocked); g_assert_cmpint(recv(peers[0], packet, sizeof(packet), 0), ==, 2);
  Set(notify, "clientId", fl_value_new_string(""));
  Set(notify, "value", fl_value_new_string("AAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
  g_autoptr(FlMethodCall) oversized = fake_flutter::Call("notify", notify); Handle(s, oversized); Done(oversized, false);
  for (int fd : peers) g_assert_cmpint(recv(fd, packet, sizeof(packet), 0), ==, -1);
  close(peers[0]);
#if defined(__APPLE__)
  // Datagram socketpairs do not report peer HUP on macOS. Linux CI exercises
  // the actual fd watcher; here invoke the same cleanup path explicitly.
  RemovePeer(*s, field, bluez.deviceA);
#endif
  Spin([&] { return field.peers.size() == 1; });
  g_test_message("Targeted privacy, broadcast, MTU rejection and peer disconnect passed");

  auto stranger = Bus(g_test_dbus_get_bus_address(bluez.daemon)); DBusReply unauthorized;
  Invoke(stranger, bluez.application, field.path, "org.bluez.GattCharacteristic1", "AcquireNotify", g_variant_new("(@a{sv})", Options(bluez.deviceA)), unauthorized);
  g_assert_nonnull(unauthorized.error); g_dbus_connection_close_sync(stranger, nullptr, nullptr); g_object_unref(stranger);
  bluez.PowerOff(); Spin([&] { return !s->running; });
  close(peers[1]); g_assert_true(s->fields.empty());
  g_test_message("Untrusted D-Bus caller rejection and adapter shutdown cleanup passed");
  s.reset(); fake_flutter::Clear();
}
static void Rollback() {
  BluezFixture bluez; bluez.rejectAdvertisement = true; auto s = Server();
  g_autoptr(FlValue) profile = Profile();
  g_autoptr(FlMethodCall) start = fake_flutter::Call("startServer", profile); Handle(s, start); Done(start, false);
  g_assert_false(s->running); g_assert_null(s->bus); g_assert_true(s->registrations.empty());
  bluez.rejectAdvertisement = false;
  g_autoptr(FlMethodCall) retry = fake_flutter::Call("startServer", profile); Handle(s, retry); Done(retry);
  Reset(*s); s.reset(); fake_flutter::Clear();
}
static void NameFallback() {
  BluezFixture bluez; auto s = Server();
  g_autoptr(FlValue) profile = Profile();
  bluez.advertisementRejections = 1;
  g_autoptr(FlMethodCall) start = fake_flutter::Call("startServer", profile); Handle(s, start); Done(start);
  g_assert_true(s->running); g_assert_true(s->name.empty());
  g_assert_cmpint(bluez.advertisements, ==, 2);
  Reset(*s);
  bluez.advertisementRejections = 1;
  Set(profile, "requireAdvertisedName", fl_value_new_bool(true));
  g_autoptr(FlMethodCall) strict = fake_flutter::Call("startServer", profile); Handle(s, strict); Done(strict, false);
  g_assert_cmpint(bluez.advertisements, ==, 3);
  g_assert_false(s->running); g_assert_null(s->bus);
  s.reset(); fake_flutter::Clear();
}
static void CancelCapability() {
  BluezFixture bluez; auto s = Server();
  g_autoptr(FlMethodCall) oldCheck = fake_flutter::Call("checkSupport"); Handle(s, oldCheck);
  Reset(*s);
  g_autoptr(FlMethodCall) newCheck = fake_flutter::Call("checkSupport"); Handle(s, newCheck);
  Done(oldCheck, false); Done(newCheck);
  g_assert_true(s->supported); g_assert_true(s->powered); g_assert_false(s->checking);
  Reset(*s); s.reset(); fake_flutter::Clear();
}
int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add_func("/bluez/peripheral/communication", RunServerTests);
  g_test_add_func("/bluez/peripheral/registration-rollback", Rollback);
  g_test_add_func("/bluez/peripheral/advertised-name-fallback", NameFallback);
  g_test_add_func("/bluez/peripheral/cancel-capability", CancelCapability);
  return g_test_run();
}
