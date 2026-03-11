import 'package:omsg_app/src/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds public profile url from api base', () {
    const api = AstraApi(baseUrl: 'https://volds.ru');
    expect(
      api.publicProfileUrl('@Alice_Name'),
      'https://volds.ru/u/alice_name',
    );
  });

  test('extracts username from https profile uri', () {
    expect(
      publicProfileUsernameFromUri(Uri.parse('https://volds.ru/u/alice_name')),
      'alice_name',
    );
  });

  test('extracts username from custom scheme uri', () {
    expect(
      publicProfileUsernameFromUri(Uri.parse('omsg://u/alice_name')),
      'alice_name',
    );
  });
}
