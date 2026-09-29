// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/profile_service.dart';
import '../utils/username_logic.dart';

/// Bottom sheet for choosing / changing the chameleon handle.
///
/// Decision D4: free-form field with generated suggestions as the default, and
/// the suggestions are profanity-checked too (handled inside
/// [ProfileService.suggestUsernames]).
///
/// Used from the Me-tab profile header and the header chip in C1; the
/// onboarding "Pick your chameleon" slide (C3) reuses [UsernameField] directly
/// so the validation copy is identical in both places.
class UsernameEditSheet extends StatelessWidget {
  const UsernameEditSheet({Key? key}) : super(key: key);

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const UsernameEditSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = context.watch<ProfileService>();
    final isChange = (profile.username ?? '').isNotEmpty;
    final cooldownDays = profile.cooldownDaysRemaining();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isChange ? 'Change your name' : 'Name your chameleon',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Only friends see this name. It never appears on your '
                'questions, answers or comments.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey[600]),
              ),
              if (isChange && cooldownDays > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.lock_clock, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'You can change it again in $cooldownDays '
                        '${cooldownDays == 1 ? 'day' : 'days'}.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              UsernameField(
                initialValue: profile.username,
                enabled: !(isChange && cooldownDays > 0),
                onSaved: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reusable handle field: text input with inline validation, a refreshable row
/// of generated suggestions, and a save button wired to [ProfileService].
///
/// Shared by [UsernameEditSheet] and the onboarding profile slide so the rules
/// and the copy live in exactly one place.
class UsernameField extends StatefulWidget {
  const UsernameField({
    Key? key,
    this.initialValue,
    this.enabled = true,
    this.onSaved,
    this.suggestionCount = 3,
    this.saveLabel,
    this.autofocus = false,
  }) : super(key: key);

  final String? initialValue;
  final bool enabled;

  /// Called after a successful save.
  final VoidCallback? onSaved;

  final int suggestionCount;
  final String? saveLabel;
  final bool autofocus;

  @override
  State<UsernameField> createState() => _UsernameFieldState();
}

class _UsernameFieldState extends State<UsernameField> {
  late final TextEditingController _controller;
  List<String> _suggestions = const [];
  String? _errorText;
  bool _saving = false;
  bool _pickedFromSuggestions = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSuggestions());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _refreshSuggestions() {
    if (!mounted) return;
    final profile = Provider.of<ProfileService>(context, listen: false);
    setState(() {
      _suggestions = profile.suggestUsernames(widget.suggestionCount);
    });
  }

  void _onChanged(String value) {
    final error = usernameFormatError(value);
    setState(() {
      _pickedFromSuggestions = _suggestions.contains(normalizeUsername(value));
      _errorText = value.isEmpty || error == null
          ? null
          : usernameFormatErrorMessage(error);
    });
  }

  Future<void> _save() async {
    final profile = Provider.of<ProfileService>(context, listen: false);
    final value = normalizeUsername(_controller.text);
    final error = usernameFormatError(value);
    if (error != null) {
      setState(() => _errorText = usernameFormatErrorMessage(error));
      return;
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });
    final result = await profile.setUsername(
      value,
      wasSuggested: _pickedFromSuggestions,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (result.success) {
      widget.onSaved?.call();
      return;
    }
    setState(() => _errorText = result.message);
    if (result.error == UsernameError.taken) _refreshSuggestions();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          enabled: widget.enabled && !_saving,
          autofocus: widget.autofocus,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: kUsernameMaxLength,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            // Keep the field in the handle alphabet as the user types, so the
            // inline error is about length, not stray characters.
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
          ],
          onChanged: _onChanged,
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            prefixText: '@',
            // Obviously a placeholder, not a name to keep: the real
            // suggestions live in the chips below.
            hintText: 'my_handle',
            hintStyle: TextStyle(color: Colors.grey[500]),
            errorText: _errorText,
            border: const OutlineInputBorder(),
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              'Suggestions',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: Colors.grey[600]),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: widget.enabled && !_saving ? _refreshSuggestions : null,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Shuffle'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final suggestion in _suggestions)
              ActionChip(
                label: Text('@$suggestion'),
                onPressed: widget.enabled && !_saving
                    ? () {
                        _controller.text = suggestion;
                        _onChanged(suggestion);
                        setState(() => _pickedFromSuggestions = true);
                      }
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: widget.enabled && !_saving ? _save : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Text(
                    widget.saveLabel ?? 'Save name',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
