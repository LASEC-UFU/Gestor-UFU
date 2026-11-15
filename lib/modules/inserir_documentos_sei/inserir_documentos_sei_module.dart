import 'package:flutter/material.dart';

import 'package:gestor_ufu/platform/module/gestor_module.dart';

/// Módulo planejado "Inserir Documentos no SEI" — ainda sem tela (cartão
/// desativado no painel).
class InserirDocumentosSeiModule extends GestorModule {
  const InserirDocumentosSeiModule();

  @override
  String get id => 'inserir-documentos-sei';

  @override
  String get title => 'Inserir Documentos no SEI';

  @override
  String get description =>
      'Insira fichas de componentes curriculares no processo do SEI.';

  @override
  IconData get icon => Icons.topic_rounded;

  @override
  Color get accent => const Color(0xFFFFB454);

  @override
  String get category => 'PROCESSOS E DOCUMENTOS';

  @override
  String? get route => null;
}
