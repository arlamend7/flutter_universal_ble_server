import 'native_transport.dart';
import 'transport.dart';

BleClientTransport createDefaultBleClientTransport() =>
    NativeBleClientTransport();
