// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// lib/src/screens/home_screen.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/time_utils.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<dynamic> _questions = [];
  bool _isLoading = false;

  // Dummy questions for now.
  final List<Map<String, dynamic>> dummyQuestions = [
    {
      'id': 1,
      'title': 'Do you approve of the new policy?',
      'votes': 10,
      'answered': false,
      'type': 'approval',
      'timestamp': DateTime.now().subtract(Duration(minutes: 10)).toIso8601String(),
    },
    {
      'id': 2,
      'title': 'What is your favorite color?',
      'votes': 5,
      'answered': true,
      'type': 'multipleChoice',
      'timestamp': DateTime.now().subtract(Duration(hours: 1)).toIso8601String(),
    },
    {
      'id': 3,
      'title': 'Describe your ideal vacation.',
      'votes': 8,
      'answered': false,
      'type': 'text',
      'timestamp': DateTime.now().subtract(Duration(days: 2)).toIso8601String(),
    },
  ];

  @override
  void initState() {
    super.initState();
    _questions = dummyQuestions;
    // Later replace dummyQuestions with real API data via fetchQuestions().
  }

  Future<void> fetchQuestions() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final response = await http.get(Uri.parse('https://readtheroom.site/api/questions'));
      if (response.statusCode == 200) {
        setState(() {
          _questions = json.decode(response.body);
        });
      } else {
        print('Error fetching questions: ${response.statusCode}');
      }
    } catch (error) {
      print('Error: $error');
    }
    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: fetchQuestions,
            child: ListView.builder(
              padding: EdgeInsets.only(top: 16),
              itemCount: _questions.length + 1, // +1 for the logo header.
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    children: [
                      Center(
                        child: Image.asset(
                          'assets/images/RTR-logo_Aug2025.png',
                          height: 80,
                        ),
                      ),
                      SizedBox(height: 16),
                    ],
                  );
                }
                var question = _questions[index - 1];
                return ListTile(
                  title: Text(question['title'] ?? 'No Title'),
                  subtitle: Text('Votes: ${question['votes'] ?? 0} • ${getTimeAgo(question['timestamp'])}'),
                  trailing: question['answered'] == true
                      ? Icon(Icons.check, color: Colors.green)
                      : Icon(Icons.help_outline),
                  onTap: () {
                    // Navigate to detailed view or voting screen based on question type.
                    switch (question['type']) {
                      case 'approval':
                        Navigator.pushNamed(context, '/voteApproval');
                        break;
                      case 'text':
                        Navigator.pushNamed(context, '/voteText');
                        break;
                      case 'multipleChoice':
                        Navigator.pushNamed(context, '/voteMultipleChoice');
                        break;
                      default:
                        break;
                    }
                  },
                );
              },
            ),
          );
  }
}
