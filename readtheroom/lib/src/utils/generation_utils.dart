// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Generation options for demographic filtering on responses.
class GenerationOption {
  final String id;
  final String label;
  final String? years;

  const GenerationOption({
    required this.id,
    required this.label,
    this.years,
  });
}

const List<GenerationOption> generations = [
  GenerationOption(id: 'gen_z', label: 'Gen Z', years: 'b. 1997–2012'),
  GenerationOption(id: 'millennial', label: 'Millennial', years: 'b. 1981–1996'),
  GenerationOption(id: 'gen_x', label: 'Gen X', years: 'b. 1965–1980'),
  GenerationOption(id: 'boomer', label: 'Boomer', years: 'b. 1946–1964'),
  GenerationOption(id: 'silent_plus', label: 'Silent+', years: 'b. before 1946'),
  GenerationOption(id: 'opt_out', label: 'Opt out'),
];

/// Returns the display label for a generation ID, or the ID itself if not found.
String getGenerationLabel(String id) {
  for (final gen in generations) {
    if (gen.id == id) return gen.label;
  }
  return id;
}

/// Returns the generation option for a given ID, or null if not found.
GenerationOption? getGenerationOption(String id) {
  for (final gen in generations) {
    if (gen.id == id) return gen;
  }
  return null;
}

/// Selectable generations (excludes opt_out) for display in filter dialogs.
List<GenerationOption> get selectableGenerations =>
    generations.where((g) => g.id != 'opt_out').toList();
