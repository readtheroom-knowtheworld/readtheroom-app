// Copyright (C) 2025 Soud Al Kharusi
// SPDX-License-Identifier: AGPL-3.0-or-later

// This file contains a hardcoded list of all countries to avoid database calls
// The list is sorted alphabetically

class CountriesData {
  // Map of country names to their ISO_A3 codes
  static const Map<String, String> countryIsoMap = {
    "Afghanistan": "AFG",
    "Albania": "ALB",
    "Algeria": "DZA",
    "Andorra": "AND",
    "Angola": "AGO",
    "Antigua and Barbuda": "ATG",
    "Argentina": "ARG",
    "Armenia": "ARM",
    "Australia": "AUS",
    "Austria": "AUT",
    "Azerbaijan": "AZE",
    "Bahamas": "BHS",
    "Bahrain": "BHR",
    "Bangladesh": "BGD",
    "Barbados": "BRB",
    "Belarus": "BLR",
    "Belgium": "BEL",
    "Belize": "BLZ",
    "Benin": "BEN",
    "Bhutan": "BTN",
    "Bolivia": "BOL",
    "Bosnia and Herzegovina": "BIH",
    "Botswana": "BWA",
    "Brazil": "BRA",
    "Brunei": "BRN",
    "Bulgaria": "BGR",
    "Burkina Faso": "BFA",
    "Burundi": "BDI",
    "Cabo Verde": "CPV",
    "Cambodia": "KHM",
    "Cameroon": "CMR",
    "Canada": "CAN",
    "Central African Republic": "CAF",
    "Chad": "TCD",
    "Chile": "CHL",
    "China": "CHN",
    "Colombia": "COL",
    "Comoros": "COM",
    "Congo (Congo-Brazzaville)": "COG",
    "Costa Rica": "CRI",
    "Croatia": "HRV",
    "Cuba": "CUB",
    "Cyprus": "CYP",
    "Czechia": "CZE",
    "Democratic Republic of the Congo": "COD",
    "Denmark": "DNK",
    "Djibouti": "DJI",
    "Dominica": "DMA",
    "Dominican Republic": "DOM",
    "Ecuador": "ECU",
    "Egypt": "EGY",
    "El Salvador": "SLV",
    "Equatorial Guinea": "GNQ",
    "Eritrea": "ERI",
    "Estonia": "EST",
    "Eswatini": "SWZ",
    "Ethiopia": "ETH",
    "Fiji": "FJI",
    "Finland": "FIN",
    "France": "FRA",
    "Gabon": "GAB",
    "Gambia": "GMB",
    "Georgia": "GEO",
    "Germany": "DEU",
    "Ghana": "GHA",
    "Greece": "GRC",
    "Grenada": "GRD",
    "Guatemala": "GTM",
    "Guinea": "GIN",
    "Guinea-Bissau": "GNB",
    "Guyana": "GUY",
    "Haiti": "HTI",
    "Holy See": "VAT",
    "Honduras": "HND",
    "Hungary": "HUN",
    "Iceland": "ISL",
    "India": "IND",
    "Indonesia": "IDN",
    "Iran": "IRN",
    "Iraq": "IRQ",
    "Ireland": "IRL",
    "Israel": "ISR",
    "Italy": "ITA",
    "Jamaica": "JAM",
    "Japan": "JPN",
    "Jordan": "JOR",
    "Kazakhstan": "KAZ",
    "Kenya": "KEN",
    "Kiribati": "KIR",
    "Kuwait": "KWT",
    "Kyrgyzstan": "KGZ",
    "Laos": "LAO",
    "Latvia": "LVA",
    "Lebanon": "LBN",
    "Lesotho": "LSO",
    "Liberia": "LBR",
    "Libya": "LBY",
    "Liechtenstein": "LIE",
    "Lithuania": "LTU",
    "Luxembourg": "LUX",
    "Madagascar": "MDG",
    "Malawi": "MWI",
    "Malaysia": "MYS",
    "Maldives": "MDV",
    "Mali": "MLI",
    "Malta": "MLT",
    "Marshall Islands": "MHL",
    "Mauritania": "MRT",
    "Mauritius": "MUS",
    "Mexico": "MEX",
    "Micronesia": "FSM",
    "Moldova": "MDA",
    "Monaco": "MCO",
    "Mongolia": "MNG",
    "Montenegro": "MNE",
    "Morocco": "MAR",
    "Mozambique": "MOZ",
    "Myanmar": "MMR",
    "Namibia": "NAM",
    "Nauru": "NRU",
    "Nepal": "NPL",
    "Netherlands": "NLD",
    "New Zealand": "NZL",
    "Nicaragua": "NIC",
    "Niger": "NER",
    "Nigeria": "NGA",
    "North Korea": "PRK",
    "North Macedonia": "MKD",
    "Norway": "NOR",
    "Oman": "OMN",
    "Pakistan": "PAK",
    "Palau": "PLW",
    "Palestine State": "PSE",
    "Panama": "PAN",
    "Papua New Guinea": "PNG",
    "Paraguay": "PRY",
    "Peru": "PER",
    "Philippines": "PHL",
    "Poland": "POL",
    "Portugal": "PRT",
    "Qatar": "QAT",
    "Romania": "ROU",
    "Russia": "RUS",
    "Rwanda": "RWA",
    "Saint Kitts and Nevis": "KNA",
    "Saint Lucia": "LCA",
    "Saint Vincent and the Grenadines": "VCT",
    "Samoa": "WSM",
    "San Marino": "SMR",
    "Sao Tome and Principe": "STP",
    "Saudi Arabia": "SAU",
    "Senegal": "SEN",
    "Serbia": "SRB",
    "Seychelles": "SYC",
    "Sierra Leone": "SLE",
    "Singapore": "SGP",
    "Slovakia": "SVK",
    "Slovenia": "SVN",
    "Solomon Islands": "SLB",
    "Somalia": "SOM",
    "South Africa": "ZAF",
    "South Korea": "KOR",
    "South Sudan": "SSD",
    "Spain": "ESP",
    "Sri Lanka": "LKA",
    "Sudan": "SDN",
    "Suriname": "SUR",
    "Sweden": "SWE",
    "Switzerland": "CHE",
    "Syria": "SYR",
    "Tajikistan": "TJK",
    "Tanzania": "TZA",
    "Thailand": "THA",
    "Timor-Leste": "TLS",
    "Togo": "TGO",
    "Tonga": "TON",
    "Trinidad and Tobago": "TTO",
    "Tunisia": "TUN",
    "Turkey": "TUR",
    "Turkmenistan": "TKM",
    "Tuvalu": "TUV",
    "Uganda": "UGA",
    "Ukraine": "UKR",
    "United Arab Emirates": "ARE",
    "United Kingdom": "GBR",
    "United States of America": "USA",
    "Uruguay": "URY",
    "Uzbekistan": "UZB",
    "Vanuatu": "VUT",
    "Venezuela": "VEN",
    "Vietnam": "VNM",
    "Yemen": "YEM",
    "Zambia": "ZMB",
    "Zimbabwe": "ZWE"
  };

  // Method to get ISO_A3 code for a country name
  static String getIsoCodeForCountry(String countryName) {
    // First try exact match
    String isoCode = countryIsoMap[countryName] ?? "";
    if (isoCode.isNotEmpty) {
      return isoCode;
    }
    
    // Handle common variations of country names
    final String normalizedName = countryName.trim();
    
    // Handle US variations
    if (normalizedName == "United States" || 
        normalizedName == "USA" || 
        normalizedName == "US" ||
        normalizedName == "America") {
      return "USA";
    }
    
    // Handle UK variations  
    if (normalizedName == "UK" || 
        normalizedName == "Britain" ||
        normalizedName == "Great Britain" ||
        normalizedName == "England") {
      return "GBR";
    }
    
    // Handle other common variations
    if (normalizedName == "Russia" || normalizedName == "Russian Federation") {
      return "RUS";
    }
    
    if (normalizedName == "South Korea" || normalizedName == "Korea, South" || normalizedName == "Republic of Korea") {
      return "KOR";
    }
    
    if (normalizedName == "North Korea" || normalizedName == "Korea, North" || normalizedName == "Democratic People's Republic of Korea") {
      return "PRK";
    }
    
    // Handle China variations
    if (normalizedName == "China" || normalizedName == "People's Republic of China" || normalizedName == "PRC") {
      return "CHN";
    }
    
    // Handle Iran variations
    if (normalizedName == "Iran" || normalizedName == "Islamic Republic of Iran") {
      return "IRN";
    }
    
    // Handle Syria variations
    if (normalizedName == "Syria" || normalizedName == "Syrian Arab Republic") {
      return "SYR";
    }
    
    // Handle Venezuela variations
    if (normalizedName == "Venezuela" || normalizedName == "Bolivarian Republic of Venezuela") {
      return "VEN";
    }
    
    // Handle Tanzania variations
    if (normalizedName == "Tanzania" || normalizedName == "United Republic of Tanzania") {
      return "TZA";
    }
    
    // Handle Bolivia variations
    if (normalizedName == "Bolivia" || normalizedName == "Plurinational State of Bolivia") {
      return "BOL";
    }
    
    // Handle Congo variations
    if (normalizedName == "Democratic Republic of Congo" || normalizedName == "Congo (Kinshasa)" || normalizedName == "DRC") {
      return "COD";
    }
    
    if (normalizedName == "Republic of Congo" || normalizedName == "Congo (Brazzaville)" || normalizedName == "Congo-Brazzaville") {
      return "COG";
    }
    
    // Handle Macedonia variations
    if (normalizedName == "Macedonia" || normalizedName == "Former Yugoslav Republic of Macedonia" || normalizedName == "FYROM") {
      return "MKD";
    }
    
    // Handle Czech Republic variations
    if (normalizedName == "Czech Republic" || normalizedName == "Czechia") {
      return "CZE";
    }
    
    // Handle Myanmar variations
    if (normalizedName == "Myanmar" || normalizedName == "Burma") {
      return "MMR";
    }
    
    // Handle Ivory Coast variations
    if (normalizedName == "Ivory Coast" || normalizedName == "Côte d'Ivoire") {
      return "CIV";
    }
    
    // Try case-insensitive match
    for (var entry in countryIsoMap.entries) {
      if (entry.key.toLowerCase() == normalizedName.toLowerCase()) {
        return entry.value;
      }
    }
    
    return "";
  }

  // Method to get country name from ISO_A3 code
  static String getCountryNameFromIso(String isoCode) {
    for (var entry in countryIsoMap.entries) {
      if (entry.value == isoCode) {
        return entry.key;
      }
    }
    return "";
  }
  
  static const List<String> countries = [
    "Afghanistan",
    "Albania",
    "Algeria",
    "Andorra",
    "Angola",
    "Antigua and Barbuda",
    "Argentina",
    "Armenia",
    "Australia",
    "Austria",
    "Azerbaijan",
    "Bahamas",
    "Bahrain",
    "Bangladesh",
    "Barbados",
    "Belarus",
    "Belgium",
    "Belize",
    "Benin",
    "Bhutan",
    "Bolivia",
    "Bosnia and Herzegovina",
    "Botswana",
    "Brazil",
    "Brunei",
    "Bulgaria",
    "Burkina Faso",
    "Burundi",
    "Cabo Verde",
    "Cambodia",
    "Cameroon",
    "Canada",
    "Central African Republic",
    "Chad",
    "Chile",
    "China",
    "Colombia",
    "Comoros",
    "Congo (Congo-Brazzaville)",
    "Costa Rica",
    "Croatia",
    "Cuba",
    "Cyprus",
    "Czechia",
    "Democratic Republic of the Congo",
    "Denmark",
    "Djibouti",
    "Dominica",
    "Dominican Republic",
    "Ecuador",
    "Egypt",
    "El Salvador",
    "Equatorial Guinea",
    "Eritrea",
    "Estonia",
    "Eswatini",
    "Ethiopia",
    "Fiji",
    "Finland",
    "France",
    "Gabon",
    "Gambia",
    "Georgia",
    "Germany",
    "Ghana",
    "Greece",
    "Grenada",
    "Guatemala",
    "Guinea",
    "Guinea-Bissau",
    "Guyana",
    "Haiti",
    "Holy See",
    "Honduras",
    "Hungary",
    "Iceland",
    "India",
    "Indonesia",
    "Iran",
    "Iraq",
    "Ireland",
    "Israel",
    "Italy",
    "Jamaica",
    "Japan",
    "Jordan",
    "Kazakhstan",
    "Kenya",
    "Kiribati",
    "Kuwait",
    "Kyrgyzstan",
    "Laos",
    "Latvia",
    "Lebanon",
    "Lesotho",
    "Liberia",
    "Libya",
    "Liechtenstein",
    "Lithuania",
    "Luxembourg",
    "Madagascar",
    "Malawi",
    "Malaysia",
    "Maldives",
    "Mali",
    "Malta",
    "Marshall Islands",
    "Mauritania",
    "Mauritius",
    "Mexico",
    "Micronesia",
    "Moldova",
    "Monaco",
    "Mongolia",
    "Montenegro",
    "Morocco",
    "Mozambique",
    "Myanmar",
    "Namibia",
    "Nauru",
    "Nepal",
    "Netherlands",
    "New Zealand",
    "Nicaragua",
    "Niger",
    "Nigeria",
    "North Korea",
    "North Macedonia",
    "Norway",
    "Oman",
    "Pakistan",
    "Palau",
    "Palestine State",
    "Panama",
    "Papua New Guinea",
    "Paraguay",
    "Peru",
    "Philippines",
    "Poland",
    "Portugal",
    "Qatar",
    "Romania",
    "Russia",
    "Rwanda",
    "Saint Kitts and Nevis",
    "Saint Lucia",
    "Saint Vincent and the Grenadines",
    "Samoa",
    "San Marino",
    "Sao Tome and Principe",
    "Saudi Arabia",
    "Senegal",
    "Serbia",
    "Seychelles",
    "Sierra Leone",
    "Singapore",
    "Slovakia",
    "Slovenia",
    "Solomon Islands",
    "Somalia",
    "South Africa",
    "South Korea",
    "South Sudan",
    "Spain",
    "Sri Lanka",
    "Sudan",
    "Suriname",
    "Sweden",
    "Switzerland",
    "Syria",
    "Tajikistan",
    "Tanzania",
    "Thailand",
    "Timor-Leste",
    "Togo",
    "Tonga",
    "Trinidad and Tobago",
    "Tunisia",
    "Turkey",
    "Turkmenistan",
    "Tuvalu",
    "Uganda",
    "Ukraine",
    "United Arab Emirates",
    "United Kingdom",
    "United States of America",
    "Uruguay",
    "Uzbekistan",
    "Vanuatu",
    "Venezuela",
    "Vietnam",
    "Yemen",
    "Zambia",
    "Zimbabwe"
  ];
  
  // Map of countries to their representative cities (3 major cities per country)
  // This is a simplified version - in a real app, this would include more comprehensive data
  static final Map<String, List<Map<String, dynamic>>> countryCities = {
    "United States of America": [
      {"name": "New York", "country_name_en": "United States of America", "population": 8336817},
      {"name": "Los Angeles", "country_name_en": "United States of America", "population": 3979576},
      {"name": "Chicago", "country_name_en": "United States of America", "population": 2693976}
    ],
    "United Kingdom": [
      {"name": "London", "country_name_en": "United Kingdom", "population": 9002488},
      {"name": "Birmingham", "country_name_en": "United Kingdom", "population": 1141816},
      {"name": "Manchester", "country_name_en": "United Kingdom", "population": 547627}
    ],
    "France": [
      {"name": "Paris", "country_name_en": "France", "population": 2175601},
      {"name": "Marseille", "country_name_en": "France", "population": 861635},
      {"name": "Lyon", "country_name_en": "France", "population": 513275}
    ],
    "Germany": [
      {"name": "Berlin", "country_name_en": "Germany", "population": 3669491},
      {"name": "Hamburg", "country_name_en": "Germany", "population": 1841179},
      {"name": "Munich", "country_name_en": "Germany", "population": 1471508}
    ],
    "Japan": [
      {"name": "Tokyo", "country_name_en": "Japan", "population": 13929286},
      {"name": "Osaka", "country_name_en": "Japan", "population": 2691742},
      {"name": "Yokohama", "country_name_en": "Japan", "population": 3726167}
    ],
    "Australia": [
      {"name": "Sydney", "country_name_en": "Australia", "population": 4627345},
      {"name": "Melbourne", "country_name_en": "Australia", "population": 4485211},
      {"name": "Brisbane", "country_name_en": "Australia", "population": 2274560}
    ],
    "Canada": [
      {"name": "Toronto", "country_name_en": "Canada", "population": 2930000},
      {"name": "Montreal", "country_name_en": "Canada", "population": 1780000},
      {"name": "Vancouver", "country_name_en": "Canada", "population": 675218}
    ],
    "China": [
      {"name": "Shanghai", "country_name_en": "China", "population": 24256800},
      {"name": "Beijing", "country_name_en": "China", "population": 21516000},
      {"name": "Guangzhou", "country_name_en": "China", "population": 14498400}
    ],
    "India": [
      {"name": "Mumbai", "country_name_en": "India", "population": 12442373},
      {"name": "Delhi", "country_name_en": "India", "population": 11034555},
      {"name": "Bangalore", "country_name_en": "India", "population": 8443675}
    ],
    "Brazil": [
      {"name": "São Paulo", "country_name_en": "Brazil", "population": 12252023},
      {"name": "Rio de Janeiro", "country_name_en": "Brazil", "population": 6748000},
      {"name": "Brasília", "country_name_en": "Brazil", "population": 3015268}
    ]
    // Note: In a real app, we would include data for all 230 countries
    // This is a simplified version with just 10 countries for brevity
  };
  
  // Method to get all cities (useful for search functionality)
  static List<Map<String, dynamic>> getAllCities() {
    List<Map<String, dynamic>> allCities = [];
    
    // For the countries with detailed city data
    countryCities.forEach((country, cities) {
      // Add IDs to each city
      final citiesWithIds = cities.map((city) {
        return {
          ...city,
          'id': _generateCityId(city['name'], city['country_name_en']),
        };
      }).toList();
      allCities.addAll(citiesWithIds);
    });
    
    // For countries without detailed city data, add a default capital city
    for (String country in countries) {
      if (!countryCities.containsKey(country)) {
        allCities.add({
          "id": _generateCityId("Capital", country),
          "name": "Capital", 
          "country_name_en": country, 
          "population": 1000000
        });
      }
    }
    
    return allCities;
  }

  // Method to get a list of major cities for a specific country
  static List<Map<String, dynamic>> getCitiesForCountry(String country) {
    final cities = countryCities[country] ?? [
      // Default city if none found
      {"name": "Capital City", "country_name_en": country, "population": 1000000}
    ];
    
    // Add IDs to each city
    return cities.map((city) {
      return {
        ...city,
        'id': _generateCityId(city['name'], city['country_name_en']),
      };
    }).toList();
  }

  // Generate a deterministic UUID-like ID from city name and country
  static String _generateCityId(String cityName, String countryName) {
    // Create a deterministic hash-based ID
    final combined = '$cityName-$countryName';
    final hash = combined.hashCode.abs();
    
    // Format as UUID-like string (not a real UUID, but database-compatible)
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return '${hex.substring(0, 8)}-${hex.substring(0, 4)}-${hex.substring(0, 4)}-${hex.substring(0, 4)}-${hex.padRight(12, '0').substring(0, 12)}';
  }
} 