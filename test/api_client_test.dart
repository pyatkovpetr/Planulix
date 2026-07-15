import 'package:flutter_test/flutter_test.dart';
import 'package:planulix/api/client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'server URL without token is a valid local connection profile',
    () async {
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient();

      await api.saveSettings('http://localhost:4096', '');

      expect(api.baseUrl, 'http://localhost:4096/api');
      expect(api.authToken, isNull);
      expect(api.isConfigured, isTrue);
    },
  );
}
