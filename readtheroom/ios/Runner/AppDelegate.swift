import Flutter
import UIKit
import BackgroundTasks
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {

    // Supabase configuration — set via Xcode build settings or xcconfig
    // SUPABASE_URL and SUPABASE_ANON_KEY must be defined in your project's .xcconfig or environment
    private let supabaseUrl = Bundle.main.infoDictionary?["SUPABASE_URL"] as? String ?? ""
    private let supabaseAnonKey = Bundle.main.infoDictionary?["SUPABASE_ANON_KEY"] as? String ?? ""
    private let appGroupId = "group.com.readtheroom.app"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Register background task for QOTD refresh
        registerBackgroundTasks()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func applicationDidEnterBackground(_ application: UIApplication) {
        // Schedule background refresh when app enters background
        scheduleQOTDRefresh()
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.readtheroom.qotdRefresh",
            using: nil
        ) { task in
            self.handleQOTDRefresh(task: task as! BGAppRefreshTask)
        }
        print("QOTD background task registered")
    }

    private func handleQOTDRefresh(task: BGAppRefreshTask) {
        print("QOTD background refresh started")

        // Schedule next refresh first
        scheduleQOTDRefresh()

        // Create a task to fetch QOTD
        let fetchTask = Task {
            await fetchAndUpdateQOTD()
        }

        // Handle expiration
        task.expirationHandler = {
            fetchTask.cancel()
            print("QOTD background task expired")
        }

        // Execute the fetch
        Task {
            await fetchTask.value
            task.setTaskCompleted(success: true)
            print("QOTD background refresh completed")
        }
    }

    private func scheduleQOTDRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.readtheroom.qotdRefresh")
        // Schedule for 1 hour from now (iOS may delay based on system conditions)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("QOTD background refresh scheduled for ~1 hour from now")
        } catch {
            print("Failed to schedule QOTD background refresh: \(error)")
        }
    }

    // MARK: - QOTD Fetching

    private func fetchAndUpdateQOTD() async {
        do {
            // Get today's date in YYYY-MM-DD format
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateKey = formatter.string(from: Date())

            // Build the Supabase REST API URL
            let endpoint = "\(supabaseUrl)/rest/v1/question_of_the_day_history"
            let query = "select=question_id,questions!inner(id,prompt,votes,comment_count,is_hidden)&date=eq.\(dateKey)"

            guard let url = URL(string: "\(endpoint)?\(query)") else {
                print("QOTD: Invalid URL")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("QOTD: HTTP error")
                return
            }

            // Parse response
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let question = json["questions"] as? [String: Any],
                  let isHidden = question["is_hidden"] as? Bool,
                  !isHidden else {
                print("QOTD: No valid question found or question is hidden")
                return
            }

            let questionText = question["prompt"] as? String ?? ""
            let voteCount = question["votes"] as? Int ?? 0
            let commentCount = question["comment_count"] as? Int ?? 0
            let questionId = question["id"] as? String ?? ""

            // Save to App Groups UserDefaults for widget to read
            guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
                print("QOTD: Failed to access App Groups UserDefaults")
                return
            }

            userDefaults.set(questionText, forKey: "qotd_question_text")
            userDefaults.set(voteCount, forKey: "qotd_vote_count")
            userDefaults.set(commentCount, forKey: "qotd_comment_count")
            userDefaults.set(questionId, forKey: "qotd_question_id")
            userDefaults.set(ISO8601DateFormatter().string(from: Date()), forKey: "qotd_last_updated")
            // Note: hasAnswered requires user context, leave existing value

            print("QOTD: Saved to UserDefaults - votes: \(voteCount), comments: \(commentCount)")

            // Reload widget timelines
            WidgetCenter.shared.reloadAllTimelines()
            print("QOTD: Widget timelines reloaded")

        } catch {
            print("QOTD fetch error: \(error)")
        }
    }
}
