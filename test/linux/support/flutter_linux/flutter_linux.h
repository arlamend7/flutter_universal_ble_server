#pragma once
// Test-only Flutter channel/value adapter. The production BlueZ implementation
// is compiled unchanged against real GLib/GIO; no radio or Flutter engine here.
#include <gio/gio.h>
#include <map>
#include <vector>
#include <string>
#include <functional>

enum FlValueType { FL_VALUE_TYPE_NULL, FL_VALUE_TYPE_BOOL, FL_VALUE_TYPE_INT, FL_VALUE_TYPE_STRING, FL_VALUE_TYPE_LIST, FL_VALUE_TYPE_MAP };
struct FlValue {
  FlValueType type; int refs = 1; bool boolean = false; int64_t integer = 0;
  std::string text; std::vector<FlValue*> list; std::map<std::string, FlValue*> map;
  explicit FlValue(FlValueType t) : type(t) {}
};
inline FlValue* fl_value_ref(FlValue* v) { if (v) ++v->refs; return v; }
inline void fl_value_unref(FlValue* v) { if (!v || --v->refs) return; for (auto p : v->list) fl_value_unref(p); for (auto p : v->map) fl_value_unref(p.second); delete v; }
G_DEFINE_AUTOPTR_CLEANUP_FUNC(FlValue, fl_value_unref)
inline FlValue* fl_value_new_map() { return new FlValue(FL_VALUE_TYPE_MAP); }
inline FlValue* fl_value_new_list() { return new FlValue(FL_VALUE_TYPE_LIST); }
inline FlValue* fl_value_new_string(const char* s) { auto v = new FlValue(FL_VALUE_TYPE_STRING); v->text = s; return v; }
inline FlValue* fl_value_new_bool(bool b) { auto v = new FlValue(FL_VALUE_TYPE_BOOL); v->boolean = b; return v; }
inline FlValue* fl_value_new_int(int64_t i) { auto v = new FlValue(FL_VALUE_TYPE_INT); v->integer = i; return v; }
inline void fl_value_set_string_take(FlValue* m, const char* key, FlValue* v) { fl_value_unref(m->map[key]); m->map[key] = v; }
inline FlValue* fl_value_lookup_string(FlValue* m, const char* key) { auto it = m->map.find(key); return it == m->map.end() ? nullptr : it->second; }
inline void fl_value_append_take(FlValue* l, FlValue* v) { l->list.push_back(v); }
inline FlValue* fl_value_get_list_value(FlValue* l, size_t n) { return l->list.at(n); }
inline size_t fl_value_get_length(FlValue* v) { return v->type == FL_VALUE_TYPE_LIST ? v->list.size() : v->map.size(); }
inline FlValueType fl_value_get_type(FlValue* v) { return v ? v->type : FL_VALUE_TYPE_NULL; }
inline const char* fl_value_get_string(FlValue* v) { return v->text.c_str(); }
inline bool fl_value_get_bool(FlValue* v) { return v->boolean; }
inline int64_t fl_value_get_int(FlValue* v) { return v->integer; }
using FlMethodCall = GObject;
using FlMethodChannel = GObject;
using FlEventChannel = GObject;
using FlMethodResponse = GObject;
using FlMethodErrorResponse = GObject;
using FlMethodSuccessResponse = GObject;
using FlStandardMethodCodec = GObject;
using FlMethodCodec = GObject;
using FlBinaryMessenger = GObject;
#define FL_METHOD_CALL(x) ((FlMethodCall*)(x))
#define FL_METHOD_CHANNEL(x) ((FlMethodChannel*)(x))
#define FL_METHOD_CODEC(x) ((FlMethodCodec*)(x))
#define FL_METHOD_SUCCESS_RESPONSE(x) ((FlMethodSuccessResponse*)(x))
#define FL_IS_METHOD_SUCCESS_RESPONSE(x) (g_object_get_data(G_OBJECT(x), "success") != nullptr)
G_DEFINE_AUTOPTR_CLEANUP_FUNC(FlMethodCall, g_object_unref)
G_DEFINE_AUTOPTR_CLEANUP_FUNC(FlMethodChannel, g_object_unref)
G_DEFINE_AUTOPTR_CLEANUP_FUNC(FlMethodResponse, g_object_unref)
G_DEFINE_AUTOPTR_CLEANUP_FUNC(FlStandardMethodCodec, g_object_unref)
namespace fake_flutter {
inline std::map<std::string, GObject*> channels;
inline std::vector<FlValue*> events;
inline std::function<FlValue*(FlValue*)> dart_request;
struct Handler { void (*method)(FlMethodChannel*, FlMethodCall*, gpointer) = nullptr; gpointer data = nullptr; GDestroyNotify destroy = nullptr; ~Handler() { if (destroy) destroy(data); } };
struct Stream { gpointer data; GDestroyNotify destroy; ~Stream() { if (destroy) destroy(data); } };
inline GObject* Object() { return G_OBJECT(g_object_new(G_TYPE_OBJECT, nullptr)); }
inline GObject* Channel(const char* name) {
  auto object = Object(); channels[name] = G_OBJECT(g_object_ref(object)); return object;
}
inline FlMethodCall* Call(const char* method, FlValue* args = nullptr) {
  auto object = Object(); g_object_set_data_full(object, "method", g_strdup(method), g_free);
  g_object_set_data_full(object, "args", fl_value_ref(args), [](gpointer p) { fl_value_unref(static_cast<FlValue*>(p)); }); return object;
}
inline void Clear() {
  for (auto& c : channels) { g_object_set_data(c.second, "handler", nullptr); g_object_set_data(c.second, "stream", nullptr); }
  for (auto& c : channels) g_object_unref(c.second); channels.clear();
  for (auto* e : events) fl_value_unref(e); events.clear(); dart_request = {};
}
}
inline FlStandardMethodCodec* fl_standard_method_codec_new() { return fake_flutter::Object(); }
inline FlMethodChannel* fl_method_channel_new(FlBinaryMessenger*, const char* name, FlMethodCodec*) { return fake_flutter::Channel(name); }
inline FlEventChannel* fl_event_channel_new(FlBinaryMessenger*, const char* name, FlMethodCodec*) { return fake_flutter::Channel(name); }
inline void fl_method_channel_set_method_call_handler(FlMethodChannel* c, void (*handler)(FlMethodChannel*, FlMethodCall*, gpointer), gpointer data, GDestroyNotify destroy) {
  auto h = new fake_flutter::Handler{handler, data, destroy}; g_object_set_data_full(c, "handler", h, [](gpointer p) { delete static_cast<fake_flutter::Handler*>(p); });
}
inline void fl_event_channel_set_stream_handlers(FlEventChannel* c, FlMethodErrorResponse* (*listen)(FlEventChannel*, FlValue*, gpointer), FlMethodErrorResponse* (*)(FlEventChannel*, FlValue*, gpointer), gpointer data, GDestroyNotify destroy) {
  g_object_set_data_full(c, "stream", new fake_flutter::Stream{data, destroy}, [](gpointer p) { delete static_cast<fake_flutter::Stream*>(p); });
  if (listen) listen(c, nullptr, data);
}
inline const char* fl_method_call_get_name(FlMethodCall* c) { return static_cast<const char*>(g_object_get_data(c, "method")); }
inline FlValue* fl_method_call_get_args(FlMethodCall* c) { return static_cast<FlValue*>(g_object_get_data(c, "args")); }
inline gboolean fl_method_call_respond_success(FlMethodCall* c, FlValue* v, GError**) {
  g_object_set_data(c, "done", GINT_TO_POINTER(1)); g_object_set_data(c, "success", GINT_TO_POINTER(1));
  g_object_set_data_full(c, "value", fl_value_ref(v), [](gpointer p) { fl_value_unref(static_cast<FlValue*>(p)); }); return true;
}
inline gboolean fl_method_call_respond_error(FlMethodCall* c, const char* code, const char* message, FlValue*, GError**) {
  g_object_set_data(c, "done", GINT_TO_POINTER(1)); g_object_set_data_full(c, "error", g_strdup(code), g_free);
  g_object_set_data_full(c, "message", g_strdup(message), g_free); return true;
}
inline gboolean fl_method_call_respond_not_implemented(FlMethodCall* c, GError** e) { return fl_method_call_respond_error(c, "unsupported", "Not implemented", nullptr, e); }
inline gboolean fl_event_channel_send(FlEventChannel*, FlValue* v, GCancellable*, GError**) { fake_flutter::events.push_back(fl_value_ref(v)); return true; }
inline gboolean fl_event_channel_send_error(FlEventChannel*, const char*, const char*, FlValue*, GCancellable*, GError**) { return true; }
inline FlValue* fl_method_success_response_get_result(FlMethodSuccessResponse* r) { return static_cast<FlValue*>(g_object_get_data(r, "value")); }
inline void fl_method_channel_invoke_method(FlMethodChannel* c, const char*, FlValue* args, GCancellable* cancel, GAsyncReadyCallback callback, gpointer data) {
  g_autoptr(GTask) task = g_task_new(c, cancel, callback, data);
  auto response = fake_flutter::Object();
  g_autoptr(FlValue) answer = fake_flutter::dart_request(args);
  fl_method_call_respond_success(response, answer, nullptr);
  g_task_return_pointer(task, response, g_object_unref);
}
inline FlMethodResponse* fl_method_channel_invoke_method_finish(FlMethodChannel*, GAsyncResult* result, GError** error) { return G_OBJECT(g_task_propagate_pointer(G_TASK(result), error)); }
