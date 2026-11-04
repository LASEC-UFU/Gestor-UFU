import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';

/// Widget que exibe um texto com ícone de lápis para edição inline.
/// Ao clicar no lápis, o texto vira um TextField editável.
/// Confirma com Enter ou clicando fora, cancela com Escape.
class InlineEditText extends StatefulWidget {
  final String text;

  /// Texto exibido no campo ao entrar em modo edição (ex: com macros).
  /// Se nulo, usa [text].
  final String? editText;
  final TextStyle? style;
  final ValueChanged<String> onChanged;
  final int? maxLines;
  final double iconSize;

  const InlineEditText({
    super.key,
    required this.text,
    this.editText,
    this.style,
    required this.onChanged,
    this.maxLines = 1,
    this.iconSize = 16,
  });

  @override
  State<InlineEditText> createState() => _InlineEditTextState();
}

class _InlineEditTextState extends State<InlineEditText> {
  bool _editing = false;
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(InlineEditText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.text != widget.text) {
      _controller.text = widget.text;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _editing) {
      _confirm();
    }
  }

  void _startEditing() {
    setState(() {
      _editing = true;
      _controller.text = widget.editText ?? widget.text;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _confirm() {
    final newText = _controller.text.trim();
    setState(() => _editing = false);
    if (newText.isNotEmpty && newText != widget.text) {
      widget.onChanged(newText);
    }
  }

  void _cancel() {
    setState(() {
      _editing = false;
      _controller.text = widget.text;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _cancel();
          }
        },
        child: SizedBox(
          height: 32,
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            maxLines: widget.maxLines,
            style:
                widget.style?.copyWith(fontSize: 13) ??
                TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: AppTheme.accent),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: AppTheme.accent, width: 2),
              ),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: _confirm,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.check,
                        size: 16,
                        color: AppTheme.accentGreen,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: _cancel,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: AppTheme.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            onSubmitted: (_) => _confirm(),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            widget.text,
            style: widget.style,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        InkWell(
          onTap: _startEditing,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.all(2),
            child: Icon(
              Icons.edit,
              size: widget.iconSize,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
