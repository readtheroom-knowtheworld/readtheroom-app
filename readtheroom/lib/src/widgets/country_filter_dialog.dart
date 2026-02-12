// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import '../services/room_service.dart';
import '../utils/generation_utils.dart';

class CountryFilterDialog extends StatefulWidget {
  final Map<String, Map<String, dynamic>> countryResponses;
  final String? currentSelectedCountry;
  final Function(String?) onCountrySelected;
  final String questionTitle;
  final String questionId;
  final String questionType; // 'approval', 'multiple_choice', 'text'
  final Map<String, double>? countryAverages; // Only for approval questions
  final List<String>? questionOptions; // Only for multiple choice questions
  final Map<String, String?>? countryMostPopular; // Only for multiple choice questions
  final List<Map<String, dynamic>>? allResponses; // All responses for room counting
  final int? myNetworkResponseCount; // Accurate My Network response count from service
  final Map<String, int>? roomResponseCounts; // Accurate room response counts from service
  final Map<String, String>? roomNames; // Room ID to name mapping
  final Map<String, Map<String, dynamic>>? generationResponses; // Generation response data
  final Map<String, double>? generationAverages; // Only for approval questions
  final Map<String, String?>? generationMostPopular; // Only for multiple choice questions

  const CountryFilterDialog({
    Key? key,
    required this.countryResponses,
    required this.currentSelectedCountry,
    required this.onCountrySelected,
    required this.questionTitle,
    required this.questionId,
    this.questionType = 'text',
    this.countryAverages,
    this.questionOptions,
    this.countryMostPopular,
    this.allResponses,
    this.myNetworkResponseCount,
    this.roomResponseCounts,
    this.roomNames,
    this.generationResponses,
    this.generationAverages,
    this.generationMostPopular,
  }) : super(key: key);

  static Future<String?> show({
    required BuildContext context,
    required Map<String, Map<String, dynamic>> countryResponses,
    required String? currentSelectedCountry,
    required String questionTitle,
    required String questionId,
    String questionType = 'text',
    Map<String, double>? countryAverages,
    List<String>? questionOptions,
    Map<String, String?>? countryMostPopular,
    List<Map<String, dynamic>>? allResponses,
    int? myNetworkResponseCount,
    Map<String, int>? roomResponseCounts,
    Map<String, String>? roomNames,
    Map<String, Map<String, dynamic>>? generationResponses,
    Map<String, double>? generationAverages,
    Map<String, String?>? generationMostPopular,
  }) {
    return showDialog<String?>(
      context: context,
      builder: (context) => CountryFilterDialog(
        countryResponses: countryResponses,
        currentSelectedCountry: currentSelectedCountry,
        questionTitle: questionTitle,
        questionId: questionId,
        questionType: questionType,
        countryAverages: countryAverages,
        questionOptions: questionOptions,
        countryMostPopular: countryMostPopular,
        allResponses: allResponses,
        myNetworkResponseCount: myNetworkResponseCount,
        roomResponseCounts: roomResponseCounts,
        roomNames: roomNames,
        generationResponses: generationResponses,
        generationAverages: generationAverages,
        generationMostPopular: generationMostPopular,
        onCountrySelected: (country) => Navigator.of(context).pop(country),
      ),
    );
  }

  @override
  State<CountryFilterDialog> createState() => _CountryFilterDialogState();
}

class _CountryFilterDialogState extends State<CountryFilterDialog> {
  String _searchQuery = '';
  late List<MapEntry<String, Map<String, dynamic>>> _sortedCountries;
  List<dynamic> _userRooms = [];
  bool _isLoadingRooms = true;
  Map<String, int> _roomResponseCounts = {};
  int _myNetworkResponseCount = 0;

  @override
  void initState() {
    super.initState();
    _sortedCountries = widget.countryResponses.entries.toList()
      ..sort((a, b) {
        final aTotal = a.value['total'] as int? ?? 0;
        final bTotal = b.value['total'] as int? ?? 0;
        return bTotal.compareTo(aTotal); // Sort by response count, descending
      });
    
    // Use the passed My Network count if available, otherwise calculate from allResponses
    if (widget.myNetworkResponseCount != null) {
      _myNetworkResponseCount = widget.myNetworkResponseCount!;
    }
    
    _loadUserRooms();
  }

  Future<void> _loadUserRooms() async {
    try {
      // Use passed data if available for instant display
      if (widget.roomResponseCounts != null && widget.roomNames != null) {
        final roomCounts = widget.roomResponseCounts!;
        final networkTotal = widget.myNetworkResponseCount ?? 0;
        
        // Create room data from passed information
        final roomsData = roomCounts.entries.map((entry) {
          final roomId = entry.key;
          final roomName = widget.roomNames![roomId] ?? 'Room';
          return {
            'id': roomId,
            'name': roomName,
            'member_count': 5, // Assume unlocked since it has responses
            'is_unlocked': true,
            'response_count': entry.value,
          };
        }).toList();
        
        if (mounted) {
          setState(() {
            _userRooms = roomsData;
            _roomResponseCounts = roomCounts;
            _myNetworkResponseCount = networkTotal;
            _isLoadingRooms = false;
          });
        }
      } else {
        // Fallback to fetching rooms if data not provided
        final roomService = RoomService();
        final rooms = await roomService.getUserRooms();
        
        // Use passed room response counts if available, otherwise calculate from allResponses
        final roomCounts = <String, int>{};
        int networkTotal = 0;
        
        if (widget.roomResponseCounts != null) {
          // Use the accurate counts passed from the service
          roomCounts.addAll(widget.roomResponseCounts!);
        } else if (widget.allResponses != null) {
          // Fallback to calculating from allResponses (less accurate)
          for (final response in widget.allResponses!) {
            final roomId = response['room_id'] as String?;
            if (roomId != null) {
              roomCounts[roomId] = (roomCounts[roomId] ?? 0) + 1;
              networkTotal++;
            }
          }
        }
      
      if (mounted) {
        setState(() {
          _userRooms = rooms.map((room) => {
            'id': room.id,
            'name': room.name,
            'member_count': room.memberCount,
            'is_unlocked': room.isUnlocked,
          }).toList();
          _roomResponseCounts = roomCounts;
          // Only update My Network count if it wasn't passed as parameter
          if (widget.myNetworkResponseCount == null) {
            _myNetworkResponseCount = networkTotal;
          }
          _isLoadingRooms = false;
        });
      }
      } // Close the else block
    } catch (e) {
      print('Error loading user rooms: $e');
      if (mounted) {
        setState(() {
          _isLoadingRooms = false;
        });
      }
    }
  }

  bool get _hasActiveUnlockedRoom {
    return _userRooms.any((room) => room['is_unlocked'] == true);
  }

  bool get _hasEnoughNetworkResponses {
    return _myNetworkResponseCount >= 5;
  }

  bool get _shouldShowMyNetwork {
    return _hasActiveUnlockedRoom && _hasEnoughNetworkResponses;
  }

  bool get _shouldShowMyNetworkGreyed {
    return _hasActiveUnlockedRoom && !_hasEnoughNetworkResponses;
  }

  String get _myNetworkSnackbarMessage {
    if (!_hasActiveUnlockedRoom) {
      return 'Create or join a room to build your network!';
    } else if (!_hasEnoughNetworkResponses) {
      return 'Too few responses from your network (need 5+)';
    }
    return '';
  }


  // Color mapping for approval questions (matches approval results screen)
  Color _getColorForValue(double value) {
    // Normalize the value from -1 to 1 range to 0 to 1 range
    final normalizedValue = (value + 1) / 2;
    
    if (normalizedValue < 0.2) {
      return Colors.red;
    } else if (normalizedValue < 0.4) {
      return Colors.red[300]!;
    } else if (normalizedValue < 0.6) {
      return Colors.grey.shade300;
    } else if (normalizedValue < 0.8) {
      return Colors.lightGreen;
    } else {
      return Colors.green;
    }
  }

  // Color mapping for multiple choice questions (matches multiple choice results screen)
  Color getColorForOption(String? option) {
    // Return grey for ties or null values
    if (option == null || option == 'TIE') {
      return Colors.grey[400]!;
    }
    
    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
    ];
    
    // Find the index of this option in the list of options
    if (widget.questionOptions != null) {
      final index = widget.questionOptions!.indexOf(option);
      if (index != -1) {
        return colors[index % colors.length];
      }
    }
    
    // If option not found, use a default color
    return Colors.grey[400]!;
  }

  Color _getCountryColor(String countryName, int responseCount) {
    // Handle World option specially
    if (countryName == 'World') {
      return _getGlobalColor(responseCount);
    }

    // Handle My Network option specially - always use primary color
    if (countryName == 'My Network') {
      return Theme.of(context).primaryColor;
    }

    // Handle Generation filter - match country color behavior
    if (countryName.startsWith('Gen:')) {
      final genId = countryName.substring(4);
      if (widget.questionType == 'approval' && widget.generationAverages != null) {
        final average = widget.generationAverages![genId];
        if (average != null) return _getColorForValue(average);
      }
      if (widget.questionType == 'multiple_choice' && widget.generationMostPopular != null) {
        final mostPopular = widget.generationMostPopular![genId];
        return getColorForOption(mostPopular);
      }
      return Theme.of(context).primaryColor;
    }
    
    // For approval questions, use the average approval rating color
    if (widget.questionType == 'approval' && widget.countryAverages != null) {
      final average = widget.countryAverages![countryName];
      if (average != null) {
        return _getColorForValue(average);
      }
    }
    
    // For multiple choice questions, use the most popular option color
    if (widget.questionType == 'multiple_choice' && widget.countryMostPopular != null) {
      final mostPopular = widget.countryMostPopular![countryName];
      return getColorForOption(mostPopular);
    }
    
    // For text questions or other question types, use response count based color with higher threshold
    final threshold = widget.questionType == 'text' ? 5 : 3;
    return responseCount > threshold 
        ? Theme.of(context).primaryColor
        : Colors.grey[400]!;
  }

  Color _getGlobalColor(int totalResponses) {
    // For approval questions, calculate the global average and use its color
    if (widget.questionType == 'approval' && widget.countryAverages != null) {
      // Calculate weighted global average from country averages
      double totalWeightedValue = 0;
      int totalResponsesFromAverages = 0;
      
      widget.countryAverages!.forEach((country, average) {
        final countryResponseCount = widget.countryResponses[country]?['total'] as int? ?? 0;
        totalWeightedValue += average * countryResponseCount;
        totalResponsesFromAverages += countryResponseCount;
      });
      
      if (totalResponsesFromAverages > 0) {
        final globalAverage = totalWeightedValue / totalResponsesFromAverages;
        return _getColorForValue(globalAverage);
      }
    }
    
    // For multiple choice questions, calculate global most popular option
    if (widget.questionType == 'multiple_choice' && widget.countryMostPopular != null && widget.questionOptions != null) {
      // Count total votes for each option across all countries
      final globalOptionCounts = <String, int>{};
      for (var option in widget.questionOptions!) {
        globalOptionCounts[option] = 0;
      }
      
      widget.countryMostPopular!.forEach((country, mostPopular) {
        if (mostPopular != null && widget.countryResponses[country] != null) {
          final countryResponseCount = widget.countryResponses[country]!['total'] as int? ?? 0;
          globalOptionCounts[mostPopular] = (globalOptionCounts[mostPopular] ?? 0) + countryResponseCount;
        }
      });
      
      if (globalOptionCounts.isNotEmpty) {
        // Find the globally most popular option
        final maxCount = globalOptionCounts.values.reduce((a, b) => a > b ? a : b);
        final mostPopularGlobally = globalOptionCounts.entries
            .where((entry) => entry.value == maxCount)
            .map((entry) => entry.key)
            .first;
            
        return getColorForOption(mostPopularGlobally);
      }
    }
    
    // For text questions or other question types, use response count based color with higher threshold
    final threshold = widget.questionType == 'text' ? 5 : 3;
    return totalResponses > threshold 
        ? Theme.of(context).primaryColor
        : Colors.grey[400]!;
  }

  @override
  Widget build(BuildContext context) {
    final totalResponsesGlobal = _sortedCountries.fold<int>(0, (sum, entry) {
      return sum + (entry.value['total'] as int? ?? 0);
    });

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Filter Results'),
          SizedBox(height: 4),
          Text(
            widget.questionTitle.length > 50 
                ? '${widget.questionTitle.substring(0, 50)}...'
                : widget.questionTitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
      content: Container(
        width: double.maxFinite,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Global option
            _buildCountryOption(
              context: context,
              countryName: 'World',
              subtitle: 'All responses ($totalResponsesGlobal)',
              isSelected: widget.currentSelectedCountry == null,
              responseCount: totalResponsesGlobal,
              onTap: () => widget.onCountrySelected(null),
            ),
            
            // My Network option - directly under World
            if (!_isLoadingRooms) ...[
              _buildMyNetworkOption(),
            ],

            // Divider between fixed options and searchable content
            Divider(),

            SizedBox(height: 8),

            // Search bar for rooms and countries
            if (_sortedCountries.isNotEmpty || _userRooms.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                    contentPadding: EdgeInsets.symmetric(vertical: 8.0),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              SizedBox(height: 12),
            ],

            // Scrollable list: Generations + Rooms + Countries
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // Generations section
                  ..._buildGenerationsSection(totalResponsesGlobal),

                  // Top 3 rooms with >5 responses
                  ..._buildTopRoomsList(),

                  // Countries heading
                  if (_sortedCountries.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(left: 8, top: 8, bottom: 4),
                      child: Text(
                        'Countries',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.grey[500],
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),

                  // Top 5 countries
                  ..._buildTopCountriesList(totalResponsesGlobal),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildCountryOption({
    required BuildContext context,
    required String countryName,
    required String subtitle,
    required bool isSelected,
    required int responseCount,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected 
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: _getCountryColor(countryName, responseCount),
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    countryName.startsWith('Gen:') ? getGenerationLabel(countryName.substring(4)) : countryName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isSelected
                          ? Theme.of(context).primaryColor
                          : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMyNetworkOption() {
    final isEnabled = _shouldShowMyNetwork;
    final isGreyed = _shouldShowMyNetworkGreyed;
    final isVisible = isEnabled || isGreyed;
    
    if (!isVisible) return SizedBox.shrink();
    
    return InkWell(
      onTap: isEnabled 
        ? () => widget.onCountrySelected('My Network')
        : () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_myNetworkSnackbarMessage),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.only(
                bottom: 50,
                left: 16,
                right: 16,
              ),
              elevation: 100, // High elevation to ensure it appears above dialog
            ),
          );
        },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: widget.currentSelectedCountry == 'My Network' && isEnabled
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor, // Always use primary color
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'My Network',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isEnabled
                        ? (widget.currentSelectedCountry == 'My Network'
                            ? Theme.of(context).primaryColor 
                            : null)
                        : Colors.grey[500],
                      fontWeight: widget.currentSelectedCountry == 'My Network' && isEnabled
                        ? FontWeight.bold 
                        : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Your room network',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isEnabled ? Colors.grey[600] : Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
            if (widget.currentSelectedCountry == 'My Network' && isEnabled)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGenerationsSection(int totalResponsesGlobal) {
    if (widget.generationResponses == null || widget.generationResponses!.isEmpty) {
      return [];
    }

    var genEntries = widget.generationResponses!.entries
        .where((e) => (e.value['total'] as int? ?? 0) > 5)
        .toList()
      ..sort((a, b) {
        final aTotal = a.value['total'] as int? ?? 0;
        final bTotal = b.value['total'] as int? ?? 0;
        return bTotal.compareTo(aTotal);
      });

    if (_searchQuery.isNotEmpty) {
      genEntries = genEntries.where((e) {
        final label = getGenerationLabel(e.key);
        return label.toLowerCase().contains(_searchQuery.toLowerCase());
      }).toList();
    }

    if (genEntries.isEmpty) return [];

    return [
      Padding(
        padding: EdgeInsets.only(left: 8, top: 8, bottom: 4),
        child: Text(
          'Generations',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.grey[500],
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ),
      ...genEntries.map((entry) {
        final genId = entry.key;
        final data = entry.value;
        final total = data['total'] as int? ?? 0;
        final percentage = totalResponsesGlobal > 0 ? (total / totalResponsesGlobal * 100).round() : 0;
        final filterKey = 'Gen:$genId';

        return _buildCountryOption(
          context: context,
          countryName: filterKey,
          subtitle: '$percentage% ($total responses)',
          isSelected: widget.currentSelectedCountry == filterKey,
          responseCount: total,
          onTap: () => widget.onCountrySelected(filterKey),
        );
      }),
    ];
  }

  List<Widget> _buildTopRoomsList() {
    // Sort all rooms by response count (highest first)
    final sortedRooms = List.from(_userRooms);
    sortedRooms.sort((a, b) {
      final aCount = _roomResponseCounts[a['id']] ?? 0;
      final bCount = _roomResponseCounts[b['id']] ?? 0;
      return bCount.compareTo(aCount);
    });
    
    // Filter by search query and ONLY include rooms with 5+ responses
    final filteredRooms = sortedRooms.where((room) {
      final responseCount = _roomResponseCounts[room['id']] ?? 0;
      final hasEnoughResponses = responseCount >= 5;
      final matchesSearch = _searchQuery.isEmpty || 
          room['name'].toString().toLowerCase().contains(_searchQuery.toLowerCase());
      
      return hasEnoughResponses && matchesSearch;
    }).toList();
    
    // Take top 3 rooms with 5+ responses
    final topRooms = filteredRooms.take(3).toList();
    
    return topRooms.map((room) {
      final responseCount = _roomResponseCounts[room['id']] ?? 0;
      
      return _buildRoomOption(
        context: context,
        room: room,
        responseCount: responseCount,
        isEnabled: true, // All rooms shown here have 5+ responses
        isSelected: widget.currentSelectedCountry == 'Room:${room['id']}',
      );
    }).toList();
  }

  Widget _buildRoomOption({
    required BuildContext context,
    required Map<String, dynamic> room,
    required int responseCount,
    required bool isEnabled,
    required bool isSelected,
  }) {
    final roomId = 'Room:${room['id']}';
    final roomName = room['name'].toString();
    
    return InkWell(
      onTap: isEnabled 
        ? () => widget.onCountrySelected(roomId)
        : () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Too few responses from this room (need 5+)'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.only(
                bottom: 50,
                left: 16,
                right: 16,
              ),
              elevation: 100, // High elevation to ensure it appears above dialog
            ),
          );
        },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected && isEnabled
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: isEnabled 
                  ? _getCountryColor(roomId, responseCount)
                  : Colors.grey[400]!,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    roomName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: isEnabled
                        ? (isSelected ? Theme.of(context).primaryColor : null)
                        : Colors.grey[500],
                      fontWeight: isSelected && isEnabled ? FontWeight.bold : null,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '$responseCount responses',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isEnabled ? Colors.grey[600] : Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected && isEnabled)
              Icon(
                Icons.check_circle,
                color: Theme.of(context).primaryColor,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTopCountriesList(int totalResponsesGlobal) {
    // Filter countries by search query
    final filteredCountries = _searchQuery.isEmpty 
        ? _sortedCountries
        : _sortedCountries.where((entry) {
            return entry.key.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();
    
    // Take top 5 countries
    final topCountries = filteredCountries.take(5).toList();
    
    return topCountries.map((entry) {
      final countryName = entry.key;
      final data = entry.value;
      final total = data['total'] as int? ?? 0;
      final percentage = totalResponsesGlobal > 0 ? (total / totalResponsesGlobal * 100).round() : 0;
      
      return _buildCountryOption(
        context: context,
        countryName: countryName,
        subtitle: '$percentage% ($total responses)',
        isSelected: widget.currentSelectedCountry == countryName,
        responseCount: total,
        onTap: () => widget.onCountrySelected(countryName),
      );
    }).toList();
  }
}