import 'package:cockpit/app/core/domain/entities/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloneRoot ausente por padrão (pergunta no primeiro clone)', () {
    expect(const AppSettings().cloneRoot, isNull);
    expect(const AppSettings().toJson().containsKey('clone.root'), isFalse);
    expect(AppSettings.fromJson(const {}).cloneRoot, isNull);
  });

  test('cloneRoot persiste no JSON, inclusive caminho de Windows', () {
    for (final path in ['/Users/rafgl/Projetos', r'C:\Users\rafgl\Projetos']) {
      final json = const AppSettings().copyWith(cloneRoot: path).toJson();
      expect(json['clone.root'], path);
      expect(AppSettings.fromJson(json).cloneRoot, path);
    }
  });

  test('copyWith sem cloneRoot preserva o valor', () {
    final s = const AppSettings().copyWith(cloneRoot: '/p');
    expect(s.copyWith(codeSize: 14).cloneRoot, '/p');
  });
}
