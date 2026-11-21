/// Când are voie aplicația să ceară locația — funcții pure, testabile.
///
/// Regula: utilizatorul e întrebat de sistem cel mult o dată automat (la
/// prima deschidere a ecranului Radio). După aceea:
/// - permisiune dată -> locația e folosită în tăcere;
/// - permisiune refuzată -> NU mai întrebăm singuri; apare doar bara
///   portocalie cu butonul "Pornește" (cererea vine numai la apăsare).
library;

import 'package:shared_preferences/shared_preferences.dart';

/// Starea permisiunii, independentă de plugin (ușor de testat).
enum LocationPermissionStatus { granted, denied, deniedForever }

enum LocationAction {
  /// Permisiune dată — citim poziția fără niciun dialog.
  useSilently,

  /// Cerem permisiunea prin dialogul sistemului.
  requestPermission,

  /// Refuzată permanent — doar setările aplicației o mai pot schimba.
  openAppSettings,

  /// Nu întrebăm nimic; arătăm doar indiciul din bara de locație.
  showHint,
}

/// [alreadyAsked] = am cerut deja automat permisiunea (ținut minte în
/// preferințe, peste reporniri). [userInitiated] = utilizatorul a apăsat
/// un buton de locație.
LocationAction decideLocationAction({
  required LocationPermissionStatus status,
  required bool alreadyAsked,
  required bool userInitiated,
}) {
  switch (status) {
    case LocationPermissionStatus.granted:
      return LocationAction.useSilently;
    case LocationPermissionStatus.denied:
      if (userInitiated || !alreadyAsked) return LocationAction.requestPermission;
      return LocationAction.showHint;
    case LocationPermissionStatus.deniedForever:
      return userInitiated ? LocationAction.openAppSettings : LocationAction.showHint;
  }
}

/// Dialogul "Locația telefonului e oprită" apare automat cel mult o dată
/// (în viața instalării); apoi doar la apăsarea butonului.
bool shouldAutoPromptServiceOff({required bool alreadyShown, required bool userInitiated}) =>
    userInitiated || !alreadyShown;

/// Ce a ales utilizatorul, ținut minte între deschideri / reporniri.
class LocationPromptMemory {
  static const String kAskedKey = 'location_permission_asked';
  static const String kChoiceKey = 'location_permission_choice';
  static const String kServicePromptKey = 'location_service_prompt_shown';

  final SharedPreferences _prefs;
  LocationPromptMemory(this._prefs);

  static Future<LocationPromptMemory> load() async => LocationPromptMemory(await SharedPreferences.getInstance());

  bool get permissionAsked => _prefs.getBool(kAskedKey) ?? false;
  bool get servicePromptShown => _prefs.getBool(kServicePromptKey) ?? false;

  /// 'granted' / 'denied' / null (încă neîntrebat).
  String? get lastChoice => _prefs.getString(kChoiceKey);

  Future<void> markPermissionAsked() => _prefs.setBool(kAskedKey, true);
  Future<void> markServicePromptShown() => _prefs.setBool(kServicePromptKey, true);

  Future<void> rememberChoice(LocationPermissionStatus status) =>
      _prefs.setString(kChoiceKey, status == LocationPermissionStatus.granted ? 'granted' : 'denied');
}
