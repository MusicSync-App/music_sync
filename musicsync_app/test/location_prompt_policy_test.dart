import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicsync_app/radio/location_prompt_policy.dart';

void main() {
  group('decideLocationAction', () {
    test('granted -> silent, never a prompt', () {
      for (final asked in [true, false]) {
        for (final user in [true, false]) {
          expect(
            decideLocationAction(status: LocationPermissionStatus.granted, alreadyAsked: asked, userInitiated: user),
            LocationAction.useSilently,
          );
        }
      }
    });

    test('denied: asks automatically only the first time', () {
      expect(
        decideLocationAction(status: LocationPermissionStatus.denied, alreadyAsked: false, userInitiated: false),
        LocationAction.requestPermission,
      );
      expect(
        decideLocationAction(status: LocationPermissionStatus.denied, alreadyAsked: true, userInitiated: false),
        LocationAction.showHint,
      );
    });

    test('denied: a button tap may ask again', () {
      expect(
        decideLocationAction(status: LocationPermissionStatus.denied, alreadyAsked: true, userInitiated: true),
        LocationAction.requestPermission,
      );
    });

    test('denied forever: hint automatically, settings on tap', () {
      expect(
        decideLocationAction(status: LocationPermissionStatus.deniedForever, alreadyAsked: false, userInitiated: false),
        LocationAction.showHint,
      );
      expect(
        decideLocationAction(status: LocationPermissionStatus.deniedForever, alreadyAsked: true, userInitiated: true),
        LocationAction.openAppSettings,
      );
    });
  });

  test('service-off dialog shown automatically at most once', () {
    expect(shouldAutoPromptServiceOff(alreadyShown: false, userInitiated: false), isTrue);
    expect(shouldAutoPromptServiceOff(alreadyShown: true, userInitiated: false), isFalse);
    expect(shouldAutoPromptServiceOff(alreadyShown: true, userInitiated: true), isTrue);
  });

  test('LocationPromptMemory survives a "restart"', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await LocationPromptMemory.load();
    expect(first.permissionAsked, isFalse);
    expect(first.lastChoice, isNull);
    await first.markPermissionAsked();
    await first.markServicePromptShown();
    await first.rememberChoice(LocationPermissionStatus.denied);

    final again = await LocationPromptMemory.load();
    expect(again.permissionAsked, isTrue);
    expect(again.servicePromptShown, isTrue);
    expect(again.lastChoice, 'denied');
    // A second automatic open no longer prompts.
    expect(
      decideLocationAction(
        status: LocationPermissionStatus.denied,
        alreadyAsked: again.permissionAsked,
        userInitiated: false,
      ),
      LocationAction.showHint,
    );
  });
}
