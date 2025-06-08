import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:mapbox_gl/mapbox_gl.dart';

void main() {
  runApp(const TaxiApp());
}

class TaxiApp extends StatelessWidget {
  const TaxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yellow Taxi (Mapbox)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.yellow,
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.yellow),
        ),
        textTheme: const TextTheme(
          headline6: TextStyle(color: Colors.white),
          bodyText2: TextStyle(color: Colors.white),
        ),
      ),
      home: const TaxiHomePage(),
    );
  }
}

class TaxiHomePage extends StatefulWidget {
  const TaxiHomePage({super.key});

  @override
  State<TaxiHomePage> createState() => _TaxiHomePageState();
}

class _TaxiHomePageState extends State<TaxiHomePage> {
  // Map & Location
  LatLng _currentLocation = const LatLng(0, 0);
  LatLng? _destinationLocation;
  final List<LatLng> _routePoints = [];
  final String _mapboxAccessToken = "pk.eyJ1IjoibGJtYW5hZ2VtZW50IiwiYSI6ImNtYm5mbmY3ZTFsd3Aya3NkZDZtZXplNnoifQ.LnMpwMgIO3uYQNJIHIje1A";
  final String _mapboxStyleUrl = "mapbox://styles/mapbox/dark-v10";
  MapController _mapController = MapController();

  // UI State
  String _selectedRideType = 'Car';
  bool _isLoading = false;
  String _searchQuery = '';
  double _fareEstimate = 0.0;
  String _eta = '';

  // Ride Types
  final List<Map<String, dynamic>> _rideTypes = [
    {'type': 'Bike', 'icon': Icons.electric_bike, 'multiplier': 0.7},
    {'type': 'Car', 'icon': Icons.directions_car, 'multiplier': 1.0},
    {'type': 'Premium', 'icon': Icons.directions_car_filled, 'multiplier': 1.5},
  ];

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  // Location Methods
  Future<void> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return _showError('Enable location services');

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return _showError('Location permissions denied');
      }
    }

    Position position = await Geolocator.getCurrentPosition();
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
    });

    _mapController.move(_currentLocation, 15);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  // Routing with Mapbox Directions API
  Future<void> _getRouteDirections() async {
    if (_destinationLocation == null) return;

    setState(() => _isLoading = true);
    _routePoints.clear();

    try {
      final response = await http.get(Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/'
        '${_currentLocation.longitude},${_currentLocation.latitude};'
        '${_destinationLocation!.longitude},${_destinationLocation!.latitude}'
        '?geometries=geojson&access_token=$_mapboxAccessToken',
      ));

      final data = json.decode(response.body);
      if (data['routes'] == null || data['routes'].isEmpty) {
        throw Exception('No route found');
      }

      final coordinates = data['routes'][0]['geometry']['coordinates'];
      setState(() {
        _routePoints.addAll(coordinates.map<LatLng>((coord) => LatLng(coord[1], coord[0])));
      });

      await _calculateFareAndETA(data['routes'][0]['distance'], data['routes'][0]['duration']);
    } catch (e) {
      _showError('Route error: ${e.toString()}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // Fare Calculation
  Future<void> _calculateFareAndETA(double distanceMeters, double durationSeconds) async {
    final multiplier = _rideTypes.firstWhere(
      (type) => type['type'] == _selectedRideType,
    )['multiplier'];

    double baseFare = 2.50;
    double distanceFare = (distanceMeters / 1000) * 1.20;
    double totalFare = (baseFare + distanceFare) * multiplier;
    int etaMinutes = (durationSeconds / 60).round();

    setState(() {
      _fareEstimate = double.parse(totalFare.toStringAsFixed(2));
      _eta = '${etaMinutes} min';
    });
  }

  // Search with Mapbox Geocoding API
  Future<void> _searchDestination(String query) async {
    if (query.isEmpty) return;

    try {
      final response = await http.get(Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$query.json?'
        'proximity=${_currentLocation.longitude},${_currentLocation.latitude}'
        '&access_token=$_mapboxAccessToken',
      ));

      final data = json.decode(response.body);
      if (data['features'] == null || data['features'].isEmpty) {
        return _showError('No results found');
      }

      _showSearchResults(data['features']);
    } catch (e) {
      _showError('Search error');
    }
  }

  void _setDestination(Map<String, dynamic> feature) {
    final coordinates = feature['geometry']['coordinates'];
    final destination = LatLng(coordinates[1], coordinates[0]);

    setState(() {
      _destinationLocation = destination;
    });

    _getRouteDirections();
  }

  void _showSearchResults(List<dynamic> features) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) => ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: features.length,
        itemBuilder: (context, index) => ListTile(
          leading: const Icon(Icons.location_on, color: Colors.yellow),
          title: Text(
            features[index]['place_name'],
            style: const TextStyle(color: Colors.white),
          ),
          onTap: () {
            Navigator.pop(context);
            _setDestination(features[index]);
          },
        ),
      ),
    );
  }

  // Ride Request
  Future<void> _requestRide() async {
    if (_destinationLocation == null) {
      return _showError('Select destination first');
    }

    setState(() => _isLoading = true);
    await Future.delayed(const Duration(seconds: 2));
    setState(() => _isLoading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Ride requested!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              center: _currentLocation,
              zoom: 15.0,
            ),
            layers: [
              TileLayerOptions(
                urlTemplate: 'https://api.mapbox.com/styles/v1/{id}/tiles/{z}/{x}/{y}?access_token={accessToken}',
                additionalOptions: {
                  'accessToken': _mapboxAccessToken,
                  'id': 'mapbox/dark-v10',
                },
              ),
              PolylineLayerOptions(
                polylines: [
                  Polyline(
                    points: _routePoints,
                    strokeWidth: 4.0,
                    color: Colors.yellow,
                  ),
                ],
              ),
              MarkerLayerOptions(
                markers: [
                  if (_currentLocation != null)
                    Marker(
                      point: _currentLocation,
                      builder: (ctx) => const Icon(
                        Icons.location_pin,
                        color: Colors.blue,
                        size: 40,
                      ),
                    ),
                  if (_destinationLocation != null)
                    Marker(
                      point: _destinationLocation!,
                      builder: (ctx) => const Icon(
                        Icons.location_pin,
                        color: Colors.red,
                        size: 40,
                      ),
                    ),
                ],
              ),
            ],
          ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: _buildSearchBar(),
          ),

          Positioned(
            right: 16,
            bottom: 180,
            child: FloatingActionButton(
              backgroundColor: Colors.grey[900]!.withOpacity(0.9),
              mini: true,
              onPressed: _getCurrentLocation,
              child: const Icon(Icons.my_location, color: Colors.yellow),
            ),
          ),

          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: Column(
              children: [
                if (_destinationLocation != null) _buildFareInfo(),
                _buildRideTypeSelector(),
                const SizedBox(height: 16),
                _buildRequestRideButton(),
              ],
            ),
          ),

          if (_isLoading)
            const Center(child: CircularProgressIndicator(color: Colors.yellow)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[900]!.withOpacity(0.9),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search, color: Colors.yellow, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Enter destination...',
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: (value) => _searchQuery = value,
              onSubmitted: _searchDestination,
            ),
          ),
          if (_searchQuery.isNotEmpty)
            GestureDetector(
              onTap: () {
                setState(() {
                  _searchQuery = '';
                  _destinationLocation = null;
                  _routePoints.clear();
                });
              },
              child: const Icon(Icons.close, color: Colors.grey, size: 20),
            ),
        ],
      ),
    );
  }

  Widget _buildRideTypeSelector() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900]!.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _rideTypes.map((type) {
          bool isSelected = _selectedRideType == type['type'];
          return GestureDetector(
            onTap: () {
              setState(() => _selectedRideType = type['type']);
              if (_destinationLocation != null) {
                _getRouteDirections();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.yellow[800]!.withOpacity(0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: isSelected ? Border.all(color: Colors.yellow, width: 1.5) : null,
              ),
              child: Column(
                children: [
                  Icon(type['icon'], 
                    color: isSelected ? Colors.yellow : Colors.grey,
                    size: 24),
                  const SizedBox(height: 4),
                  Text(
                    type['type'],
                    style: TextStyle(
                      color: isSelected ? Colors.yellow : Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFareInfo() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.grey[900]!.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Estimated Fare', style: TextStyle(color: Colors.grey)),
              Text('\$$_fareEstimate', 
                style: const TextStyle(color: Colors.yellow, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('ETA', style: TextStyle(color: Colors.grey)),
              Text(_eta, 
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRequestRideButton() {
    return GestureDetector(
      onTap: _requestRide,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 32),
        decoration: BoxDecoration(
          color: Colors.yellow,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.yellow.withOpacity(0.3),
              blurRadius: 15,
              spreadRadius: 2,
            ),
          ],
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.black,
                  strokeWidth: 3,
                ),
              )
            : const Text(
                'REQUEST RIDE',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
      ),
    );
  }
}