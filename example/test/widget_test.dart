// Smoke test for the demo dashboard.
//
// The page kicks off a live measurement in initState, which needs plugins
// (connectivity, battery, device info, geolocator, preferences) that aren't
// available in a widget test. So this builds the widget tree without
// pumping the post-frame callback that starts the run, which is enough to
// catch layout and construction errors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_quality_example/main.dart';

void main() {
  testWidgets('dashboard builds and shows its shell', (tester) async {
    await tester.pumpWidget(const NetworkQualityDemoApp());

    expect(find.text('Network Quality'), findsOneWidget);
    expect(find.text('Measure'), findsOneWidget);
    // Hero metrics render with placeholders before any data arrives.
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Latency'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
