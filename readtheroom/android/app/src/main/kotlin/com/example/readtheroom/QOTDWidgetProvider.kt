package com.readtheroom.app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.content.SharedPreferences
import android.graphics.Color
import android.view.View

/**
 * AppWidgetProvider for the Question of the Day Widget.
 *
 * Displays the QOTD with Curio mascot, question text, vote count, and comment count.
 * Background is teal (#00897B).
 * Curio is happy when user has answered, questioning when they haven't.
 */
class QOTDWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        private const val PREFS_NAME = "HomeWidgetPreferences"
        private const val COLOR_TEAL = 0xFF00897B.toInt()
        private const val MAX_QUESTION_LENGTH = 120

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

        fun updateAppWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val prefs: SharedPreferences = context.getSharedPreferences(
                PREFS_NAME,
                Context.MODE_PRIVATE
            )

            // Read QOTD data saved by Flutter
            val questionText = prefs.getString("qotd_question_text", "What's on your mind?") ?: "What's on your mind?"
            val voteCount = getIntOrLong(prefs, "qotd_vote_count", 0)
            val commentCount = getIntOrLong(prefs, "qotd_comment_count", 0)
            val hasAnswered = prefs.getBoolean("qotd_has_answered", false)
            val questionId = prefs.getString("qotd_question_id", "") ?: ""

            val views = RemoteViews(context.packageName, R.layout.qotd_widget_layout)

            // Truncate question text if needed
            val displayText = if (questionText.length > MAX_QUESTION_LENGTH) {
                questionText.take(MAX_QUESTION_LENGTH - 3) + "..."
            } else {
                questionText
            }
            views.setTextViewText(R.id.qotd_question_text, displayText)

            // Format stats with proper pluralization
            val voteLabel = if (voteCount == 1) "vote" else "votes"
            val statsText = if (commentCount > 0) {
                val commentLabel = if (commentCount == 1) "comment" else "comments"
                "$voteCount $voteLabel \u2022 $commentCount $commentLabel"
            } else {
                "$voteCount $voteLabel"
            }
            views.setTextViewText(R.id.qotd_stats, statsText)

            // Set Curio image based on whether user has answered
            val curioDrawable = if (hasAnswered) {
                R.drawable.curio_happy
            } else {
                R.drawable.curio_questioning
            }
            views.setImageViewResource(R.id.qotd_curio_image, curioDrawable)

            // Set click intent to open app via deep link to QOTD
            val deepLinkUri = if (questionId.isNotEmpty()) {
                "readtheroom://qotd/$questionId"
            } else {
                "readtheroom://home"
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse(deepLinkUri)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                1, // Different request code from streak widget
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.qotd_widget_container, pendingIntent)

            // Update the widget
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
