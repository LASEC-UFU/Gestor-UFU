import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:config_moodle/core/theme/app_theme.dart';

/// Item para o picker inline de vínculos.
class LinkOption {
  final int? id;
  final String label;
  final String? subtitle;

  const LinkOption({this.id, required this.label, this.subtitle});
}

/// Widget que exibe o vínculo atual e, ao clicar, mostra um combobox inline
/// com filtro para selecionar dentre as opções disponíveis.
class InlineLinkPicker extends StatefulWidget {
  final int? currentId;
  final String? currentLabel;
  final bool isLinked;
  final List<LinkOption> options;
  final ValueChanged<int?> onChanged;
  final Color linkedColor;
  final Color unlinkedColor;

  const InlineLinkPicker({
    super.key,
    this.currentId,
    this.currentLabel,
    required this.isLinked,
    required this.options,
    required this.onChanged,
    this.linkedColor = AppTheme.accentGreen,
    this.unlinkedColor = const Color(0x64B0B0B0),
  });

  @override
  State<InlineLinkPicker> createState() => _InlineLinkPickerState();
}

class _InlineLinkPickerState extends State<InlineLinkPicker> {
  bool _editing = false;
  String _filter = '';
  late FocusNode _focusNode;
  late TextEditingController _filterCtrl;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _filterCtrl = TextEditingController();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _removeOverlay();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant InlineLinkPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If link changed externally while editing, close editing mode
    if (widget.currentId != oldWidget.currentId && _editing) {
      _removeOverlay();
      _editing = false;
    }
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _editing) {
      // Delay close so overlay InkWell.onTap fires before the overlay is removed
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && _editing) {
          _close();
        }
      });
    }
  }

  void _open() {
    setState(() {
      _editing = true;
      _filter = '';
      _filterCtrl.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _showOverlay();
    });
  }

  void _close() {
    _removeOverlay();
    setState(() => _editing = false);
  }

  void _select(int? id) {
    _removeOverlay();
    setState(() => _editing = false);
    widget.onChanged(id);
  }

  void _showOverlay() {
    _removeOverlay();
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(builder: (_) => _buildOverlay());
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _updateOverlay() {
    _overlayEntry?.markNeedsBuild();
  }

  Widget _buildOverlay() {
    final lf = _filter.toLowerCase();
    final filtered = widget.options
        .where(
          (o) =>
              lf.isEmpty ||
              o.label.toLowerCase().contains(lf) ||
              (o.subtitle?.toLowerCase().contains(lf) ?? false),
        )
        .toList();

    return Positioned(
      width: 380,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: Offset(0, 32),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          color: AppTheme.bgSurface,
          child: Container(
            constraints: BoxConstraints(maxHeight: 250),
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.divider),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // "Sem vínculo" option
                InkWell(
                  onTap: () => _select(null),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: widget.currentId == null
                          ? AppTheme.accent.withAlpha(20)
                          : null,
                      border: Border(
                        bottom: BorderSide(color: AppTheme.divider),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.link_off,
                          size: 14,
                          color: AppTheme.textSecondary,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Sem vínculo',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Filtered list
                Flexible(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final opt = filtered[i];
                      final isSelected = opt.id == widget.currentId;
                      return InkWell(
                        onTap: () => _select(opt.id),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          color: isSelected
                              ? AppTheme.accent.withAlpha(20)
                              : null,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                opt.label,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isSelected
                                      ? AppTheme.accent
                                      : AppTheme.textPrimary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (opt.subtitle != null)
                                Text(
                                  opt.subtitle!,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return CompositedTransformTarget(
        link: _layerLink,
        child: KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              _close();
            }
          },
          child: SizedBox(
            height: 30,
            child: TextField(
              controller: _filterCtrl,
              focusNode: _focusNode,
              style: TextStyle(fontSize: 12, color: AppTheme.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                hintText: 'Buscar módulo...',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary.withAlpha(150),
                ),
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(left: 6, right: 4),
                  child: Icon(Icons.search, size: 14),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 24,
                  minHeight: 24,
                ),
                suffixIcon: InkWell(
                  onTap: _close,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 22,
                  minHeight: 22,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppTheme.accent),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(
                    color: AppTheme.accent,
                    width: 2,
                  ),
                ),
              ),
              onChanged: (v) {
                setState(() => _filter = v);
                _updateOverlay();
              },
            ),
          ),
        ),
      );
    }

    // Display mode
    return InkWell(
      onTap: _open,
      borderRadius: BorderRadius.circular(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.link,
            size: 13,
            color: widget.isLinked ? widget.linkedColor : widget.unlinkedColor,
          ),
          SizedBox(width: 4),
          Flexible(
            child: Text(
              widget.isLinked
                  ? (widget.currentLabel ?? 'ID: ${widget.currentId}')
                  : 'Sem vínculo',
              style: TextStyle(
                fontSize: 11,
                color: widget.isLinked
                    ? AppTheme.textSecondary
                    : widget.unlinkedColor,
                fontStyle: widget.isLinked
                    ? FontStyle.normal
                    : FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.isLinked)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: InkWell(
                onTap: () => widget.onChanged(null),
                child: const Icon(
                  Icons.close,
                  size: 12,
                  color: AppTheme.danger,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
