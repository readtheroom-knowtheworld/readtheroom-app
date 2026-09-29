// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared threshold that switches results visualizations between per-response
/// dot charts (below the threshold) and aggregate bars/histograms (at or above).
///
/// Applied to the number of *filtered* responses (after country/generation
/// filters) so the mode can flip as filters change — this is intended and is
/// tracked via the `results_viz_mode` analytics event.
const int kDotPlotThreshold = 30;
