// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../services/question_reactions_service.dart';
import '../utils/reaction_logic.dart';

/// The free-emoji picker sheet: quick chips over the full emoji keyboard.
///
/// Extracted from `question_reactions_widget.dart` (WP-D) so the chat overlay's
/// reactions use the *same* control, with the same theming, the same height cap
/// and the same single-grapheme validation, rather than a second copy that can
/// drift. The widget that owned it keeps its behaviour exactly: it calls
/// [EmojiPickerSheet.show] and applies whatever comes back.
///
/// Returns the chosen emoji, or null if the sheet was dismissed or the
/// selection failed validation (in which case the caller's [onRejected] has
/// already explained why).
class EmojiPickerSheet {
  const EmojiPickerSheet._();

  /// Shows the picker.
  ///
  /// [highlighted] marks quick chips the user has already used, so the control
  /// shows state rather than pretending every tap is new. [onRejected] reports
  /// a selection that is not a single emoji — the keyboard can yield
  /// multi-glyph sequences, and the column is free text now, so something has
  /// to refuse them.
  static Future<String?> show({
    required BuildContext context,
    String title = 'Add a reaction',
    Set<String> highlighted = const {},
    List<String> quickPicks = QuestionReactionsService.quickReactions,
    void Function(String rejected)? onRejected,
  }) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Quick chips — the familiar five.
                if (quickPicks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: quickPicks.map((reaction) {
                        final isMine = highlighted.contains(reaction);
                        return GestureDetector(
                          onTap: () =>
                              Navigator.of(sheetContext).pop(reaction),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: theme.primaryColor
                                  .withOpacity(isMine ? 0.22 : 0.1),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: theme.primaryColor
                                    .withOpacity(isMine ? 1.0 : 0.3),
                                width: isMine ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              reaction,
                              style: const TextStyle(fontSize: 20),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                const SizedBox(height: 12),
                Divider(height: 1, color: theme.dividerColor),
                // Full keyboard. Height is capped so the sheet never covers the
                // whole screen on a short device.
                SizedBox(
                  height: (MediaQuery.of(sheetContext).size.height * 0.4)
                      .clamp(220.0, 320.0),
                  child: EmojiPicker(
                    onEmojiSelected: (category, emoji) =>
                        Navigator.of(sheetContext).pop(emoji.emoji),
                    config: Config(
                      height: double.infinity,
                      emojiViewConfig: EmojiViewConfig(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        columns: 7,
                        emojiSizeMax: 34,
                      ),
                      categoryViewConfig: CategoryViewConfig(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        indicatorColor: theme.primaryColor,
                        iconColorSelected: theme.primaryColor,
                        dividerColor: theme.dividerColor,
                      ),
                      // Search by name ("fire", "thumbs", "cat"): the bottom
                      // bar is kept only for its search button — no backspace,
                      // since one tap on an emoji closes the sheet anyway.
                      bottomActionBarConfig: BottomActionBarConfig(
                        enabled: true,
                        showBackspaceButton: false,
                        showSearchViewButton: true,
                        backgroundColor: theme.scaffoldBackgroundColor,
                        buttonColor: theme.scaffoldBackgroundColor,
                        buttonIconColor: theme.primaryColor,
                        // The default bar puts search bottom-left; ours sits
                        // bottom-right, where the thumb already is.
                        customBottomActionBar: (config, state, showSearchView) =>
                            Container(
                          color: theme.scaffoldBackgroundColor,
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              IconButton(
                                tooltip: 'Search emoji',
                                onPressed: showSearchView,
                                icon: Icon(Icons.search_rounded,
                                    color: theme.primaryColor, size: 26),
                              ),
                            ],
                          ),
                        ),
                      ),
                      searchViewConfig: SearchViewConfig(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        buttonIconColor: theme.primaryColor,
                        hintText: 'Search emoji',
                        inputTextStyle: theme.textTheme.bodyMedium,
                        hintTextStyle: theme.textTheme.bodyMedium
                            ?.copyWith(color: Colors.grey),
                      ),
                      skinToneConfig: const SkinToneConfig(enabled: true),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (picked == null) return null;
    if (!isSingleEmoji(picked)) {
      onRejected?.call(picked);
      return null;
    }
    return picked;
  }
}
