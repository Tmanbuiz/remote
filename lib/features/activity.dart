import '../core/remote_key.dart';

enum StepKind { key, app, wait, wake }

class ActivityStep {
  const ActivityStep({
    required this.deviceId,
    required this.kind,
    required this.value,
  });
  final String deviceId;
  final StepKind kind;
  final String value;
  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'kind': kind.name,
    'value': value,
  };
  factory ActivityStep.fromJson(Map<String, dynamic> j) => ActivityStep(
    deviceId: j['deviceId'] as String,
    kind: StepKind.values.byName(j['kind'] as String),
    value: j['value'] as String,
  );
  RemoteKey get key => RemoteKey.values.byName(value);
}

class Activity {
  const Activity({required this.id, required this.name, required this.steps});
  final String id, name;
  final List<ActivityStep> steps;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'steps': steps.map((s) => s.toJson()).toList(),
  };
  factory Activity.fromJson(Map<String, dynamic> j) => Activity(
    id: j['id'] as String,
    name: j['name'] as String,
    steps: (j['steps'] as List)
        .map((s) => ActivityStep.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
  );
}
