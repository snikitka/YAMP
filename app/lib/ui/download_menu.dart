import 'package:flutter/material.dart';

import '../state/models.dart';
import '../theme.dart';

typedef Download = void Function(String link, Quality quality, String title);

List<Widget> downloadItems(Download download, String link, String title) => [
  for (final (q, label) in const [(Quality.lossless, 'Скачать FLAC'), (Quality.mp3, 'Скачать MP3 320')])
    MenuItemButton(
      leadingIcon: const Icon(Icons.download_rounded),
      onPressed: link.isEmpty ? null : () => download(link, q, title),
      child: Text(label),
    ),
];

class DownloadButton extends StatelessWidget {
  const DownloadButton({
    super.key,
    required this.download,
    required this.link,
    required this.title,
    this.label = 'Скачать',
    this.size = 48,
  });

  final Download download;
  final String link, title, label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accent = context.status.accent;
    return MenuAnchor(
      menuChildren: downloadItems(download, link, title),
      builder: (context, menu, _) => IconButton(
        tooltip: label,
        onPressed: link.isEmpty ? null : () => menu.isOpen ? menu.close() : menu.open(),
        style: IconButton.styleFrom(
          fixedSize: Size.square(size),
          minimumSize: Size.square(size),
          padding: EdgeInsets.zero,
          backgroundColor: accent.withValues(alpha: 0.14),
          foregroundColor: accent,
          shape: CircleBorder(side: BorderSide(color: accent.withValues(alpha: 0.45))),
        ),
        iconSize: size * 0.5,
        icon: const Icon(Icons.download_rounded),
      ),
    );
  }
}
