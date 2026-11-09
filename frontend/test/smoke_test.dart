import 'package:flutter_test/flutter_test.dart';

import 'package:personfin/main.dart';

void main() {
  testWidgets('app builds and shows placeholder text', (tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('PersonFin'), findsOneWidget);
  });
}
