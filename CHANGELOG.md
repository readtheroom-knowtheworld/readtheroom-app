## [1.1.4] - 2026-02-07
Added: 
- Security reviews and open source readiness checks
- Sub-national map toggle

Changed: 
- Light mode theme
- Search screen browsing UI
- Rainbow border on streak card in homescreen only for top 5 ranked users
- Deeplink changes
- Removed Syncfusion dependency to be able to open source the project
- Text colour in light mode for achievement badges in the Me screen

## [1.1.3] - 2026-02-02
Added:
- Homescreen widgets for question of the day
- Haptic feedback: on answer and question submission

Changed: 
- Question of the Day now selected server-side
- Swipe navigation improved: left edge swipe goes home. 

## [1.1.2] - 2026-02-02
Added:
- Homescreen widgets for iOS and Android!
- Lockscreen widgets for iOS
- What's New? Dialogue for app updates. 

Fixed: 
- Removed debug buttons in settings page

Changed: 
- How sentence capitalization works across the app
- NSFW auto-toggle in comments

## [1.1.1] - 2026-01-13
Added:
- Streak widget rainbow if in top 10
- Streak widget medal badges for top 3 ranked users
- Android: Chameleon sillouette to notifications instead of grey dot

Fixed: 
- Fix local notifications
- Passkey recovery flow / app uninstall <-> reinstall and login attempt. 
- Optional streak reminders now use local timezone

## [1.1.0] - 2025-12-20

Added: 
- Question of the day vote and comment counts
- Search page now show top all time (non-NSFW) questions by default 
- Lightmode maps now have borders
- Clicking on a country on a map filters the data on the response distributions
- Added answer streak to right of logo on main feed
- On "Top Question" card, dialogue should list in order of votes the users top 10 questions
- QOTD badge opens dialogue showing all QOTDs similar to Top Question dialogue with the Top 10 questions
- New badges 
- Top emoji reacts show on main feed. 
- Country flags in main feed if question is targetted
- Streak animation
- Submit answer animation
- Toggle-able answer streak reminders 
- New question topics
- New Curio 
 
Changed: 
- Always on global model
- On empty state in homescreen, refresh enabled all topics if user accidentally disabled them all. 
- Toggle of private question on/off should be defaulted back to global if when untoggled, not left on city.
- +5 word count on questions title allowed
- Number of categories displayed on new question page. 
- Moved reactions up on results pages, below the top choice/average response section
- Responses (Global) should be grey not white text, and the question should be in larger text and in white above the distribution plots showing the breakdowns of votes
- Moved share/report down (below comments section)
- Below the comment section, instead of "Last updated ... " should be "Swipe to next..." with the swipe symbol used in the on boarding tutorial "Swipe to next"
- Moved My Questions and My Rooms dropdown menues to bottom of Me page, badge ordering 
- Permission dialogue opens after and not before answering QOTD. 
- Reduced onboarding slides

Fixed: 
- Some badges 
- Onboarding tutorial repeats
- Accessibility: clicking a question using a question with a screen reader triggers dialogue of world vs city explanation... Fixed. 
- Filter by network error snackbar no longer hidden behind dialogue on results pages



## [1.0.5] - 2025-09-13
Added: 
- Congratulations screen for major acheievements

## [1.0.4] - 2025-09-09
Fixed: 
- Ranked (all-time) shown on camo counter card to avoid confusion
- MC Top Choice answer centering

## [1.0.3] - 2025-09-03

Changed:
- Camo Counter rank is based on questions posted in last 30 days only

Fixed: 
- Onboarding guide infinite loop!
- Successfully joining a room should now be reflected immediately in My Rooms section

## [1.0.2] - 2025-09-01

Added: 
- Onboarding tutorial updates
- App version number in bottom of settings

Changed:
- No more room feeds

Fixed: 
- Guide section updated to include room explainers
- Room member counts fixed
- Answered questions list fixed

## [1.0.1] - 2025-08-22

Added: 
- Rooms can be created feeds
- Country/room comparisons
- Room quality scores (Average Camo Quality of chameleons in room)
- Onboarding tutorial

Changed:
- Activity feed now accessible from bottom nav bar. 
- Location setting is now in Settings screen.
- Main feeds now only show questions <30 days old

Fixed: 
- Guide section updated including room information
- Searching NSFW questions  
- Map colouring on load
- Navigation to results/answer screen from a link in a comment 

## [0.9.1] - 2025-08-11
Changed:
- App logo

Added: 
- PostHog dependancy 
- Activity dropdown in Me page for recent notifications

Fixed: 
- Search filters and sorting speeds
- Country-targeted questions now auto-filter for only that country's responses in the results pages
- Comment counts now display in Me page

## [0.9.0] - 2025-08-05
Changed:
- Me page now contains more information packaged under "My Stuff"
- Updated guide section 
- Antarctica removed from maps

Added: 
- Private questions now available (only people with link can view/vote)
- New platform Stats page
- news & Notes section on sidebar
- Viewed-toggle on main feed
- Suggestions on feedback pages now supports comments

Fixed: 
- Feed sorting now works without pulldown refresh


## [0.8.9] - 2025-07-28
Changed:
- Updated FCM topic subscriptions
- Real time notifications for new comments on subscribed questions
- Added fallback site page for deeplink fails
- New users can browse 3 results pages before being prompted to authenticate
- Nav bars disappear when scrolling down on main feed
- Faster loading of main feed
- Sorting of suggestions page
- Deeplink fixes

## [0.8.8] - 2025-07-15
Changed:
- Global mode now includes questions targeted to user's current city (if set) in addition to global and country questions
- Performance improvement: Location boost calculations only run in city mode, not in global or country modes
- Q-activity notifications now only trigger for significant vote increases (comments handled separately)
- QOTD notification title standardized to "🦎 Question of the Day" with question text in body
- All question-related notifications now use consistent payload format for proper navigation
- System notifications can now optionally link to specific questions

Fixed:
- Notification system improvements to prevent duplicate notifications
- QOTD notifications now display actual question text instead of generic message
- Fixed notification navigation to properly route to question results screens
- Eliminated duplicate comment notifications from q-activity system
- Long answer text submissions now submittable. 

## [0.8.7] - 2025-07-11
Added:
- Camo Quality Index in "Me" screen
- Swipe to mark-as-read in Subscribed questions list on "Me" screen

Fixed: 
- Linked Questions display in all response pages now


Changed:
- Feed types and organization
  - Location boosting is off except in the city feed, but there is a specific country feed and global feed now.
- QOTD updated to highest votes in past 24 hours (not past calendar day)
- Local boost now handled automatically based off feed type (Global/Country/City)
- Notifications on question activity now only come for >30% change since last view

## [0.8.6] - 2025-07-09
Added:
- Tick marks in approval answer screen 

Fixed: 
- Notification fix, always notify when a comment appears on a subscribed question
- Subscribed list doesn't wipe randomly if data corrupted
- Submitting a text response vote causes a +2 in the number of votes for text questions, but this is resolved when revisiting the question later. 
- Lizzies now persist on comments and number of lizzies on a comment is displayed
- First letter capitalized by default for text responses and for comments 
- Linked questions link to answer pages instead of results pages if user hadn't answered before


Changed:
- Comment box widened to match other boxes on the results pages
- "Show all X comments" -> "Show more" to avoid dumping many comments at once
- "Change location" buttons on home page location click is now centred in the dialogue
- Notifications only when number of votes on subscribed to question increases by +30% from the last time user viewed it


## [0.8.5] - 2025-06-30

Added:
- Comments on results pages
- Reactions to results pages
- Comments and reacts display on home feed 
- Comments on a subscribed question notify subscribers
- Borders to separate questions on main feed 
- States included in city names when searching if available
- Guide section

Fixed: 
- Overly excessive background updates to vote counts
- Faster results page loads by pre-fetching data
- After a manual refresh updates vote, comment counts on feed
- Temporary double-count of a newly submitted text vote in UI

Changed: 
- Answered questions now fully greyed out on main feed, including vote count
- Slightly more spacing between list items in the home_screen
- Arranged the tags in the category section of home and new question in order of popularity. 



## [0.8.4] - 2025-06-29

Added:
- Sharing QR code to sidebar
- Gold, silver and bronze medals for top ranked posters
- More passkey updates for new android users
- Can subscribe to questions
- Can filter categories on main feed

Fixed: 
- Notifications on subscribed-to questions
- Subscriptions shown in "Me" page
- Cities in same county see each others questions on city-level addressing.
- White on white text in new questions page

Changed: 




## [0.8.3] - 2025-06-27

### Added
- Sharing capabilities for questions
- Display a preview page before new question is submitted
- Onboarding flow with unified authentication dialog
- Multiple choice options can be rearranged in the new question screen. 
- Debug info in settings screen
- Real time updates to results screens
- Users can subscribe to notifications from individual questions
- Real time updates on homescreen vote counts
- Platform stats moved to app drawer. About page links to website. 
- App can follow system theme (automatic dark vs light mode)
- Invite Links in app now
- Loading screens added
- Show devID even when logged out.
- Edge functions and CDN enhancement for faster feed loads
- Camo Counters added
- Can now dismiss questions from feed
- Swipe navigation added to the next unanswered question
- Swipe navigation added to all question answer/results pages


### Fixed
- Overflow on question input
- Fixed vote counting on refresh
- Vote count mismatch between home screen and results screens for multiple choice questions
- Vote count display on multiple choice results screen now shows accurate count instead of country count
- Multiple choice results screen now loads individual responses instead of country-summarized data for accurate vote distribution display
- Feedback screen now scrolls as single element
- Vote counting on Feedback screen
- Deep links now go to answer/results screen depending on if user voted on the question before. 
- User can delete their own questions, even if they get to their question from the "Me" page
- Clear country button added to "Me" page including new explainer dialogue boxes
- Pagination working on home feeds
- Autocapitalization in new question form
- Deleted questions showing up in "Posted" list on "Me" page
- Update to question polling for vote counts on homescreen -> immediate on answer submission
- Can now edit answer options when creating a multiple choice question
- Camo Counter lag fixed

### Changed
- Descriptions/names of question types on new question page
- QOTD fallback
- On suggestions Vote -> Like/Unlike
- Passkey login updates for android. 
- Updates to text results screen for popular responses and no word cloud for short answer questions.
- Approval questions now have auto-description and reworded results page. 
- Thumb ordering in approval results pages
- NSFW questions can't make it to QotD
- Re-arranged new question page



## [0.8.2] - 2025-06-16

### Added
- Push notification capability added via FCM

### Fixed
- Word cloud vote counting bug.
- Vote counter issues on text results and multiple choice results screens.
- Bug where multiple choice options failed to load for the Question of the Day (QOTD).
- QOTD now properly fails to load when a question has been reported.
- Feed refresh on pulldown

### Changed
- Word cloud now displays “Not enough data” when filtering by country with fewer than 5 responses; globally, it shows raw responses even if a word cloud can’t be generated.
- Response map only appears if responses come from more than 2 countries.
- Improved global/country/city explainer text on the New Question page.
- About page number formatting improved for Question Tally and Response Tally to better handle large values.

## [0.8.1] - 2025-06-13

### Fixed
- Fixed issue with response maps showing dummy data
- Fixed issue with post-auth navigation on first sign in


