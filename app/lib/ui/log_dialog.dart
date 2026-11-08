import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/controller.dart';

Future<void> showLogDialog(BuildContext context, Controller c) {
  return showDialog(context: context, builder: (_) => _LogDialog(c: c));
}

class _LogDialog extends StatefulWidget {
  const _LogDialog({required this.c});

  final Controller c;

  @override
  State<_LogDialog> createState() => _LogDialogState();
}

class _LogDialogState extends State<_LogDialog> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.c.log.addListener(_follow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
  }

  @override
  void dispose() {
    widget.c.log.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToEnd() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _follow() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent - pos.pixels < 40) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Журнал', style: text.titleLarge)),
                  IconButton(
                    tooltip: 'Копировать',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () => Clipboard.setData(ClipboardData(text: widget.c.log.value)),
                  ),
                  IconButton(
                    tooltip: 'Очистить',
                    icon: const Icon(Icons.delete_sweep_rounded),
                    onPressed: widget.c.clearLog,
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: ValueListenableBuilder(
                        valueListenable: widget.c.log,
                        builder: (_, log, _) => SelectableText(
                          log.isEmpty ? 'Журнал пуст.' : log,
                          style: TextStyle(
                            fontFamily: 'Cascadia Mono',
                            fontFamilyFallback: const ['Consolas', 'monospace'],
                            fontSize: 12.5,
                            height: 1.55,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
