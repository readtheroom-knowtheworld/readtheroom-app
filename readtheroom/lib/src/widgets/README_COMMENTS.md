# Comments System Integration Guide

This guide explains how to integrate the uniform comment system into all question results screens.

## Components Overview

### 1. `CommentWidget` - Individual Comment Display
- Displays a single comment with upvote lizard 🦎 button
- Handles expand/collapse for long comments
- Shows randomized username and timestamp
- Provides menu for reply/report actions

### 2. `CommentsSection` - Complete Comments List
- Manages loading and display of all comments for a question
- Handles pagination (loads 20 comments at a time)
- Shows preview (top 3 comments) by default
- Includes "Add Comment" button
- Empty state when no comments exist

### 3. `AddCommentDialog` - Comment Creation
- Modal dialog for adding new comments
- Supports @question_id linking
- Profanity filtering
- NSFW marking option
- Real-time character count

### 4. `CommentService` - Backend Operations
- Handles all API calls to Supabase
- Manages upvote lizard reactions
- Randomized username generation
- Comment CRUD operations
- Reporting functionality

## Integration Steps

### Step 1: Add Imports
```dart
import '../widgets/comments_section.dart';
import '../widgets/add_comment_dialog.dart';
```

### Step 2: Add Comments Section to Results Screen
Add to the main Column children, typically after the results display and action buttons:

```dart
// In your results screen's Column children:
children: [
  // ... existing content (results, charts, actions)
  
  // Comments Section
  SizedBox(height: 24),
  CommentsSection(
    questionId: widget.question['id']?.toString() ?? '',
    onAddCommentTap: () => _handleAddComment(),
  ),
],
```

### Step 3: Add Comment Handler Method
Add this method to your results screen class:

```dart
void _handleAddComment() async {
  final questionTitle = widget.question['prompt'] ?? widget.question['title'] ?? 'Question';
  final questionId = widget.question['id']?.toString() ?? '';

  if (questionId.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Unable to add comment: Question ID not found'),
        backgroundColor: Colors.red,
      ),
    );
    return;
  }

  await AddCommentDialog.show(
    context: context,
    questionId: questionId,
    questionTitle: questionTitle,
    onCommentAdded: (newComment) {
      // The CommentsSection widget will automatically refresh
      print('New comment added: ${newComment['id']}');
    },
  );
}
```

## Files to Update

To complete the comments integration across all question types:

1. **approval_results_screen.dart** ✅ (Already updated)
2. **multiple_choice_results_screen.dart** 
3. **text_results_screen.dart**

## Features Included

### ✅ Core Features (Implemented)
- Uniform comment widget across all screens
- Two-line preview with expand on tap
- 🦎 upvote lizard reactions with optimistic updates
- Randomized usernames per question
- Profanity filtering
- NSFW content marking
- Comment reporting
- @question_id linking support
- Pagination (20 comments per page)
- Empty states and loading indicators

### 🚧 Future Features (To Be Added)
- Comment threading (Phase 2)
- Question reactions (❤️ 🤔 😡 😂 🤯)
- Push notifications for comments
- Comment search
- Advanced moderation tools

## Database Requirements

Ensure these tables exist (as per comments.md):
- `comments`
- `comment_upvote_lizard_reactions`
- `comment_reports`
- `question_comment_usernames`

## Authentication Notes

- Authenticated users can add comments and react
- Anonymous users can view comments but cannot interact
- Comment authorship is anonymous via randomized usernames
- User's own reactions are highlighted but attribution is anonymous

## Styling

The comment components use:
- `ThemeUtils.getDropdownBackgroundColor()` for consistent backgrounds
- Theme-aware colors for light/dark mode support
- Consistent spacing and typography
- Smooth animations for expand/collapse

## Error Handling

All components include:
- Network error handling with user-friendly messages
- Optimistic updates that revert on failure
- Input validation and profanity filtering
- Loading states and proper disabled states

## Performance Considerations

- Comments load in batches of 20 for pagination
- Optimistic updates for instant feedback
- Minimal re-renders through proper state management
- Cached randomized usernames per question

## Testing the UI

### Test Screen Available
A complete test screen is available at `lib/src/widgets/comments_test_screen.dart` that demonstrates:
- All comment widget variations (short, long, with reactions)
- Question reactions widget
- Full comments section with dummy data
- Different interaction states and features

### Dummy Data for Development
To use dummy data instead of real backend calls, set `useDummyData: true` on:
- `CommentsSection` widget
- `QuestionReactionsWidget` widget

### Bug Fixes Applied
- Fixed Supabase `in_()` method error → changed to `inFilter()`
- Added proper null handling for all data fields
- Added optimistic updates with error recovery

## Testing Checklist

When integrating into a new screen:

- [ ] Comments load properly for existing questions
- [ ] Add comment dialog opens and submits
- [ ] Upvote lizard reactions work (toggle on/off)
- [ ] Long comments expand/collapse correctly
- [ ] Empty state shows when no comments
- [ ] Loading states display during API calls
- [ ] Error handling works for network issues
- [ ] Responsive design on different screen sizes
- [ ] Light/dark theme support
- [ ] Authentication states handled properly
- [ ] Dummy data displays correctly for UI testing