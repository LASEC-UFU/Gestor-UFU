import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'package:gestor_ufu/data/services/ai_agent/agent_history.dart';
import 'package:gestor_ufu/data/services/ai_agent/agent_settings.dart';

/// Cores no estilo do painel de chat do VS Code.
class VsColors {
  const VsColors(this.dark);

  final bool dark;

  static VsColors of(BuildContext context) =>
      VsColors(Theme.of(context).brightness == Brightness.dark);

  Color get bg => dark ? const Color(0xFF1F1F1F) : const Color(0xFFF3F3F3);
  Color get card => dark ? const Color(0xFF282828) : Colors.white;
  Color get border => dark ? const Color(0xFF3C3C3C) : const Color(0xFFDADADA);
  Color get text => dark ? const Color(0xFFE4E4E4) : const Color(0xFF1F1F1F);
  Color get muted => dark ? const Color(0xFF9A9A9A) : const Color(0xFF6F6F6F);
  Color get hover => dark ? const Color(0xFF2F3033) : const Color(0xFFE6E6E6);
  Color get chip => dark ? const Color(0xFF353535) : const Color(0xFFE8E8E8);
  Color get tab => dark ? const Color(0xFF37373D) : const Color(0xFFE1E4F0);
  Color get accent => const Color(0xFF0A6ED1);
  Color get selection =>
      dark ? const Color(0xFF04395E) : const Color(0xFF0060C0);
  Color get error => dark ? const Color(0xFFF48771) : const Color(0xFFC72E2E);
  Color get success => dark ? const Color(0xFF73C991) : const Color(0xFF2E8B57);
  Color get code => dark ? const Color(0xFF2D2D2D) : const Color(0xFFEFEFEF);
}

extension AgentProviderTab on AgentProvider {
  /// Nome da aba, como na barra do VS Code.
  String get tabLabel => switch (this) {
    AgentProvider.claude => 'Claude Code',
    AgentProvider.chatgpt => 'Codex',
    AgentProvider.gemini => 'Gemini',
    AgentProvider.copilot => 'Copilot',
  };

  /// Cor do botão de enviar.
  Color get sendColor => switch (this) {
    AgentProvider.claude => const Color(0xFFAE3A22),
    AgentProvider.chatgpt => const Color(0xFF202123),
    AgentProvider.gemini => const Color(0xFF3B78E7),
    AgentProvider.copilot => const Color(0xFF8250DF),
  };
}

extension AgentAccessIcon on AgentAccess {
  IconData get icon => switch (this) {
    AgentAccess.manual => Icons.pan_tool_outlined,
    AgentAccess.acceptEdits => Icons.code_rounded,
    AgentAccess.plan => Icons.receipt_long_outlined,
    AgentAccess.auto => Icons.bolt_outlined,
    AgentAccess.bypass => Icons.alt_route_rounded,
    AgentAccess.gestor => Icons.storage_rounded,
  };
}

// ------------------------------------------------------------ menu de ações

/// Item do menu de ações (o "/" da extensão do VS Code).
class PaletteItem {
  PaletteItem({
    required this.section,
    required this.label,
    this.subtitle,
    this.trailing,
    this.icon,
    this.checked = false,
    this.onSelect,
    this.builder,
  });

  final String section;
  final String label;
  final String? subtitle;
  final String? trailing;
  final IconData? icon;
  final bool checked;
  final VoidCallback? onSelect;

  /// Conteúdo próprio (ex.: o controle de esforço); não fecha o menu.
  final Widget Function(BuildContext context, VoidCallback refresh)? builder;
}

/// Mostra o menu de ações acima da caixa de mensagem.
Future<void> showPalette(
  BuildContext context, {
  required List<PaletteItem> Function() items,
  required double bottom,
  bool filter = true,
  String? title,
  String? hint,
  double width = 560,
}) => showDialog<void>(
  context: context,
  barrierColor: Colors.transparent,
  builder: (_) => _Palette(
    items: items,
    bottom: bottom,
    filter: filter,
    title: title,
    hint: hint,
    width: width,
  ),
);

class _Palette extends StatefulWidget {
  const _Palette({
    required this.items,
    required this.bottom,
    required this.filter,
    required this.width,
    this.title,
    this.hint,
  });

  final List<PaletteItem> Function() items;
  final double bottom;
  final bool filter;
  final double width;
  final String? title;
  final String? hint;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  int _index = 0;

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<PaletteItem> get _visible {
    final query = _query.text.trim().toLowerCase();
    return [
      for (final item in widget.items())
        if (query.isEmpty ||
            item.label.toLowerCase().contains(query) ||
            (item.subtitle ?? '').toLowerCase().contains(query) ||
            item.section.toLowerCase().contains(query))
          item,
    ];
  }

  void _select(PaletteItem item) {
    if (item.builder != null || item.onSelect == null) return;
    Navigator.of(context).pop();
    item.onSelect!();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final selectable = _visible.where((i) => i.builder == null).toList();
    if (selectable.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _index = (_index + 1) % selectable.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _index = (_index - 1 + selectable.length) % selectable.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _select(selectable[_index.clamp(0, selectable.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final visible = _visible;
    final selectable = visible.where((i) => i.builder == null).toList();
    final highlighted = selectable.isEmpty
        ? null
        : selectable[_index.clamp(0, selectable.length - 1)];
    final children = <Widget>[];
    String? section;
    for (final item in visible) {
      if (item.section != section) {
        if (section != null) {
          children.add(Divider(height: 9, color: vs.border));
        }
        section = item.section;
        if (section.isNotEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: Text(
                section,
                style: TextStyle(fontSize: 12, color: vs.muted),
              ),
            ),
          );
        }
      }
      children.add(
        item.builder != null
            ? item.builder!(context, () => setState(() {}))
            : _PaletteRow(
                item: item,
                highlighted: identical(item, highlighted),
                onTap: () => _select(item),
                onHover: () =>
                    setState(() => _index = selectable.indexOf(item)),
              ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 60, 12, widget.bottom),
        child: Focus(
          onKeyEvent: _onKey,
          autofocus: !widget.filter,
          child: Material(
            color: vs.card,
            elevation: 8,
            shadowColor: Colors.black38,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: vs.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.width,
                maxHeight: 420,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(
                        children: [
                          Text(
                            widget.title!,
                            style: TextStyle(fontSize: 12, color: vs.muted),
                          ),
                          const Spacer(),
                          if (widget.hint != null)
                            Text(
                              widget.hint!,
                              style: TextStyle(fontSize: 11, color: vs.muted),
                            ),
                        ],
                      ),
                    ),
                  if (widget.filter)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
                      child: TextField(
                        controller: _query,
                        focusNode: _focus,
                        autofocus: true,
                        style: TextStyle(fontSize: 13, color: vs.text),
                        decoration: InputDecoration(
                          hintText: 'Filtrar ações…',
                          hintStyle: TextStyle(color: vs.muted),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.fromLTRB(
                            10,
                            10,
                            10,
                            8,
                          ),
                        ),
                        onChanged: (_) => setState(() => _index = 0),
                        onSubmitted: (_) {
                          if (highlighted != null) _select(highlighted);
                        },
                      ),
                    ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 6),
                      children: children.isEmpty
                          ? [
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  'Nenhuma ação encontrada.',
                                  style: TextStyle(color: vs.muted),
                                ),
                              ),
                            ]
                          : children,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.item,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  final PaletteItem item;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final fg = highlighted ? Colors.white : vs.text;
    final sub = highlighted ? Colors.white70 : vs.muted;
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: highlighted ? vs.selection : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 18, color: fg),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label, style: TextStyle(fontSize: 13, color: fg)),
                    if (item.subtitle != null)
                      Text(
                        item.subtitle!,
                        style: TextStyle(fontSize: 11.5, color: sub),
                      ),
                  ],
                ),
              ),
              if (item.trailing != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    item.trailing!,
                    style: TextStyle(fontSize: 12, color: sub),
                  ),
                ),
              if (item.checked)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Icon(Icons.check_rounded, size: 18, color: fg),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Controle de esforço (os pontinhos do VS Code).
class EffortRow extends StatelessWidget {
  const EffortRow({
    required this.value,
    required this.onChanged,
    this.icon = false,
    super.key,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool icon;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    const levels = AgentSettings.efforts;
    final selected = levels.indexOf(value);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (icon) ...[
            Icon(Icons.tune_rounded, size: 18, color: vs.text),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              'Esforço (${AgentSettings.effortLabel(value)})',
              style: TextStyle(fontSize: 13, color: vs.text),
            ),
          ),
          Tooltip(
            message:
                'Clique num ponto para mudar; clique de novo para voltar '
                'ao padrão do modelo.',
            child: Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: vs.chip,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < levels.length; i++)
                    GestureDetector(
                      onTap: () => onChanged(i == selected ? '' : levels[i]),
                      child: Tooltip(
                        message: AgentSettings.effortLabel(levels[i]),
                        child: Container(
                          width: 16,
                          height: 20,
                          alignment: Alignment.center,
                          child: Container(
                            width: i == selected ? 14 : 5,
                            height: i == selected ? 14 : 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == selected
                                  ? vs.accent
                                  : i < selected
                                  ? vs.accent.withValues(alpha: 0.6)
                                  : vs.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ itens do chat

String agentToolLabel(String name) {
  final short = name
      .replaceFirst('mcp__gestor_ufu__', '')
      .replaceFirst(RegExp(r'^mcp__'), '');
  return switch (short) {
    'get_app_context' => 'Contexto do Gestor',
    'list_modules' => 'Listar módulos',
    'get_skill' => 'Ler skill',
    'list_keys' => 'Listar chaves',
    'term_storage_key' => 'Chave do período',
    'read_key' => 'Ler dados',
    'patch_json' => 'Alterar dados',
    'write_key' => 'Gravar dados',
    'delete_key' => 'Apagar dados',
    'WebSearch' || 'google_web_search' => 'Pesquisa na web',
    'WebFetch' || 'web_fetch' => 'Abrir página',
    'Read' || 'read_file' => 'Ler arquivo',
    'Write' || 'write_file' => 'Criar arquivo',
    'Edit' || 'MultiEdit' || 'replace' => 'Editar arquivo',
    'Bash' || 'PowerShell' || 'run_shell_command' => 'Comando',
    'Glob' || 'glob' => 'Buscar arquivos',
    'Grep' || 'search_file_content' => 'Buscar texto',
    'TodoWrite' => 'Lista de tarefas',
    'Task' || 'Agent' => 'Subagente',
    'ExitPlanMode' => 'Plano pronto',
    'read_spreadsheet' => 'Ler planilha',
    'read_document' => 'Ler documento',
    'computer_screenshot' => 'Ver a tela',
    'computer_windows' => 'Listar janelas',
    'computer_cursor' => 'Posição do mouse',
    'computer_focus_window' => 'Trocar de janela',
    'computer_click' => 'Clicar',
    'computer_move' => 'Mover o mouse',
    'computer_drag' => 'Arrastar',
    'computer_scroll' => 'Rolar',
    'computer_type' => 'Digitar',
    'computer_key' => 'Teclas',
    _ => short,
  };
}

String agentToolSummary(Map<String, dynamic>? input) {
  if (input == null) return '';
  for (final key in const [
    'key',
    'module',
    'prefix',
    'query',
    'url',
    'file_path',
    'path',
    'command',
    'pattern',
    'description',
    'arquivos',
    'text',
    'keys',
    'title',
  ]) {
    final value = input[key];
    if (value == null || '$value'.trim().isEmpty) continue;
    final text = value is List ? value.join(', ') : '$value';
    final ops = input['operations'] is List
        ? ' · ${(input['operations'] as List).length} operação(ões)'
        : '';
    final line = text.replaceAll(RegExp(r'\s+'), ' ');
    return '${line.length > 90 ? '${line.substring(0, 90)}…' : line}$ops';
  }
  // Ações no computador: ponto da captura de tela.
  if (input['x'] is num && input['y'] is num) {
    final to = input['to_x'] is num
        ? ' → (${input['to_x']}, ${input['to_y']})'
        : '';
    return '(${input['x']}, ${input['y']})$to';
  }
  return '';
}

/// Mensagem do usuário: caixa com borda e horário, como na extensão.
class UserBubble extends StatelessWidget {
  const UserBubble(this.entry, {super.key});

  final AgentEntry entry;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final time = TimeOfDay.fromDateTime(entry.time).format(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Text(time, style: TextStyle(fontSize: 11, color: vs.muted)),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: vs.card,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: vs.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final label in entry.attachments)
                          AttachmentPill.label(label),
                      ],
                    ),
                  ),
                SelectableText(
                  entry.text,
                  style: TextStyle(fontSize: 13, color: vs.text, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AttachmentPill extends StatelessWidget {
  const AttachmentPill({
    required this.name,
    this.detail,
    this.onRemove,
    super.key,
  });

  /// Aceita "nome detalhe" (formato guardado no histórico).
  factory AttachmentPill.label(String label) {
    final parts = label.split(' ');
    return AttachmentPill(
      name: parts.first,
      detail: parts.length > 1 ? parts[1] : null,
    );
  }

  final String name;
  final String? detail;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final lower = name.toLowerCase();
    final icon =
        lower.endsWith('.png') ||
            lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.gif') ||
            lower.endsWith('.webp')
        ? Icons.image_outlined
        : lower.endsWith('.pdf')
        ? Icons.picture_as_pdf_outlined
        : Icons.insert_drive_file_outlined;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
      decoration: BoxDecoration(
        color: vs.chip,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: vs.muted),
          const SizedBox(width: 4),
          Text(
            name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: vs.text,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 5),
            Text(detail!, style: TextStyle(fontSize: 12, color: vs.muted)),
          ],
          if (onRemove != null)
            InkWell(
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 14, color: vs.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Item da linha do tempo da resposta: marcador à esquerda ligado aos
/// vizinhos por uma linha vertical, como na extensão do VS Code.
class TimelineItem extends StatelessWidget {
  const TimelineItem({
    required this.child,
    required this.dot,
    this.lineAbove = true,
    this.lineBelow = true,
    this.dotTop = 7,
    super.key,
  });

  final Widget child;
  final Widget dot;
  final bool lineAbove;
  final bool lineBelow;
  final double dotTop;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final line = vs.border;
    return Stack(
      children: [
        if (lineAbove)
          Positioned(
            left: 3,
            top: 0,
            height: dotTop + 3,
            child: Container(width: 1, color: line),
          ),
        if (lineBelow)
          Positioned(
            left: 3,
            top: dotTop + 3,
            bottom: 0,
            child: Container(width: 1, color: line),
          ),
        Positioned(left: 0, top: dotTop, child: dot),
        Padding(
          padding: const EdgeInsets.only(left: 22, top: 4, bottom: 8),
          child: child,
        ),
      ],
    );
  }
}

/// Marcador redondo da linha do tempo.
class TimelineDot extends StatelessWidget {
  const TimelineDot(this.color, {super.key});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Marcador pulsando (ferramenta em execução / agente trabalhando).
class PulsingDot extends StatefulWidget {
  const PulsingDot({required this.color, super.key});

  final Color color;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.25, end: 1.0).animate(_controller),
    child: TimelineDot(widget.color),
  );
}

MarkdownStyleSheet agentMarkdownStyle(BuildContext context) {
  final vs = VsColors.of(context);
  final base = TextStyle(fontSize: 13, color: vs.text, height: 1.45);
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: base,
    listBullet: base,
    strong: base.copyWith(fontWeight: FontWeight.w700),
    em: base.copyWith(fontStyle: FontStyle.italic),
    h1: base.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
    h2: base.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
    h3: base.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
    a: base.copyWith(color: vs.accent),
    code: base.copyWith(
      fontFamily: 'Consolas',
      fontSize: 12.5,
      backgroundColor: vs.code,
      color: vs.dark ? const Color(0xFFF07178) : const Color(0xFFB4262B),
    ),
    codeblockDecoration: BoxDecoration(
      color: vs.code,
      borderRadius: BorderRadius.circular(4),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    tableHead: base.copyWith(fontWeight: FontWeight.w700),
    tableBody: base,
    tableBorder: TableBorder.all(color: vs.border),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: vs.border, width: 3)),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: vs.border)),
    ),
  );
}

/// Texto da resposta do agente (markdown).
class AgentMessage extends StatelessWidget {
  const AgentMessage(this.entry, {super.key});

  final AgentEntry entry;

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: entry.text,
    onTapLink: (text, href, title) {
      if (href != null && href.startsWith('http')) {
        Process.start('rundll32', ['url.dll,FileProtocolHandler', href]);
      }
    },
    styleSheet: agentMarkdownStyle(context),
  );
}

/// Ferramentas cuja entrada é mostrada no cartão IN/OUT (comandos, edições).
bool _cardTool(AgentEntry entry) {
  final input = entry.toolInput ?? const {};
  final name = (entry.toolName ?? '').replaceFirst('mcp__gestor_ufu__', '');
  return input.containsKey('command') ||
      const {
        'patch_json',
        'write_key',
        'Edit',
        'MultiEdit',
        'Write',
        'write_file',
        'replace',
      }.contains(name);
}

String _toolInText(AgentEntry entry) {
  final input = entry.toolInput ?? const {};
  if (input['command'] != null) return '${input['command']}';
  return const JsonEncoder.withIndent('  ').convert(input);
}

/// Chamada de ferramenta no estilo da extensão: nome em negrito e, para
/// comandos/edições, um cartão com IN e OUT; para as demais, resumo na
/// mesma linha e "N linhas de saída". Clique para expandir.
class ToolRow extends StatefulWidget {
  const ToolRow(this.entry, {super.key});

  final AgentEntry entry;

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final entry = widget.entry;
    final card = _cardTool(entry) || _open;
    final summary = agentToolSummary(entry.toolInput);
    final result = entry.toolResult;
    final lines = result == null || result.trim().isEmpty
        ? 0
        : '\n'.allMatches(result.trimRight()).length + 1;
    final mono = TextStyle(
      fontFamily: 'Consolas',
      fontSize: 12.5,
      color: vs.text,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                agentToolLabel(entry.toolName ?? ''),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: vs.text,
                ),
              ),
              if (!card && summary.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    summary,
                    overflow: TextOverflow.ellipsis,
                    style: mono.copyWith(color: vs.text.withValues(alpha: 0.8)),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (!card)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              entry.running
                  ? 'executando…'
                  : entry.toolError
                  ? 'erro · clique para ver'
                  : lines == 0
                  ? 'sem saída'
                  : '$lines ${lines == 1 ? 'linha' : 'linhas'} de saída',
              style: TextStyle(
                fontSize: 12,
                color: entry.toolError ? vs.error : vs.muted,
              ),
            ),
          )
        else
          Container(
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: vs.card,
              border: Border.all(color: vs.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _IoRow(
                  label: 'IN',
                  text: _toolInText(entry),
                  style: mono,
                  expanded: _open,
                  onTap: () => setState(() => _open = !_open),
                ),
                if (result != null || entry.running) ...[
                  Divider(height: 1, color: vs.border),
                  _IoRow(
                    label: entry.toolError ? 'ERRO' : 'OUT',
                    text: entry.running
                        ? 'executando…'
                        : (result!.trim().isEmpty ? '(sem saída)' : result),
                    style: mono.copyWith(
                      color: entry.toolError ? vs.error : vs.text,
                    ),
                    shaded: true,
                    expanded: _open,
                    onTap: () => setState(() => _open = !_open),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _IoRow extends StatelessWidget {
  const _IoRow({
    required this.label,
    required this.text,
    required this.style,
    required this.expanded,
    required this.onTap,
    this.shaded = false,
  });

  final String label;
  final String text;
  final TextStyle style;
  final bool expanded;
  final bool shaded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final shown = text.length > 6000 ? '${text.substring(0, 6000)}\n…' : text;
    final body = expanded
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: SelectableText(shown, style: style),
            ),
          )
        : ShaderMask(
            // Prévia de 3 linhas que esmaece, como na extensão.
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black, Colors.black, Colors.transparent],
              stops: [0, 0.6, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: Text(
              shown,
              maxLines: 3,
              overflow: TextOverflow.clip,
              style: style,
            ),
          );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 38,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: vs.muted,
                  fontFamily: 'Consolas',
                ),
              ),
            ),
            Expanded(
              child: Container(
                color: shaded ? vs.code.withValues(alpha: 0.6) : null,
                padding: shaded ? const EdgeInsets.all(4) : EdgeInsets.zero,
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Palavra animada no fim da resposta enquanto o agente trabalha
/// ("Simmering…" da extensão).
class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({required this.label, super.key});

  final String label;

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    // Brilho que percorre o texto.
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return ShaderMask(
          shaderCallback: (rect) => LinearGradient(
            colors: [vs.muted, vs.text, vs.muted],
            stops: [(t - 0.25).clamp(0.0, 1.0), t, (t + 0.25).clamp(0.0, 1.0)],
          ).createShader(rect),
          child: Text(
            widget.label,
            style: const TextStyle(fontSize: 13, color: Colors.white),
          ),
        );
      },
    );
  }
}

/// Pedido de aprovação de uma ferramenta (modo Manual / Planejar…).
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    required this.tool,
    required this.input,
    required this.onAnswer,
    super.key,
  });

  final String tool;
  final Map<String, dynamic> input;

  /// true = permitir; null = permitir sempre nesta conversa.
  final void Function(bool? allow) onAnswer;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final isPlan = tool == 'ExitPlanMode';
    final detail = isPlan
        ? '${input['plan'] ?? ''}'
        : const JsonEncoder.withIndent('  ').convert(input);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: vs.card,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: vs.accent.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isPlan
                ? 'O agente terminou o plano. Pode começar a executar?'
                : 'Permitir que o agente use "${agentToolLabel(tool)}"?',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: vs.text,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: isPlan
                  ? MarkdownBody(
                      data: detail,
                      styleSheet: agentMarkdownStyle(context),
                    )
                  : SelectableText(
                      detail,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        color: vs.text,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: vs.accent,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => onAnswer(true),
                child: Text(isPlan ? 'Sim, executar' : 'Permitir'),
              ),
              if (!isPlan)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => onAnswer(null),
                  child: const Text('Permitir sempre nesta conversa'),
                ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => onAnswer(false),
                child: Text(isPlan ? 'Não, continuar planejando' : 'Negar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tempo relativo curto ("agora", "5 min", "9 h", "3 d", "2 mês").
String relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'agora';
  if (diff.inHours < 1) return '${diff.inMinutes} min';
  if (diff.inDays < 1) return '${diff.inHours} h';
  if (diff.inDays < 7) return '${diff.inDays} d';
  if (diff.inDays < 30) return '${diff.inDays ~/ 7} sem';
  if (diff.inDays < 365) return '${diff.inDays ~/ 30} mês';
  return '${diff.inDays ~/ 365} a';
}

/// Linha da lista "Chats".
class ConversationTile extends StatefulWidget {
  const ConversationTile({
    required this.conversation,
    required this.onOpen,
    required this.onDelete,
    this.active = false,
    super.key,
  });

  final AgentConversation conversation;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final bool active;

  @override
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final c = widget.conversation;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _hover || widget.active ? vs.hover : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  c.title.isEmpty ? 'Conversa sem título' : c.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: vs.text),
                ),
              ),
              const SizedBox(width: 12),
              if (_hover)
                InkWell(
                  onTap: widget.onDelete,
                  child: Tooltip(
                    message: 'Excluir conversa',
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 16,
                      color: vs.muted,
                    ),
                  ),
                )
              else
                Text(
                  relativeTime(c.updatedAt),
                  style: TextStyle(fontSize: 12, color: vs.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão de ícone pequeno da barra (estilo VS Code).
class VsIconButton extends StatelessWidget {
  const VsIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 18,
    this.color,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: size,
            color: onPressed == null
                ? vs.muted.withValues(alpha: 0.5)
                : color ?? vs.text.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}

/// Chip da barra inferior da caixa de mensagem (modelo, modo…).
class ComposerChip extends StatelessWidget {
  const ComposerChip({
    required this.label,
    required this.onTap,
    this.icon,
    this.filled = false,
    this.tooltip,
    this.iconColor,
    super.key,
  });

  final Color? iconColor;

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final vs = VsColors.of(context);
    final child = InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: filled ? vs.chip : null,
          borderRadius: BorderRadius.circular(filled ? 10 : 5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: iconColor ?? vs.muted),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(fontSize: 12, color: vs.text),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}
