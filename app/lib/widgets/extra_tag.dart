import 'package:flutter/material.dart';
import '../theme/category_colors.dart';

/// Small pill-shaped label for secondary/descriptive tags -- a pipeline's
/// organism scope (prokaryote/eukaryote/...) on the Hub, and (reusing the
/// same pipeline-id labels) which pipeline(s) use a given database on the
/// Databases screen. One shared widget so a tag looks and means the same
/// thing everywhere in the app.
class ExtraTag extends StatelessWidget {
  final String tag;
  final bool english;
  const ExtraTag({super.key, required this.tag, required this.english});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final style = tag.extraTagStyle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: style.bg(brightness), borderRadius: BorderRadius.circular(6)),
      child: Text(
        tag.extraTagLabel(english),
        style: TextStyle(color: style.fg(brightness), fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}
