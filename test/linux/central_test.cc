#include "../../linux/ble_central.cc"
#include "bluez_fixture.h"
static FlMethodCall* Send(const std::string& channel, const char* method, FlValue* args = nullptr) {
  auto c = fake_flutter::channels.at(channel);
  auto handler = static_cast<fake_flutter::Handler*>(g_object_get_data(c, "handler"));
  auto call = fake_flutter::Call(method, args); handler->method(c, call, handler->data); return call;
}
static void Done(FlMethodCall* call, bool success = true) {
  Spin([&] { return g_object_get_data(call, "done") != nullptr; });
  if (success && !g_object_get_data(call, "success")) g_error("Call failed: %s", static_cast<char*>(g_object_get_data(call, "message")));
  g_assert_cmpint(g_object_get_data(call, "success") != nullptr, ==, success);
}
static void Clients() {
  BluezFixture bluez; register_ble_central(nullptr);
  const std::string root = "universal_ble_server/client/";
  for (const char* name : {"a", "b", "duplicate"}) {
    g_autoptr(FlValue) args = fl_value_new_map(); Set(args, "session", fl_value_new_string(name));
    g_autoptr(FlMethodCall) call = Send(root + "methods", "createClient", args); Done(call);
  }
  auto a = root + "a/methods", b = root + "b/methods";
  // Concurrent initialization/operations must not share native busy state.
  g_autoptr(FlMethodCall) supportA = Send(a, "checkSupport");
  g_autoptr(FlMethodCall) supportB = Send(b, "checkSupport"); Done(supportA); Done(supportB);
  g_autoptr(FlValue) argA = fl_value_new_map(); Set(argA, "id", fl_value_new_string(bluez.deviceA));
  g_autoptr(FlValue) argB = fl_value_new_map(); Set(argB, "id", fl_value_new_string(bluez.deviceB));
  g_autoptr(FlMethodCall) connectA = Send(a, "connect", argA);
  g_autoptr(FlMethodCall) connectB = Send(b, "connect", argB); Done(connectA); Done(connectB);
  g_assert_cmpuint(bluez.connected.size(), ==, 2);
  g_autoptr(FlMethodCall) duplicate = Send(root + "duplicate/methods", "connect", argA); Done(duplicate, false);
  g_assert_cmpstr(static_cast<const char*>(g_object_get_data(duplicate, "error")), ==, "busy");
  g_autoptr(FlMethodCall) disposeDuplicate = Send(root + "duplicate/methods", "dispose"); Done(disposeDuplicate);
  g_assert_true(bluez.disconnected.empty());
  g_autoptr(FlMethodCall) discoverA = Send(a, "discover");
  g_autoptr(FlMethodCall) discoverB = Send(b, "discover"); Done(discoverA); Done(discoverB);
  g_autoptr(FlValue) key = fl_value_new_map(); Set(key, "key", fl_value_new_string("0000abcd-0000-1000-8000-00805f9b34fb/0000abce-0000-1000-8000-00805f9b34fb"));
  g_autoptr(FlMethodCall) readA = Send(a, "read", key); Done(readA);
  g_assert_cmpstr(fl_value_get_string(static_cast<FlValue*>(g_object_get_data(readA, "value"))), ==, "AAH/");
  g_autoptr(FlMethodCall) disposeA = Send(a, "dispose"); Done(disposeA);
  g_assert_cmpuint(bluez.disconnected.size(), ==, 1); g_assert_true(bluez.disconnected[0] == bluez.deviceA);
  g_autoptr(FlMethodCall) readB = Send(b, "read", key); Done(readB);
  Set(key, "value", fl_value_new_string("AP8="));
  g_autoptr(FlMethodCall) writeB = Send(b, "write", key); Done(writeB); g_assert_true(bluez.written == std::vector<guint8>({0,255}));
  g_autoptr(FlMethodCall) disposeB = Send(b, "dispose"); Done(disposeB);
  g_assert_cmpuint(bluez.disconnected.size(), ==, 2); g_assert_true(bluez.disconnected[1] == bluez.deviceB);
  g_test_message("Independent concurrent sessions, duplicate-device exclusion and selective disposal passed");
  fake_flutter::Clear();
}
int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr); g_test_add_func("/bluez/central/multiple-peripherals", Clients); return g_test_run();
}
