# ReadTheRoom Hardcoded Data

This directory contains hardcoded data used by the application to reduce database dependencies.

## Countries Data

The `countries_data.dart` file contains:

1. A complete list of 230 countries, sorted alphabetically
2. A mapping of major countries to their top cities (population data included)
3. Helper methods to retrieve and work with this data

This approach eliminates the need to connect to Supabase to load country data, improving app performance and reliability.

## Implementation Details

- The `LocationService` class has been modified to use the hardcoded data instead of making Supabase queries
- The `QuestionService.getResponsesByCountry()` method now generates deterministic dummy data for visualization
- City data is provided for major countries, with fallback "Capital" cities for others

## Advantages

- Reduces API calls to Supabase
- Makes the app work without internet connection
- Provides consistent data for testing and development
- Eliminates potential issues with Row Level Security (RLS) policies

## Future Improvements

- Add comprehensive city data for all countries
- Include additional metadata like country codes, flags, etc.
- Implement a hybrid approach where hardcoded data is used as fallback when the database is unavailable 