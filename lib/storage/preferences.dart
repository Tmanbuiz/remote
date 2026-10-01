import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/activity.dart';

class Preferences extends ChangeNotifier {
  Preferences(this.prefs);
  final SharedPreferences prefs;
  bool get simple => prefs.getBool('simple') ?? false;
  bool get leftHanded => prefs.getBool('leftHanded') ?? false;
  bool get haptics => prefs.getBool('haptics') ?? true;
  bool get spoken => prefs.getBool('spoken') ?? false;
  bool get learn => prefs.getBool('learn') ?? false;
  String room(String id) => prefs.getString('room:$id') ?? 'My room';
  String alias(String id, String app, String fallback) =>
      prefs.getString('alias:$id:$app') ?? fallback;
  List<String> favourites(String id) =>
      prefs.getStringList('favourites:$id') ?? [];
  Future<void> setBool(String key, bool value) async {
    await prefs.setBool(key, value);
    if (key == 'learn' && !value) {
      for (final k
          in prefs.getKeys().where((k) => k.startsWith('usage:')).toList()) {
        await prefs.remove(k);
      }
    }
    notifyListeners();
  }

  Future<void> setRoom(String id, String value) async {
    await prefs.setString(
      'room:$id',
      value.trim().isEmpty ? 'My room' : value.trim(),
    );
    notifyListeners();
  }

  Future<void> setAlias(String id, String app, String value) async {
    await prefs.setString('alias:$id:$app', value.trim());
    notifyListeners();
  }

  Future<void> favourite(String id, String app) async {
    final all = favourites(id);
    all.contains(app) ? all.remove(app) : all.add(app);
    await prefs.setStringList('favourites:$id', all);
    notifyListeners();
  }

  Future<void> recordLaunch(String device, String app) async {
    if (!learn) return;
    final key = 'usage:$device:$app';
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + 1);
    notifyListeners();
  }

  int launches(String device, String app) =>
      prefs.getInt('usage:$device:$app') ?? 0;
  List<Activity> get activities {
    final out = <Activity>[];
    for (final s in prefs.getStringList('activities') ?? <String>[]) {
      try {
        out.add(Activity.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {
        /* Skip damaged records. */
      }
    }
    return out;
  }

  Future<void> saveActivity(Activity a) async {
    final all = activities..removeWhere((v) => v.id == a.id);
    all.add(a);
    await prefs.setStringList(
      'activities',
      all.map((v) => jsonEncode(v.toJson())).toList(),
    );
    notifyListeners();
  }

  Future<void> removeActivity(String id) async {
    await prefs.setStringList(
      'activities',
      activities
          .where((v) => v.id != id)
          .map((v) => jsonEncode(v.toJson()))
          .toList(),
    );
    notifyListeners();
  }
}
