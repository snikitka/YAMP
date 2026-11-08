import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/controller.dart';
import '../state/search.dart';
import '../theme.dart';
import 'widgets.dart';

class LinkInput extends StatefulWidget {
  const LinkInput({super.key, required this.c});

  final Controller c;

  @override
  State<LinkInput> createState() => _LinkInputState();
}

class _LinkInputState extends State<LinkInput> {
  final _focus = FocusNode();

  Controller get c => widget.c;
  TextEditingController get _input => c.search.input;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _open(String text) {
    _input.clear();
    c.openLinks(text);
  }

  void _find(String text) {
    c.openSearch();
    c.search.run(text);
  }

  void _submit() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    looksLikeLinks(text) ? _open(text) : _find(text);
  }

  void _clear() {
    _input.clear();
    c.search.close();
    _focus.requestFocus();
  }

  void _changed(String text) {
    if (text.trim().isNotEmpty && !looksLikeLinks(text)) c.openSearch();
  }

  Future<void> _pasteInline() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').trim();
    if (text.isEmpty) return;
    if (looksLikeLinks(text) && _input.text.trim().isEmpty) {
      _open(text);
      return;
    }
    final v = _input.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    _input.value = TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    _changed(_input.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = context.status.accent;
    final phone = MediaQuery.sizeOf(context).width < phoneWidth;
    return ListenableBuilder(
      listenable: _input,
      builder: (context, _) {
        final text = _input.text.trim();
        final empty = text.isEmpty;
        final link = looksLikeLinks(text);
        final Widget? action = empty
            ? null
            : Padding(
                padding: const EdgeInsets.only(right: 6),
                child: !link
                    ? IconButton(
                        tooltip: 'Очистить',
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: _clear,
                      )
                    : IconButton.filled(
                        tooltip: 'Открыть',
                        style: IconButton.styleFrom(
                          backgroundColor: scheme.primary,
                          foregroundColor: scheme.onPrimary,
                          shape: const CircleBorder(),
                          fixedSize: const Size(32, 32),
                          minimumSize: const Size(32, 32),
                          padding: EdgeInsets.zero,
                        ),
                        iconSize: 20,
                        icon: const Icon(Icons.arrow_forward_rounded),
                        onPressed: _submit,
                      ),
              );
        final radius = BorderRadius.circular(12);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (!empty) _clear();
            },
          },
          child: Actions(
            actions: {
              PasteTextIntent: CallbackAction<PasteTextIntent>(
                onInvoke: (_) {
                  _pasteInline();
                  return null;
                },
              ),
            },
            child: TextField(
              controller: _input,
              focusNode: _focus,
              autofocus: !phone,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              onChanged: _changed,
              onTap: () {
                if (c.search.open) c.openSearch();
              },
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Трек, альбом, исполнитель или ссылка',
                prefixIcon: Icon(link ? Icons.link_rounded : Icons.search_rounded),
                suffixIcon: action,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                isDense: true,
                fillColor: scheme.surfaceContainer,
                border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
