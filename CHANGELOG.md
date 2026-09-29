## [1.3.0] - Unreleased
Added:
- The home screen is now the Question of the Day: answer it right there, watch the world's answer unfold on the existing results pages
- The Archive: every past question in one library behind the archive button — unanswered questions first (most-answered at the top), your own answers collected below, every entry answerable with full results
- Asker's pick: after posting a question, choose your favourite from upcoming Question of the Day candidates (one pick, can't pick your own, server-enforced)
- Answered questions on home show results right in the card — distribution, your own answer highlighted, the response map, no tap needed
- The answered card's button is comment-aware: "Comment" when the conversation hasn't started, "View comments (N)" once it has
- Archive has an Answered / Unanswered toggle, both sorted by response count
- Home header: logo on the left, "> read(the_room) / know the world" tagline on the right (matching the app drawer)
- The answered card's average marker animates in: sweeps from far disapprove to far approve, bounces onto the true average, and the "average" label fades in (skipped when reduce-motion is on)
- The response map on the answered card runs full-width with no inner card chrome, and shows the question's description above the results divider

Removed:
- "Top Choice" and average-answer summary sections on results pages (reactions moved up, above the map)
- Sort / Location / Reviews filter chips above the Archive search bar
- "Where people stand" subtitle on results-page maps
- The ring legend (You / Close friend / Friend / Friend of friend) under the Community demo network graph — tap tooltips carry that context
- The "Before enough friends answer" gated-state demo (and its chameleon deep-thoughts question) on the Community tab

Changed:
- The streak moved into the top bar as a compact badge, replacing the Camo Counter badge (question engagement stats still live on the Me tab); same colours, medal ranks and tap-for-details
- Answered card: "Done for today" became "Thanks for contributing today ♥", the "You answered today ✓" header is gone, and the question stays full-size instead of greying out
- Streaks now mean showing up: answering the daily question — or asking one — keeps your streak; other answers no longer count. Existing streaks carry over untouched.
- The feed is retired (trending/new/popular, pagination, vote polling all removed)
- Topic and review chips on questions now open the Archive filtered to that topic
- The QOTD cold-start overlay is retired — home is the QOTD now
- QOTD deep links land on the home question directly
- Maps restyled for both themes following basemap best practices: light mode gets Positron-style near-white land on muted blue ocean, dark mode gets Dark Matter-style near-black ocean with low-contrast land — response dots are the only saturated colour
- Thumbs beside the answered card's dot plot use the strong approve/disapprove colours; the "0" axis label and the fullscreen map's "long-press a country" hint are gone
- "Filter to here" on a map dot now filters results to that city (country filtering lives in the results filter button); filter affordances only appear when the map is opened from a results page, not from the home card
- Community demo: regular friends show as "@friend" — usernames are a close-friends privilege
- The new-question button fades in only when you reach the bottom of the home screen, so it no longer covers the answer card's buttons
- New question form: topics moved into Advanced options (most questions skip them)
- New question form: the NSFW (18+) toggle also moved into Advanced options, and the "Use @ to tag countries" hint under the description is gone (the @ feature still works; its helper only appears while tagging)
- On days the Question of the Day is 18+, users with 18+ content off now get the top question they haven't answered yet (was: top trending question, answered or not), pinned for the day
- Community tab: the sneak-peek demo now leads; "Bring your people to the room" moved below it
- The notify-me switch became an email signup ("Stay up to date and support Read the Room") — addresses land in a write-only `email_signups` table via a new `subscribe_email` RPC (deploy `supabase/migrations/add_email_signups.sql` before release)
- Multiple-choice results are ordered highest votes first, and fill in a top-to-bottom cascade — dot rows and percentage bars alike (bars grow from zero; poll updates glide instead of replaying)
- Guide and welcome tutorial refocused on the daily ritual — one question, everyone, worldwide, every day; audience-targeting copy and the whole "Customized Feeds / Topic Filtering" section are gone, and Basics now covers QOTD / Asking / the Archive
- The notification permission ask now appears right after your first successful answer (it used to interrupt your second answer attempt before submitting)
- Answering the QOTD on home now stays on home — the card flips straight to its in-card results; the results screen only opens from the comments button
- Home multiple-choice results are ranked most-answered first and cascade in top-to-bottom (colors stay tied to each option); the "Top choice by place" map subtitle is gone
- The answered card no longer repeats your answer in a quote pill above the results (the result rows already mark yours)
- The home map only appears from 5 geo-tagged responses — a lone dot on a blank landmass read worse than no map
- Fixed the home map flashing when the new-question button appeared (nav-bar/FAB visibility changes were rebuilding all four tab pages; now only the chrome rebuilds)

Fixed:
- Answers submitted through the QOTD overlay never counted toward streaks (missing timestamp)
- Navigation bar could stay hidden after scrolling in some flows
- Home card response count matched the results page (it was counting one averaged row per country instead of individual answers)
- Light mode: neutral dots no longer look like hollow rings, dot outlines are subtle dark instead of white, and the dot-plot axis line is actually visible

## [1.2.0] - 2026-08-28
Added:
- World map is now a real map: response dots over country landmasses, coloured by answer, clustered by city (nearby cities merge as you zoom out, split apart as you zoom in)
- Full-screen map mode: tap any results map to expand; legend chips highlight where each answer comes from; tap a dot for town/count details; "filter to here" jumps back to filtered results
- Dot charts on small questions (<30 respondents): one dot per person instead of bars — approval shows a beeswarm along a thumbs-down → thumbs-up axis with a marked average, multiple choice shows a dot per vote
- New Community tab with a sneak peek of the upcoming Networks update: demo network graph (you, close friends and friends-of-friends coloured by answer; other friends stay private), circle aggregate card, close-friends answers row, and a notify-me toggle
- Search bar on the home feed (Reddit-style pill that morphs into the search screen)
- Recent searches: last 10 searches shown when opening search, tap to re-run, deletable
- Search results grouped with "Posted by me" first
- Answer-source analytics (QOTD vs feed vs search vs links) plus onboarding funnel, answer/creation abandonment, share and notification-open tracking
- Automated test suite (120 tests)

Changed:
- New question screen simplified: questions default to public World questions — private questions and country/city targeting now live in a collapsed "Advanced options" section (active selections stay visible in the section header)
- Topics are now optional when posting a question
- Removed persistent topic and question-type feed filters (and the "all topics disabled" empty-feed trap) — tapping a topic chip on a question still filters the feed temporarily; the filter button is gone from the feed (18+ toggle lives in Settings)
- Topic chips on the new question form collapse to a line or two with "(show more)"
- Onboarding shortened from 8 slides to 3 — the removed content now lives in the Guide
- Bottom navigation is now Home / Community / Activity / Me (search moved into the home feed)
- Rooms retired — replaced by the upcoming Friends features; old room links show a retirement notice
- Maps appear from 3 responses (was 10–20)
- What's New dialog updated for 1.2.0

Fixed:
- Community tab showed as a Search button on answer/results screens
- White-on-white snackbar text on the Community tab
- Recent searches didn't appear when tapping into search
- Analytics opt-out was bypassed by one startup event

## [1.1.6] - 2026-04-24
Added: 
- Comments overlay
- Ability to tag others in comments 
- Notifications if you get tagged in a comment

Changed: 
- Rounded corners on histogram bars
- Changed colour mapping for responses
- Text response is now discussion-based format

## [1.1.5] - 2026-04-18
Added: 
- QOTD Overlay on app cold start
- Ability to Boost old questions and add them to the candidate pool for QOTD selection by long-pressing a question on the search screen.

Changed: 
- Comments now veiwable again by default. Question rating only required before posting a comment.
- Comment UI overhauled 
- Cleaned up onboarding slides
- QOTD can repeat is boosted by a user, but only once in 3 months. 

## [1.1.4] - 2026-02-07
Added: 
- Security review, open sourcing
- Question ratings and review tags
- Can now filter responses by Gen Z, Millennial...

Changed: 
- Light mode theme
- Search screen browsing UI
- Rainbow border on streak card in homescreen only for top 5 ranked users
- Deeplink changes
- Removed Syncfusion dependency to be able to open source the project
- Text colour in light mode for achievement badges in the Me screen
- Map interactivity changes

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


