import 'package:flutter_test/flutter_test.dart';
import 'package:score67_control/device_link.dart';

void main() {
  test('connect code comes from a full link, a fragment or the bare code', () {
    const code = 'AbCdEfGhIjKlMnOpQrStUvWx';
    expect(connectCode('https://score67.de/dashboard#connect=$code'), code);
    expect(connectCode(' connect=$code '), code);
    expect(connectCode(code), code);
    expect(connectCode('https://score67.de/s/abc'), isNull);
    expect(connectCode('short'), isNull);
  });
}
