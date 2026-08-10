# Real RDA (redundancy analysis) of Hellinger-transformed abundances against
# numeric metadata, with automatic forward selection -- direct translation
# of microbiome.R's section 11. See plots/manifest.yaml for parameter
# descriptions.
this_script_dir <- function {
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  dirname(normalizePath(sub("^--file=", "", file_arg)))
}
lib_dir <- file.path(this_script_dir, "..", "lib")
source(file.path(lib_dir, "io_helpers.R"))
source(file.path(lib_dir, "plot_theme.R"))
source(file.path(lib_dir, "style_io.R"))

suppressMessages({
  library(phyloseq)
  library(vegan)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(ggrepel)
  library(jsonlite)
})

args <- parse_cli_args(defaults = list(permutations = "999", seed = "123"))

if (is.null(args$group_var) || args$group_var == "") stop("--group_var is required")
group_var <- args$group_var
permutations <- as.integer(args$permutations)
seed <- as.integer(args$seed)
style <- read_style_from_path(args$style_json)
bg <- style$background %||% "gray90"
font_family <- style$font_family %||% "serif"
font_scale <- style$font_scale %||% 1.0
hide_x_axis <- isTRUE(style$hide_x_axis)
hide_y_axis <- isTRUE(style$hide_y_axis)

log_line("[rda_environmental_drivers] reading cached phyloseq object from %s", args$phyloseq_rds)
ps <- readRDS(args$phyloseq_rds)
log_line("[rda_environmental_drivers] phyloseq object: %d taxa x %d samples", ntaxa(ps), nsamples(ps))

if (!(group_var %in% colnames(sample_data(ps)))) {
  stop(sprintf("group_var '%s' is not a column in the metadata table. Available columns: %s",
               group_var, paste(colnames(sample_data(ps)), collapse = ", ")))
}

df_meta <- data.frame(sample_data(ps), check.names = FALSE)
# Comma-decimal locales (common in exported spreadsheets) -> dot-decimal,
# then re-infer real types -- same normalization microbiome.R's own script
# does before treating anything as numeric.
df_meta_clean <- df_meta %>%
  mutate(across(everything, as.character)) %>%
  mutate(across(everything, ~ gsub(",", ".",.))) %>%
  type.convert(as.is = TRUE)
rownames(df_meta_clean) <- rownames(df_meta)

abund_matrix <- t(as(otu_table(ps), "matrix"))
abund_matrix <- abund_matrix[rownames(df_meta_clean),, drop = FALSE]
abund_hellinger <- decostand(abund_matrix, method = "hellinger")

env_vars <- df_meta_clean %>%
  select(where(is.numeric)) %>%
  select(where(~ var(., na.rm = TRUE) > 0))

if (ncol(env_vars) == 0) {
  stop("No numeric metadata columns with variance > 0 -- RDA needs at least one real environmental variable (e.g. pH, temperature).")
}

env_vars_scaled <- as.data.frame(scale(env_vars))
rownames(env_vars_scaled) <- rownames(df_meta_clean)

common_samples <- intersect(rownames(abund_hellinger), rownames(drop_na(env_vars_scaled)))
abund_hellinger <- abund_hellinger[common_samples,, drop = FALSE]
env_vars_scaled <- drop_na(env_vars_scaled)[common_samples,, drop = FALSE]
log_line("[rda_environmental_drivers] %d samples x %d environmental variable(s): %s",
          length(common_samples), ncol(env_vars_scaled), paste(colnames(env_vars_scaled), collapse = ", "))

null_model <- rda(abund_hellinger ~ 1, data = env_vars_scaled)
full_model <- rda(abund_hellinger ~., data = env_vars_scaled)

rda_model <- tryCatch(
  ordistep(null_model, scope = formula(full_model), direction = "forward", permutations = permutations, trace = FALSE),
  error = function(e) full_model
)

if (is.null(rda_model$CCA) || rda_model$CCA$rank == 0) {
  log_line("[rda_environmental_drivers] no variable was individually significant -- showing the full model for visualization")
  rda_model <- full_model
} else {
  log_line("[rda_environmental_drivers] selected variables: %s", paste(rownames(rda_model$CCA$biplot), collapse = ", "))
}

set.seed(seed)
anova_model <- anova.cca(rda_model, permutations = permutations)
p_model <- anova_model$`Pr(>F)`[1]
r2_adj <- RsquareAdj(rda_model)$adj.r.squared
sum_rda <- summary(rda_model)
rda1_var <- if ("RDA1" %in% colnames(sum_rda$cont$importance)) round(sum_rda$cont$importance[2, "RDA1"] * 100, 2) else NA_real_
rda2_var <- if ("RDA2" %in% colnames(sum_rda$cont$importance)) round(sum_rda$cont$importance[2, "RDA2"] * 100, 2) else NA_real_

site_scores <- as.data.frame(scores(rda_model, display = "sites")) %>%
  mutate(SampleID = rownames(.), Group = df_meta_clean[rownames(.), group_var])

# Real, edge case: with only one continuous
# environmental predictor, the CONSTRAINED ordination only has a single
# axis (RDA1) -- there is no RDA2 to plot, and the code below used to
# reference it unconditionally, crashing with "object 'RDA2' not found"
# deep inside ggplot's aesthetic evaluation. Standard ecological practice
# for a single-constraint RDA (see Borcard, Gillet & Legendre, "Numerical
# Ecology with R") is to plot RDA1 against the first axis of the *residual*
# (unconstrained) variation instead, labelled PC1 by vegan -- a real,
# established convention, not an improvised workaround. y_axis_col picks
# whichever is actually available; only errors if truly neither exists
# (a genuinely degenerate ordination).
y_axis_col <- if ("RDA2" %in% colnames(site_scores)) {
  "RDA2"
} else if (any(grepl("^PC", colnames(site_scores)))) {
  grep("^PC", colnames(site_scores), value = TRUE)[1]
} else {
  NA_character_
}
if (is.na(y_axis_col)) {
  stop("This dataset's ordination has no second axis (constrained or residual) to plot against RDA1 -- too little variation to visualize as a 2D biplot.")
}
y_axis_is_residual <- y_axis_col != "RDA2"
log_line("[rda_environmental_drivers] using %s as the y-axis (%s)", y_axis_col,
         if (y_axis_is_residual) "residual/unconstrained -- only 1 constrained axis available" else "constrained")

arrow_scores <- as.data.frame(scores(rda_model, display = "bp")) %>%
  mutate(Variable = rownames(.))
if (all(c("RDA1", "RDA2") %in% colnames(arrow_scores))) {
  arrow_scores <- arrow_scores %>% mutate(RDA1 = RDA1 * 2.5, RDA2 = RDA2 * 2.5)
}

dir.create(args$out_dir, recursive = TRUE, showWarnings = FALSE)

write_json(
  list(
    analysis_id = "rda_environmental_drivers",
    group_var = group_var,
    model_p_value = p_model,
    model_p_text = format_p_value(p_model),
    adjusted_r2 = r2_adj,
    rda1_pct = rda1_var,
    rda2_pct = rda2_var,
    y_axis_col = y_axis_col,
    y_axis_is_residual = y_axis_is_residual,
    sites = lapply(seq_len(nrow(site_scores)), function(i) as.list(site_scores[i, ])),
    arrows = lapply(seq_len(nrow(arrow_scores)), function(i) as.list(arrow_scores[i, ]))
  ),
  file.path(args$out_dir, "data.json"),
  auto_unbox = TRUE, pretty = TRUE, na = "null"
)

# Resolved BEFORE building effective_style, so what gets written matches
# what the plot actually uses (see default_style_for_groups's docstring).
palette <- resolve_palette(site_scores$Group, style)

# Same reasoning as beta_diversity.R: per-sample labels are only useful
# while there are few enough sites for them to stay legible.
show_point_labels <- nrow(site_scores) <= 40

effective_style <- default_style_for_groups(site_scores$Group, legend_position = "right", show_labels = show_point_labels,
                                             background = bg, font_family = font_family, palette = palette)
write_style_json(effective_style, file.path(args$out_dir, "default_style.json"))

saveRDS(list(rda_model = rda_model, anova = anova_model), file.path(args$out_dir, "rda_environmental_drivers.rds"))

p <- ggplot +
  geom_hline(yintercept = 0, linetype = "dashed", color = "gray50", linewidth = 0.5) +
  geom_vline(xintercept = 0, linetype = "dashed", color = "gray50", linewidth = 0.5) +
  { if (nrow(arrow_scores) > 0 && all(c("RDA1", "RDA2") %in% colnames(arrow_scores))) list(
      geom_segment(data = arrow_scores, aes(x = 0, y = 0, xend = RDA1, yend = RDA2),
                   arrow = arrow(length = unit(0.3, "cm")), color = "blue", linewidth = 0.8),
      geom_text_repel(data = arrow_scores, aes(x = RDA1, y = RDA2, label = Variable),
                       color = "blue", fontface = "bold", family = font_family, size = 5)
    ) } +
  geom_point(data = site_scores, aes(x = RDA1, y =.datay_axis_col, fill = Group), size = 6, shape = 21, color = "black", stroke = 0.6) +
  geom_text_repel(data = site_scores, aes(x = RDA1, y =.datay_axis_col, label = SampleID),
                   size = 4.5, family = font_family, fontface = "italic", color = "black",
                   box.padding = 0.7, point.padding = 0.5, max.overlaps = 50) +
  scale_fill_manual(values = palette, name = group_var) +
  labs(
    x = paste0("RDA 1", if (!is.na(rda1_var)) paste0(" (", rda1_var, "%)") else ""),
    y = if (y_axis_is_residual) "PC 1 (residual, unconstrained)"
        else paste0("RDA 2", if (!is.na(rda2_var)) paste0(" (", rda2_var, "%)") else "")
  ) +
  base_theme(bg = bg, font_family = font_family, font_scale = font_scale) +
  theme(
    legend.position = "right",
    panel.border = element_rect(color = "black", fill = NA, linewidth = 1)
  )
p <- apply_axis_visibility(p, hide_x_axis, hide_y_axis)

title <- paste0("Redundancy Analysis (RDA): Key Environmental Drivers\n",
                 "Model ", format_p_value(p_model), " | Adjusted R² = ", round(r2_adj, 3))
final_plot <- with_title_bar(p, title, size = 6, title_height = 0.14, font_family = font_family)
ggsave(file.path(args$out_dir, "preview.png"), plot = final_plot,
       width = 12, height = 10, units = "in", dpi = 150, bg = "white")

log_line("[rda_environmental_drivers] wrote data.json, default_style.json, rda_environmental_drivers.rds, preview.png")
