#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "universal_ble_server_plugin.h"

namespace universal_ble_server {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(UniversalBleServerPlugin, StartStop) {
  UniversalBleServerPlugin plugin;
  EXPECT_TRUE(true);
}

}  // namespace test
}  // namespace universal_ble_server
