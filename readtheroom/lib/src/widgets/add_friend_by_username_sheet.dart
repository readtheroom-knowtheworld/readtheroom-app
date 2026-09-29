// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/friend_service.dart';
import '../utils/haptic_utils.dart';
import '../utils/username_logic.dart';
import 'chameleon_avatar.dart';

/// "Add by username" (§5.2 add flow 1): type an **exact** handle, look it up,
/// send the request.
///
/// There is no search-as-you-type and no result list on purpose — the backend
/// only offers exact match, precisely so handles cannot be enumerated (§5.1,
/// privacy P-5). A miss says "No one by that name" and nothing else: the same
/// answer is returned for a handle that does not exist, your own handle, and a
/// user who has blocked you, so the copy cannot be used as an oracle.
class AddFriendByUsernameSheet extends StatefulWidget {
  const AddFriendByUsernameSheet({Key? key}) : super(key: key);

  /// Returns true when a request was sent.
  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddFriendByUsernameSheet(),
    );
  }

  @override
  State<AddFriendByUsernameSheet> createState() =>
      _AddFriendByUsernameSheetState();
}

class _AddFriendByUsernameSheetState extends State<AddFriendByUsernameSheet> {
  final TextEditingController _controller = TextEditingController();

  bool _busy = false;
  String? _error;

  /// The resolved user, held between the lookup and the send so the user can
  /// see who they are about to add.
  FriendLookupResult? _found;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _handle =>
      normalizeUsername(_controller.text.trim().replaceFirst('@', ''));

  Future<void> _lookup() async {
    final handle = _handle;
    final formatError = usernameFormatError(handle);
    if (formatError != null) {
      setState(() {
        _found = null;
        // A handle that cannot be valid never reaches the RPC, so a typo does
        // not burn one of the 20 daily lookups.
        _error = usernameFormatErrorMessage(formatError);
      });
      return;
    }

    AppHaptics.lightImpact();
    setState(() {
      _busy = true;
      _error = null;
      _found = null;
    });

    final friends = context.read<FriendService>();
    final result = await friends.lookupByUsername(handle);
    if (!mounted) return;

    setState(() {
      _busy = false;
      if (!result.success) {
        _error = result.error == FriendError.rateLimited
            ? "You've looked up a lot of names today — try again tomorrow."
            : 'Could not look that up. Please try again.';
        return;
      }
      if (!result.found) {
        // Deliberately uninformative — see the class doc.
        _error = 'No one by that name.';
        return;
      }
      _found = result;
    });
  }

  Future<void> _send() async {
    final found = _found;
    if (found?.userId == null) return;

    AppHaptics.lightImpact();
    setState(() {
      _busy = true;
      _error = null;
    });

    final friends = context.read<FriendService>();
    final result = await friends.sendFriendRequest(
      found!.userId!,
      method: 'username',
      username: found.username,
      avatarId: found.avatarId,
    );
    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _busy = false;
        _error = result.message;
      });
      return;
    }

    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.primaryColor;
    final found = _found;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
              const SizedBox(height: 18),
              Text(
                'Add by username',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Enter their username exactly, as usernames are not searchable',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey, height: 1.35),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _controller,
                enabled: !_busy,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(kUsernameMaxLength + 1),
                ],
                onSubmitted: (_) => _lookup(),
                onChanged: (_) {
                  if (_error != null || _found != null) {
                    setState(() {
                      _error = null;
                      _found = null;
                    });
                  }
                },
                decoration: InputDecoration(
                  prefixText: '@',
                  hintText: 'their_handle',
                  hintStyle: TextStyle(color: Colors.grey[500]),
                  errorText: _error,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (found != null) ...[
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: primary.withOpacity(0.25)),
                  ),
                  child: Row(
                    children: [
                      ChameleonAvatar(avatarId: found.avatarId, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '@${found.username}',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy
                      ? null
                      : (found != null ? _send : _lookup),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Text(found != null ? 'Send request' : 'Look up'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
