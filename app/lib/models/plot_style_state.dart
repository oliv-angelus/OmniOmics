import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

/// A small set of R color names actually used as defaults by the R analysis
/// scripts (plot_theme.R's base_theme/title_bar) -- flutter_colorpicker's
/// own colorFromName doesn't know these (they're R/ggplot2 built-ins, not
/// CSS/Material names), so a swatch would otherwise render as a fallback gray
/// with no visual relationship to the real starting color.
const Map<String, Color> _rColorNames = {
  'gray90': Color(0xFFE5E5E5),
  'gray70': Color(0xFFB3B3B3),
  'gray95': Color(0xFFF2F2F2),
  'white': Colors.white,
  'black': Colors.black,
};

/// Parses either a hex string ("#RRGGBB") or one of the few R color names
/// plot_theme.R actually defaults to -- covers every value a style.json's
/// background/accent_color/palette entries can hold before the user has
/// edited anything (after an edit, everything is hex, from the color
/// picker).
Color parseStyleColor(String value) {
  return _rColorNames[value] ?? colorFromHex(value) ?? Colors.grey.shade300;
}

/// Editable style state for the Plots tab's "Personalizar" panel -- mirrors
/// the R side's style.json shape exactly (see style_io.R/plot_theme.R) so
/// toJson can be written straight to disk and passed to an analysis
/// script via --style_json with no translation layer.
class PlotStyleState {
  String background;
  String fontFamily; // 'serif' | 'sans' | 'mono' -- R's generic font aliases, always available
  /// Group/taxon/phylum name -> color, for analyses with a real named
  /// palette (alpha/beta diversity, DESeq2, RDA, IndVal, Venn, taxonomic
  /// composition, co-occurrence network). Empty for analyses that don't
  /// have one (core_microbiome's continuous heatmap, goods_coverage/
  /// rarefaction_curve's single accent_color instead).
  Map<String, String> palette;
  /// Single-series color, for goods_coverage (bar fill) / rarefaction_curve
  /// (line color) -- null for every other analysis.
  String? accentColor;
  /// Uniform multiplier over base_theme's default axis text/title sizes
  /// (plot_theme.R) -- 1.0 is every analysis's original hardcoded size.
  /// Analyses that don't call base_theme at all (cooccurrence_network's
  /// theme_void network, venn_diagram, upset_plot's ComplexUpset-owned
  /// theme) don't read this -- a real, documented scope cut, not an
  /// oversight (see plot_theme.R's apply_axis_visibility).
  double fontScale;
  /// Blanks the X/Y axis title+text+ticks entirely (base_theme-using
  /// analyses only, same scope cut as fontScale above -- a network/Venn/
  /// UpSet plot has no single cartesian "X axis"/"Y axis" to hide).
  bool hideXAxis;
  bool hideYAxis;

  PlotStyleState({
    required this.background,
    required this.fontFamily,
    required this.palette,
    this.accentColor,
    this.fontScale = 1.0,
    this.hideXAxis = false,
    this.hideYAxis = false,
  });

  factory PlotStyleState.fromJson(Map<String, dynamic> json) {
    final rawPalette = json['palette'];
    final palette = <String, String>{};
    if (rawPalette is Map) {
      rawPalette.forEach((k, v) {
        if (v is String) palette[k.toString] = v;
      });
    }
    return PlotStyleState(
      background: json['background'] as String? ?? 'gray90',
      fontFamily: json['font_family'] as String? ?? 'serif',
      palette: palette,
      accentColor: json['accent_color'] as String?,
      fontScale: (json['font_scale'] as num?)?.toDouble ?? 1.0,
      hideXAxis: json['hide_x_axis'] as bool? ?? false,
      hideYAxis: json['hide_y_axis'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson => {
        'background': background,
        'font_family': fontFamily,
        if (palette.isNotEmpty) 'palette': palette,
        if (accentColor != null) 'accent_color': accentColor,
        'font_scale': fontScale,
        'hide_x_axis': hideXAxis,
        'hide_y_axis': hideYAxis,
        'legend_position': 'right',
        'show_labels': false,
      };
}
