package com.readtheroom.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.app.PendingIntent
import android.app.AlarmManager
import android.content.Intent
import android.net.Uri
import android.content.SharedPreferences
import android.graphics.Color
import android.view.View
import android.os.Build
import android.util.TypedValue
import android.content.ComponentName
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/**
 * AppWidgetProvider for the Streak Widget.
 *
 * Displays the Curio mascot and current streak count on the home screen.
 * Background color changes based on time remaining in the day (urgency).
 * Widget self-calculates state based on current time for accurate display.
 * Fire icon and text are always white.
 */
class StreakWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
        // Schedule next update at the next time threshold
        scheduleNextUpdate(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            // Handle our scheduled alarm or boot/package replaced
            ACTION_SCHEDULED_UPDATE,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                val appWidgetManager = AppWidgetManager.getInstance(context)
                val componentName = ComponentName(context, StreakWidgetProvider::class.java)
                val appWidgetIds = appWidgetManager.getAppWidgetIds(componentName)
                if (appWidgetIds.isNotEmpty()) {
                    for (appWidgetId in appWidgetIds) {
                        updateAppWidget(context, appWidgetManager, appWidgetId)
                    }
                    // Schedule next update
                    scheduleNextUpdate(context)
                }
            }
        }
    }

    override fun onEnabled(context: Context) {
        // Called when the first widget is created
        scheduleNextUpdate(context)
    }

    override fun onDisabled(context: Context) {
        // Called when the last widget is removed
        cancelScheduledUpdate(context)
    }

    companion object {
        private const val PREFS_NAME = "HomeWidgetPreferences"
        private const val ACTION_SCHEDULED_UPDATE = "com.readtheroom.app.WIDGET_SCHEDULED_UPDATE"
        private const val REQUEST_CODE_ALARM = 12345

        // Color constants matching Flutter StreakWidgetUtils and home_screen.dart
        private const val COLOR_TEAL = 0xFF00897B.toInt()
        private const val COLOR_ORANGE = 0xFFEA6D32.toInt()  // 3-8 hours remaining
        private const val COLOR_RED = 0xFF951414.toInt()     // <3 hours remaining
        private const val COLOR_GREY = 0xFF9E9E9E.toInt()    // No streak

        // Fire icon sizes in dp for each state
        private const val FIRE_SIZE_HAPPY = 24      // Answered today
        private const val FIRE_SIZE_NEUTRAL = 24   // >8 hours remaining
        private const val FIRE_SIZE_SAD = 20       // 3-8 hours remaining
        private const val FIRE_SIZE_ANGRY = 16     // 1-3 hours remaining
        private const val FIRE_SIZE_CRITICAL = 12  // <1 hour remaining
        private const val FIRE_SIZE_DREAD = 10     // No streak

        // Helper to read Int or Long from SharedPreferences (Flutter may save as either type)
        private fun getIntOrLong(prefs: SharedPreferences, key: String, default: Int): Int {
            return try {
                prefs.getInt(key, default)
            } catch (e: ClassCastException) {
                try {
                    prefs.getLong(key, default.toLong()).toInt()
                } catch (e2: ClassCastException) {
                    default
                }
            }
        }

        // Helper to read Double or Float from SharedPreferences
        private fun getDoubleOrFloat(prefs: SharedPreferences, key: String, default: Double): Double {
            return try {
                prefs.getFloat(key, default.toFloat()).toDouble()
            } catch (e: ClassCastException) {
                try {
                    java.lang.Double.longBitsToDouble(prefs.getLong(key, java.lang.Double.doubleToLongBits(default)))
                } catch (e2: ClassCastException) {
                    default
                }
            }
        }

        // Convert dp to pixels
        private fun dpToPx(context: Context, dp: Int): Int {
            return TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP,
                dp.toFloat(),
                context.resources.displayMetrics
            ).toInt()
        }

        // Calculate hours remaining until end of day (23:59:59)
        private fun getHoursRemainingToday(): Double {
            val now = LocalDateTime.now()
            val endOfDay = LocalDateTime.of(now.toLocalDate(), LocalTime.of(23, 59, 59))
            val minutesRemaining = ChronoUnit.MINUTES.between(now, endOfDay)
            return minutesRemaining / 60.0
        }

        // Check if the last update was from today (user's calendar day)
        private fun wasUpdatedToday(lastUpdatedStr: String?): Boolean {
            if (lastUpdatedStr.isNullOrEmpty()) return false
            return try {
                val lastUpdated = LocalDateTime.parse(lastUpdatedStr, DateTimeFormatter.ISO_DATE_TIME)
                val today = LocalDate.now()
                lastUpdated.toLocalDate() == today
            } catch (e: Exception) {
                false
            }
        }

        // Determine Curio state based on streak and time remaining
        // Matches Flutter StreakWidgetUtils.getCurioState()
        private fun calculateCurioState(
            streakCount: Int,
            hasExtendedToday: Boolean,
            hoursRemaining: Double
        ): String {
            if (streakCount == 0) return "dread"
            if (hasExtendedToday) return "happy"
            if (hoursRemaining < 1) return "critical"
            if (hoursRemaining < 3) return "angry"
            if (hoursRemaining < 8) return "sad"
            return "neutral"
        }

        // Determine background color based on state
        // Matches home_screen.dart _getStreakCardColor()
        private fun calculateBackgroundColor(curioState: String): Int {
            return when (curioState) {
                "happy", "neutral" -> COLOR_TEAL
                "sad" -> COLOR_ORANGE
                "angry", "critical" -> COLOR_RED
                "dread" -> COLOR_GREY
                else -> COLOR_TEAL
            }
        }

        fun updateAppWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val prefs: SharedPreferences = context.getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE
            )

            // Read raw widget data saved by Flutter
            val streakCount = getIntOrLong(prefs, "streak_count", 0)
            val hasExtendedTodayStored = prefs.getBoolean("has_extended_today", false)
            val lastUpdated = prefs.getString("last_updated", null)

            // Calculate current state based on time (widget self-calculates for accuracy)
            val hoursRemaining = getHoursRemainingToday()

            // Check if it's a new day since last Flutter update
            // If last update was from a previous day, treat as not extended today
            val isUpdateFromToday = wasUpdatedToday(lastUpdated)
            val hasExtendedToday = hasExtendedTodayStored && isUpdateFromToday

            // Calculate state and colors based on current time
            val curioState = calculateCurioState(streakCount, hasExtendedToday, hoursRemaining)
            val backgroundColor = calculateBackgroundColor(curioState)

            val views = RemoteViews(context.packageName, R.layout.streak_widget_layout)

            // Fire icon is always white
            val fireDrawable = R.drawable.ic_fire_white

            // Set fire icon size based on urgency (shrinks as day progresses without answering)
            val fireSizeDp = when (curioState) {
                "happy" -> FIRE_SIZE_HAPPY
                "neutral" -> FIRE_SIZE_NEUTRAL
                "sad" -> FIRE_SIZE_SAD
                "angry" -> FIRE_SIZE_ANGRY
                "critical" -> FIRE_SIZE_CRITICAL
                "dread" -> FIRE_SIZE_DREAD
                else -> FIRE_SIZE_NEUTRAL
            }

            // Set fire icon drawable
            views.setImageViewResource(R.id.streak_icon, fireDrawable)

            // Set fire icon size (API 31+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val fireSizePx = dpToPx(context, fireSizeDp)
                views.setViewLayoutWidth(R.id.streak_icon, fireSizePx.toFloat(), TypedValue.COMPLEX_UNIT_PX)
                views.setViewLayoutHeight(R.id.streak_icon, fireSizePx.toFloat(), TypedValue.COMPLEX_UNIT_PX)
            }

            // Hide fire icon if streak >= 100 (to prevent overflow)
            val showFireIcon = streakCount < 100
            views.setViewVisibility(R.id.streak_icon, if (showFireIcon) View.VISIBLE else View.GONE)

            // Streak count text is always white
            views.setTextViewText(R.id.streak_count, streakCount.toString())
            views.setTextColor(R.id.streak_count, Color.WHITE)

            // Set background drawable based on calculated urgency color
            val backgroundDrawable = when (backgroundColor) {
                COLOR_ORANGE -> R.drawable.widget_background_orange
                COLOR_RED -> R.drawable.widget_background_red
                COLOR_GREY -> R.drawable.widget_background_grey
                else -> R.drawable.widget_background_teal
            }
            views.setInt(R.id.widget_container, "setBackgroundResource", backgroundDrawable)

            // Set Curio image based on state
            val curioDrawable = when (curioState) {
                "happy" -> R.drawable.curio_happy
                "neutral" -> R.drawable.curio_neutral
                "sad" -> R.drawable.curio_sad
                "angry" -> R.drawable.curio_angry
                "critical" -> R.drawable.curio_dread
                "dread" -> R.drawable.curio_dread
                else -> R.drawable.curio_neutral
            }
            views.setImageViewResource(R.id.curio_image, curioDrawable)

            // Set click intent to open app via deep link
            val intent = Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("readtheroom://home")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_container, pendingIntent)

            // Update the widget
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        // Calculate the next time threshold for widget update
        // Returns milliseconds until the next threshold (midnight, 6h, 3h, or 1h remaining)
        private fun getNextUpdateTimeMillis(): Long {
            val now = LocalDateTime.now()
            val today = now.toLocalDate()

            // Define thresholds: midnight, and when there are 8h, 3h, 1h remaining
            // 8h remaining = 16:00, 3h remaining = 21:00, 1h remaining = 23:00
            val thresholds = listOf(
                LocalDateTime.of(today, LocalTime.of(0, 0, 1)),     // Just after midnight (next day)
                LocalDateTime.of(today, LocalTime.of(16, 0, 0)),    // 8 hours remaining
                LocalDateTime.of(today, LocalTime.of(21, 0, 0)),    // 3 hours remaining
                LocalDateTime.of(today, LocalTime.of(23, 0, 0))     // 1 hour remaining
            )

            // Find the next threshold after now
            var nextThreshold: LocalDateTime? = null
            for (threshold in thresholds) {
                if (threshold.isAfter(now)) {
                    nextThreshold = threshold
                    break
                }
            }

            // If no threshold found today, schedule for midnight tomorrow
            if (nextThreshold == null) {
                nextThreshold = LocalDateTime.of(today.plusDays(1), LocalTime.of(0, 0, 1))
            }

            // Convert to epoch millis (nextThreshold is guaranteed non-null here)
            return nextThreshold!!.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        }

        // Schedule the next widget update at the next time threshold
        fun scheduleNextUpdate(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, StreakWidgetProvider::class.java).apply {
                action = ACTION_SCHEDULED_UPDATE
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE_ALARM,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val triggerAtMillis = getNextUpdateTimeMillis()

            // Use inexact alarm - does not require SCHEDULE_EXACT_ALARM permission
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            } else {
                alarmManager.set(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            }
        }

        // Cancel any scheduled widget updates
        fun cancelScheduledUpdate(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, StreakWidgetProvider::class.java).apply {
                action = ACTION_SCHEDULED_UPDATE
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE_ALARM,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.cancel(pendingIntent)
        }
    }
}
