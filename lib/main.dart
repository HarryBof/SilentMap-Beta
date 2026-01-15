import 'dart:async';
import 'dart:convert';
import 'dart:math'; 
import 'dart:ui' as ui; 
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; 
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:http/http.dart' as http;

// --- 1. ĐỊNH NGHĨA LOẠI ĐỊA ĐIỂM ---
enum PlaceType { cafe, library, workspace }

// --- 2. CLASS DỮ LIỆU ĐỊA ĐIỂM ---
class PlaceData {
  final String name;
  final String address;
  final LatLng location;
  final PlaceType type;
  final bool hasWifi;
  final String noiseLevel;
  bool isFavorite; 

  PlaceData({
    required this.name,
    required this.address,
    required this.location,
    required this.type,
    required this.hasWifi,
    required this.noiseLevel,
    this.isFavorite = false,
  });

  IconData get icon {
    switch (type) {
      case PlaceType.workspace: return Icons.computer;
      case PlaceType.library: return Icons.local_library;
      case PlaceType.cafe: return Icons.local_cafe;
    }
  }

  Color get color {
    switch (type) {
      case PlaceType.workspace: return Colors.blueAccent;
      case PlaceType.library: return Colors.orange;
      case PlaceType.cafe: return Colors.brown;
    }
  }

  // Màu hiển thị trên icon loa nhỏ
  Color get noiseColor {
    double db = _parseDb();
    if (db < 50) return Colors.green; 
    if (db < 70) return Colors.amber.shade800; 
    if (db < 85) return Colors.red; 
    return Colors.purple; 
  }

  double _parseDb() {
    try {
      return double.parse(noiseLevel.split(' ')[0]);
    } catch (e) {
      return 50.0; 
    }
  }

  // Thuật toán tạo dữ liệu biểu đồ
  List<double> generateHourlyNoise() {
    double baseDb = _parseDb();
    List<double> data = [];
    Random random = Random(name.hashCode); 

    for (int hour = 7; hour <= 22; hour++) {
      double adjustment = 0;
      if (hour >= 7 && hour <= 9) adjustment = -10; 
      else if (hour >= 12 && hour <= 13) adjustment = 5; 
      else if (hour >= 18 && hour <= 20) adjustment = 8; 
      else if (hour >= 21) adjustment = -5; 

      double noise = baseDb + adjustment + (random.nextDouble() * 6 - 3);
      if (noise < 30) noise = 30;
      if (noise > 100) noise = 100;
      data.add(noise);
    }
    return data;
  }
}

void main() {
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: SilentMapApp()));
}

class SilentMapApp extends StatefulWidget {
  const SilentMapApp({super.key});
  @override
  State<SilentMapApp> createState() => _SilentMapAppState();
}

class _SilentMapAppState extends State<SilentMapApp> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  LatLng _myLocation = LatLng(21.0056, 105.8433);
  double _accuracy = 100.0;
  
  List<LatLng> _routePoints = []; 
  bool _isRouting = false; 
  double _routeDistanceKm = 0.0; 
  double _routeDurationSec = 0.0; 

  final List<PlaceData> _places = []; 
  PlaceData? _selectedPlace;

  // Variables cho đo độ ồn
  NoiseMeter? _noiseMeter;
  StreamSubscription<NoiseReading>? _noiseSubscription;
  bool _isRecording = false;
  bool _hasShownWarning = false; 
  List<double> _readings = []; 
  double _currentDb = 0.0; 
  double _averageDb = 0.0; 
  String _noiseStatus = "Sẵn sàng đo"; 
  Timer? _smoothTimer;
  final int _measureDurationSec = 30; 
  double _progressValue = 0.0; 
  bool _showNoisePanel = false;

  @override
  void initState() {
    super.initState();
    _loadPlacesFromCSV(); 
    _locateMe();
  }

  Future<void> _loadPlacesFromCSV() async {
    try {
      final String rawData = await rootBundle.loadString("assets/places.csv");
      List<String> lines = rawData.split('\n');
      setState(() { _places.clear(); });

      for (int i = 1; i < lines.length; i++) {
        String line = lines[i].trim();
        if (line.isEmpty) continue; 
        List<String> row = line.split(',');
        if (row.length < 7) continue;

        String name = row[0].trim();
        String address = row[1].trim();
        double lat = double.tryParse(row[2].trim()) ?? 21.0;
        double lng = double.tryParse(row[3].trim()) ?? 105.0;
        String typeStr = row[4].trim().toLowerCase();
        bool hasWifi = row[5].trim().toLowerCase() == 'true';
        String noise = row[6].trim();

        PlaceType type = PlaceType.cafe;
        if (typeStr == 'library') type = PlaceType.library;
        if (typeStr == 'workspace') type = PlaceType.workspace;

        setState(() {
          _places.add(PlaceData(
            name: name, address: address, location: LatLng(lat, lng),
            type: type, hasWifi: hasWifi, noiseLevel: noise,
          ));
        });
      }
    } catch (e) { print("Lỗi đọc CSV: $e"); }
  }

  @override
  void dispose() {
    _noiseSubscription?.cancel();
    _smoothTimer?.cancel();
    super.dispose();
  }

  Future<void> _locateMe() async {
    if (await Permission.location.request().isGranted) {
      try {
        Position position = await Geolocator.getCurrentPosition();
        setState(() {
          _myLocation = LatLng(position.latitude, position.longitude);
          _accuracy = position.accuracy < 30 ? 30 : position.accuracy;
        });
        _animatedMapMove(_myLocation, 16.0, 0.0);
      } catch (e) { print(e); }
    }
  }

  void _animatedMapMove(LatLng destLocation, double destZoom, double destRotation) {
    final latTween = Tween<double>(begin: _mapController.camera.center.latitude, end: destLocation.latitude);
    final lngTween = Tween<double>(begin: _mapController.camera.center.longitude, end: destLocation.longitude);
    final zoomTween = Tween<double>(begin: _mapController.camera.zoom, end: destZoom);
    final rotateTween = Tween<double>(begin: _mapController.camera.rotation, end: destRotation);
    final controller = AnimationController(duration: const Duration(milliseconds: 1500), vsync: this);
    final Animation<double> animation = CurvedAnimation(parent: controller, curve: Curves.fastOutSlowIn);

    controller.addListener(() {
      _mapController.moveAndRotate(
        LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
        zoomTween.evaluate(animation),
        rotateTween.evaluate(animation),
      );
    });
    animation.addStatusListener((status) { if (status == AnimationStatus.completed) controller.dispose(); });
    controller.forward();
  }

  Future<void> _getDirections(LatLng destination) async {
    setState(() { _isRouting = true; });
    final String url = 'http://router.project-osrm.org/route/v1/driving/'
        '${_myLocation.longitude},${_myLocation.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson';
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final route = data['routes'][0];
        final List<dynamic> coords = route['geometry']['coordinates'];
        final newRoutePoints = coords.map((c) => LatLng(c[1], c[0])).toList();
        
        double distanceMeters = (route['distance'] as num).toDouble();
        double durationSeconds = (route['duration'] as num).toDouble();

        setState(() {
          _routePoints = newRoutePoints;
          _routeDistanceKm = distanceMeters / 1000;
          _routeDurationSec = durationSeconds;
          _isRouting = false;
          _showNoisePanel = false; 
        });

        if (newRoutePoints.isNotEmpty) {
          final bounds = LatLngBounds.fromPoints([_myLocation, destination, ...newRoutePoints]);
          final cameraFit = CameraFit.bounds(
            bounds: bounds,
            padding: const EdgeInsets.only(top: 100, bottom: 250, left: 50, right: 50),
          );
          final centerZoom = cameraFit.fit(_mapController.camera);
          _animatedMapMove(centerZoom.center, centerZoom.zoom, 0.0);
        }
      } else { setState(() => _isRouting = false); }
    } catch (e) { setState(() => _isRouting = false); }
  }

  void _clearRoute() { setState(() { _routePoints = []; _routeDistanceKm = 0; }); }
  void _toggleFavorite(PlaceData place) { setState(() { place.isFavorite = !place.isFavorite; }); }
  void _openSearchSheet() { _showListSheet(_places, "Tìm kiếm địa điểm"); }
  void _openFavoritesSheet() {
    List<PlaceData> favoritePlaces = _places.where((p) => p.isFavorite).toList();
    _showListSheet(favoritePlaces, "Danh sách Yêu thích");
  }

  void _showListSheet(List<PlaceData> dataList, String titleHint) {
    showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9, minChildSize: 0.5, maxChildSize: 0.95,
        builder: (_, scrollController) => SearchResultSheet(
          scrollController: scrollController, allPlaces: dataList, hintText: titleHint, myLocation: _myLocation, 
          onPlaceSelected: (place) {
            Navigator.pop(context); 
            setState(() => _selectedPlace = place); 
            _animatedMapMove(place.location, 17.0, 0.0); 
          },
          onToggleFavorite: (place) => _toggleFavorite(place),
          onGetDirection: (place) { Navigator.pop(context); _getDirections(place.location); },
        ),
      ),
    );
  }

  void _showAddPlaceDialog() {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController addrCtrl = TextEditingController();
    PlaceType selectedType = PlaceType.cafe;
    bool hasWifi = true;
    const Color primaryColor = Color(0xFF009688); 
    String currentNoiseLevelStr = "${_averageDb.toStringAsFixed(1)} dB";

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              backgroundColor: Colors.white,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(child: Text('Ghim vị trí đo được', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                      const SizedBox(height: 20),
                      Container(
                        width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(color: primaryColor.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.graphic_eq, color: primaryColor), const SizedBox(width: 8),
                            Text('Độ ồn: $currentNoiseLevelStr', style: const TextStyle(color: primaryColor, fontWeight: FontWeight.bold, fontSize: 16)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(controller: nameCtrl, decoration: InputDecoration(prefixIcon: const Icon(Icons.place_outlined), hintText: 'Tên địa điểm', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))),
                      const SizedBox(height: 12),
                      TextField(controller: addrCtrl, decoration: InputDecoration(prefixIcon: const Icon(Icons.map_outlined), hintText: 'Địa chỉ', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))),
                      const SizedBox(height: 20),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
                          const SizedBox(width: 10),
                          ElevatedButton(
                            onPressed: () {
                               if (nameCtrl.text.isEmpty) return;
                               final newPlace = PlaceData(name: nameCtrl.text, address: addrCtrl.text.isEmpty ? "Chưa cập nhật" : addrCtrl.text, location: _myLocation, type: selectedType, hasWifi: hasWifi, noiseLevel: currentNoiseLevelStr);
                               setState(() { _places.add(newPlace); _selectedPlace = newPlace; _showNoisePanel = false; });
                               Navigator.pop(context);
                            },
                            child: const Text('LƯU GHIM'),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<Color> _getGradientColors(double db) {
    if (db < 50) return [Colors.greenAccent, Colors.teal];
    else if (db < 70) return [Colors.yellow, Colors.orange];
    else if (db < 85) return [Colors.orange, Colors.red];
    else return [Colors.redAccent, Colors.purple];
  }

  void _preMeasureCheck() {
    if (_isRecording) return; 
    if (_hasShownWarning) { _startMeasurement(); return; }
    showDialog(context: context, builder: (context) => AlertDialog(
        title: const Text("Lưu ý"),
        content: const Text("Vui lòng giữ yên lặng khi đo."),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Hủy")), ElevatedButton(onPressed: () { setState(() { _hasShownWarning = true; }); Navigator.pop(context); _startMeasurement(); }, child: const Text("ĐO NGAY"))],
      ),
    );
  }

  void _startMeasurement() async {
    if (await Permission.microphone.request().isGranted) {
      setState(() { _isRecording = true; _readings.clear(); _currentDb = 0; _averageDb = 0; _progressValue = 0.0; _noiseStatus = "Đang thu thập..."; });
      double step = 0.25 / _measureDurationSec; 
      _smoothTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
        setState(() { _progressValue += step; if (_progressValue >= 1.0) { _progressValue = 1.0; _finishMeasurement(); } });
      });
      try {
        _noiseMeter ??= NoiseMeter();
        _noiseSubscription = _noiseMeter!.noise.listen(
          (NoiseReading r) { if (mounted) setState(() { _readings.add(r.meanDecibel); _currentDb = r.meanDecibel; }); },
          onError: (e) => _finishMeasurement(),
        );
      } catch (e) { print(e); }
    }
  }

  void _finishMeasurement() {
    _noiseSubscription?.cancel(); _smoothTimer?.cancel();
    double kq = 0; String kl = "";
    if (_readings.isNotEmpty) {
      kq = _readings.reduce((a, b) => a + b) / _readings.length;
      if (kq < 50) kl = "Yên tĩnh"; else if (kq < 70) kl = "Bình thường"; else if (kq < 85) kl = "Khá ồn"; else kl = "Nguy hiểm";
    }
    setState(() { _isRecording = false; _averageDb = kq; _currentDb = kq; _progressValue = 0.0; _noiseStatus = "Kết quả: $kl"; });
  }

  @override
  Widget build(BuildContext context) {
    bool hasFinishedMeasuring = !_isRecording && _averageDb > 0;
    List<Color> currentGradient = _getGradientColors(_currentDb);
    
    int walkTime = (_routeDistanceKm / 5 * 60).round();
    int bikeTime = (_routeDistanceKm / 30 * 60).round();
    int carTime = (_routeDistanceKm / 40 * 60).round();

    bool isNavigating = _routePoints.isNotEmpty;

    return Scaffold(
      resizeToAvoidBottomInset: false, 
      body: Stack(
        children: [
          // 1. MAP
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: _myLocation, initialZoom: 16.0, onTap: (_, __) => setState(() => _selectedPlace = null)),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.hust.silentmap'),
              
              if (_routePoints.isNotEmpty) ...[
                 PolylineLayer(polylines: [Polyline(points: _routePoints, strokeWidth: 5.0, color: Colors.blueAccent)]),
                 MarkerLayer(markers: [
                   Marker(point: _routePoints[_routePoints.length ~/ 2], width: 80, height: 30, child: Container(alignment: Alignment.center, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.blueAccent)), child: Text("${_routeDistanceKm.toStringAsFixed(1)} km", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blueAccent))))
                 ]),
              ],

              CircleLayer(circles: [CircleMarker(point: _myLocation, radius: _accuracy, useRadiusInMeter: true, color: Colors.blue.withOpacity(0.1), borderColor: Colors.blue.withOpacity(0.3), borderStrokeWidth: 1)]),
              
              MarkerLayer(
                markers: [
                  Marker(point: _myLocation, width: 60, height: 60, child: const PulsingLocationDot()),
                  
                  ..._places.where((place) {
                    if (isNavigating) return place == _selectedPlace;
                    return true; 
                  }).map((place) => Marker(
                    point: place.location, 
                    width: 50, height: 50, 
                    alignment: Alignment.bottomCenter, // Mũi nhọn chạm đất
                    child: GestureDetector(
                      onTap: () { setState(() { _selectedPlace = place; }); },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end, 
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: place.color, width: 2), boxShadow: [const BoxShadow(color: Colors.black26, blurRadius: 4)]),
                            child: Icon(place.icon, color: place.color, size: 24),
                          ),
                          ClipPath(clipper: TriangleClipper(), child: Container(color: place.color, width: 10, height: 8))
                        ],
                      ),
                    ),
                  )).toList(),

                  // --- WIDGET BONG BÓNG ---
                  if (_selectedPlace != null && !isNavigating) 
                    Marker(
                      point: _selectedPlace!.location, 
                      width: 320, 
                      height: 326, // Tăng chiều cao để chứa đủ nội dung
                      alignment: Alignment.topCenter, 
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          InfoBubble(
                            place: _selectedPlace!, 
                            myLocation: _myLocation, 
                            onDirectionsPressed: () { _getDirections(_selectedPlace!.location); },
                            onFavoritePressed: () => _toggleFavorite(_selectedPlace!), 
                          ),
                          const SizedBox(height: 2), 
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),

          // 2. NÚT TÌM KIẾM
          Positioned(
            top: 50, right: 15, 
            child: ElevatedButton.icon(
              onPressed: _openSearchSheet, 
              icon: const Icon(Icons.search, color: Colors.teal),
              label: const Text("Tìm kiếm", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, elevation: 4, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), shape: const StadiumBorder()),
            ),
          ),

          // 3. NOISE PANEL
          if (_showNoisePanel)
            Positioned(
              bottom: 20, left: 15, right: 15,
              child: Card(
                elevation: 15, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                child: Padding(
                  padding: const EdgeInsets.all(25.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Phân tích tiếng ồn", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          InkWell(
                            onTap: _isRecording ? null : () => setState(() => _showNoisePanel = false),
                            child: CircleAvatar(backgroundColor: _isRecording ? Colors.grey.shade300 : Colors.grey, radius: 12, child: const Icon(Icons.close, size: 16, color: Colors.white)),
                          )
                        ],
                      ),
                      const SizedBox(height: 20),
                      ShaderMask(
                        shaderCallback: (Rect bounds) => LinearGradient(colors: currentGradient, begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: Text(_currentDb > 0 ? _currentDb.toStringAsFixed(1) : "--", style: const TextStyle(fontSize: 70, fontWeight: FontWeight.w900, color: Colors.white)),
                      ),
                      const Text("dB", style: TextStyle(color: Colors.grey)),
                      if (_isRecording) ...[const SizedBox(height: 15), LinearProgressIndicator(value: _progressValue, backgroundColor: Colors.grey[200], color: currentGradient.last, minHeight: 8, borderRadius: BorderRadius.circular(5))],
                      const SizedBox(height: 15),
                      SizedBox(width: double.infinity, height: 50, child: Row(children: [Expanded(flex: hasFinishedMeasuring ? 4 : 1, child: ElevatedButton(onPressed: _isRecording ? null : _preMeasureCheck, style: ElevatedButton.styleFrom(backgroundColor: currentGradient.last, foregroundColor: Colors.white), child: Text(_isRecording ? "ĐO..." : "BẮT ĐẦU ĐO"))), if (hasFinishedMeasuring) ...[const SizedBox(width: 10), Expanded(flex: 6, child: ElevatedButton.icon(onPressed: _showAddPlaceDialog, icon: const Icon(Icons.add_location_alt), label: const Text("GHIM VỊ TRÍ"), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white)))]])),
                    ],
                  ),
                ),
              ),
            ),

          // 4. BUTTONS
          if (!_routePoints.isNotEmpty) 
            Positioned(
              bottom: _showNoisePanel ? 370 : 30, right: 15,
              child: Column(children: [
                  FloatingActionButton(heroTag: "btnFav", onPressed: _openFavoritesSheet, backgroundColor: Colors.white, child: const Icon(Icons.favorite, color: Colors.redAccent)),
                  const SizedBox(height: 15),
                  FloatingActionButton(heroTag: "btnNoise", onPressed: _isRecording ? null : () => setState(() => _showNoisePanel = !_showNoisePanel), backgroundColor: _isRecording ? Colors.grey[300] : Colors.white, child: Icon(Icons.graphic_eq, color: _showNoisePanel ? Colors.teal : Colors.black87)),
                  const SizedBox(height: 15),
                  FloatingActionButton(heroTag: "btnGPS", onPressed: _locateMe, backgroundColor: Colors.white, child: const Icon(Icons.my_location, color: Colors.blue)),
              ]),
            ),

          // 5. NAV BAR
          if (_routePoints.isNotEmpty)
            Positioned(bottom: 0, left: 0, right: 0, child: Container(padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20), decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)], borderRadius: BorderRadius.vertical(top: Radius.circular(20))), child: Column(mainAxisSize: MainAxisSize.min, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [_buildTransportItem(Icons.directions_walk, "$walkTime p"), _buildTransportItem(Icons.two_wheeler, "$bikeTime p"), _buildTransportItem(Icons.directions_car, "$carTime p")]), const SizedBox(height: 10), SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _clearRoute, style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), child: const Text("Kết thúc dẫn đường")))]))),
        ],
      ),
    );
  }

  Widget _buildTransportItem(IconData icon, String time) {
    return Column(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), shape: BoxShape.circle), child: Icon(icon, color: Colors.blue)), const SizedBox(height: 4), Text(time, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.blue))]);
  }
}

class SearchResultSheet extends StatefulWidget {
  final ScrollController scrollController;
  final List<PlaceData> allPlaces;
  final String hintText;
  final LatLng myLocation; 
  final Function(PlaceData) onPlaceSelected;
  final Function(PlaceData) onToggleFavorite;
  final Function(PlaceData) onGetDirection;

  const SearchResultSheet({super.key, required this.scrollController, required this.allPlaces, required this.hintText, required this.myLocation, required this.onPlaceSelected, required this.onToggleFavorite, required this.onGetDirection});

  @override
  State<SearchResultSheet> createState() => _SearchResultSheetState();
}
class _SearchResultSheetState extends State<SearchResultSheet> {
  String _searchQuery = "";
  final Set<PlaceType> _selectedFilters = {}; 
  int _currentMax = 8; 
  bool _isLoadingMore = false;
  late ScrollController _internalScrollController;

  @override
  void initState() { super.initState(); _internalScrollController = widget.scrollController; _internalScrollController.addListener(_scrollListener); }
  void _scrollListener() { if (_internalScrollController.position.pixels == _internalScrollController.position.maxScrollExtent) _loadMore(); }
  void _loadMore() async { if (_isLoadingMore) return; setState(() => _isLoadingMore = true); await Future.delayed(const Duration(seconds: 1)); setState(() { _currentMax += 5; _isLoadingMore = false; }); }
  String _getDistanceString(LatLng p1, LatLng p2) { double dist = Geolocator.distanceBetween(p1.latitude, p1.longitude, p2.latitude, p2.longitude); return dist >= 1000 ? "${(dist/1000).toStringAsFixed(1)} km" : "${dist.toStringAsFixed(0)} m"; }

  @override
  Widget build(BuildContext context) {
    List<PlaceData> filteredPlaces = widget.allPlaces.where((place) { bool matchText = place.name.toLowerCase().contains(_searchQuery.toLowerCase()) || place.address.toLowerCase().contains(_searchQuery.toLowerCase()); bool matchType = _selectedFilters.isEmpty || _selectedFilters.contains(place.type); return matchText && matchType; }).toList();
    int itemCountToDisplay = min(filteredPlaces.length, _currentMax);
    bool hasMore = filteredPlaces.length > _currentMax;

    return Container(decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))), child: Column(children: [Center(child: Container(margin: const EdgeInsets.only(top: 10), width: 40, height: 5, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)))), Padding(padding: const EdgeInsets.all(15.0), child: TextField(autofocus: false, onChanged: (val) => setState(() => _searchQuery = val), decoration: InputDecoration(hintText: widget.hintText, prefixIcon: const Icon(Icons.search), suffixIcon: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)), filled: true, fillColor: Colors.grey[100], border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 0)))), SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 15), child: Row(children: [_buildFilterChip("Cafe", PlaceType.cafe), const SizedBox(width: 10), _buildFilterChip("Thư viện", PlaceType.library), const SizedBox(width: 10), _buildFilterChip("Work-space", PlaceType.workspace)])), const Divider(), Expanded(child: filteredPlaces.isEmpty ? const Center(child: Text("Không tìm thấy địa điểm nào.", style: TextStyle(color: Colors.grey))) : ListView.builder(controller: _internalScrollController, itemCount: itemCountToDisplay + (hasMore ? 1 : 0), itemBuilder: (context, index) { if (index == itemCountToDisplay) return const Padding(padding: EdgeInsets.all(10), child: Center(child: CircularProgressIndicator())); final place = filteredPlaces[index]; String distance = _getDistanceString(widget.myLocation, place.location); return ListTile(onTap: () => widget.onPlaceSelected(place), leading: CircleAvatar(backgroundColor: place.color.withOpacity(0.1), child: Icon(place.icon, color: place.color)), title: Text(place.name, style: const TextStyle(fontWeight: FontWeight.bold)), subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(place.address, maxLines: 1, overflow: TextOverflow.ellipsis), const SizedBox(height: 4), Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: place.noiseColor.withOpacity(0.15), borderRadius: BorderRadius.circular(4)), child: Text(place.noiseLevel, style: TextStyle(fontSize: 11, color: place.noiseColor, fontWeight: FontWeight.bold))), const SizedBox(width: 8), Icon(Icons.near_me, size: 14, color: Colors.grey[600]), const SizedBox(width: 2), Text(distance, style: TextStyle(fontSize: 11, color: Colors.grey[600], fontWeight: FontWeight.bold))])]), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.directions, color: Colors.blue), onPressed: () => widget.onGetDirection(place)), IconButton(icon: Icon(place.isFavorite ? Icons.favorite : Icons.favorite_border, color: place.isFavorite ? Colors.red : Colors.grey), onPressed: () { widget.onToggleFavorite(place); setState(() {}); })])); }))]));
  }
  Widget _buildFilterChip(String label, PlaceType type) { bool isSelected = _selectedFilters.contains(type); return FilterChip(label: Text(label), selected: isSelected, onSelected: (bool selected) { setState(() { if (selected) _selectedFilters.add(type); else _selectedFilters.remove(type); }); }, selectedColor: Colors.teal.withOpacity(0.2), checkmarkColor: Colors.teal, labelStyle: TextStyle(color: isSelected ? Colors.teal : Colors.black), backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: isSelected ? Colors.teal : Colors.grey.shade300))); }
}

// --- WIDGET CHART (CẬP NHẬT: MÀU XÁM + CHỈ TÔ MÀU CỘT HIỆN TẠI) ---
// --- CẬP NHẬT: HIỂN THỊ ĐÚNG PHÚT ---
class NoiseChart extends StatelessWidget {
  final List<double> hourlyData;
  const NoiseChart({super.key, required this.hourlyData});

  @override
  Widget build(BuildContext context) {
    // 1. Lấy thời gian thực tế
    final now = DateTime.now();
    int currentHour = now.hour;
    int currentMinute = now.minute;

    // 2. Format phút: Đảm bảo luôn có 2 chữ số (VD: 9 -> 09)
    String minuteStr = currentMinute.toString().padLeft(2, '0');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Dự báo độ ồn", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
            // Badge giờ hiện tại
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
              // 3. Hiển thị giờ : phút
              child: Text("Bây giờ: $currentHour:$minuteStr", style: const TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold)),
            )
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 100, 
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end, 
            mainAxisAlignment: MainAxisAlignment.spaceBetween, 
            children: List.generate(hourlyData.length, (index) {
              int hour = 7 + index; 
              bool isNow = hour == currentHour;
              double noiseVal = hourlyData[index];
              
              // Logic màu: Chỉ tô màu cột hiện tại, còn lại xám
              Color barColor;
              if (isNow) {
                 if (noiseVal < 55) barColor = Colors.green; 
                 else if (noiseVal < 75) barColor = Colors.amber; 
                 else barColor = Colors.redAccent;
              } else {
                 barColor = Colors.grey.shade300; 
              }

              double barHeight = (noiseVal - 20) * 1.2; 
              if (barHeight < 10) barHeight = 10;
              if (barHeight > 80) barHeight = 80;

              return Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isNow) 
                    const Text("Now", style: TextStyle(fontSize: 9, color: Colors.blue, fontWeight: FontWeight.bold, height: 1))
                  else 
                    const SizedBox(height: 9), 

                  Container(
                    width: 12, 
                    height: barHeight,
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(
                      color: barColor, 
                      borderRadius: BorderRadius.circular(3),
                      border: isNow ? Border.all(color: Colors.blue, width: 2) : null,
                    ),
                  ),
                  
                  Text(
                    (hour == 7 || hour == 12 || hour == 18 || hour == 22) ? "$hour" : "", 
                    style: const TextStyle(fontSize: 9, color: Colors.grey, height: 1)
                  ),
                ],
              );
            }),
          ),
        ),
      ],
    );
  }
}
// --- WIDGET BONG BÓNG ---
class InfoBubble extends StatelessWidget {
  final PlaceData place;
  final LatLng myLocation; 
  final VoidCallback onDirectionsPressed;
  final VoidCallback onFavoritePressed; 

  const InfoBubble({super.key, required this.place, required this.myLocation, required this.onDirectionsPressed, required this.onFavoritePressed});

  String _getDistanceString() {
    double dist = Geolocator.distanceBetween(myLocation.latitude, myLocation.longitude, place.location.latitude, place.location.longitude);
    return dist >= 1000 ? "${(dist/1000).toStringAsFixed(1)} km" : "${dist.toStringAsFixed(0)} m";
  }

  @override
  Widget build(BuildContext context) {
    String distance = _getDistanceString();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [const BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(place.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 4),
                        Row(children: [const Icon(Icons.location_on, size: 14, color: Colors.grey), const SizedBox(width: 4), Expanded(child: Text(place.address, style: const TextStyle(fontSize: 12, color: Colors.grey)))]),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: onDirectionsPressed,
                        child: Column(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), shape: BoxShape.circle), child: const Icon(Icons.directions, color: Colors.blue, size: 24)), const SizedBox(height: 2), const Text("Dẫn đường", style: TextStyle(color: Colors.blue, fontSize: 10, fontWeight: FontWeight.bold))]),
                      ),
                      const SizedBox(width: 15), 
                      GestureDetector(
                        onTap: onFavoritePressed,
                        child: Column(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), shape: BoxShape.circle), child: Icon(place.isFavorite ? Icons.favorite : Icons.favorite_border, color: Colors.red, size: 24)), const SizedBox(height: 2), const Text("Yêu thích", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold))]),
                      ),
                    ],
                  )
                ],
              ),
              const Divider(height: 15),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [Icon(Icons.volume_up, size: 16, color: place.noiseColor), const SizedBox(width: 5), Text(place.noiseLevel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: place.noiseColor))]),
                  Row(children: [Icon(Icons.near_me, size: 14, color: Colors.grey[600]), const SizedBox(width: 3), Text(distance, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[600]))]),
                  Row(children: [Icon(place.hasWifi ? Icons.wifi : Icons.wifi_off, size: 16, color: place.hasWifi ? Colors.blue : Colors.grey), const SizedBox(width: 5), Text(place.hasWifi ? "Wifi Free" : "No Wifi", style: const TextStyle(fontSize: 12))]),
                ],
              ),
              const SizedBox(height: 12),
              
              NoiseChart(hourlyData: place.generateHourlyNoise()), 
            ],
          ),
        ),
        ClipPath(clipper: TriangleClipper(), child: Container(color: Colors.white, width: 14, height: 10)),
      ],
    );
  }
}

class TriangleClipper extends CustomClipper<ui.Path> {
  @override
  ui.Path getClip(Size size) { final path = ui.Path(); path.lineTo(size.width / 2, size.height); path.lineTo(size.width, 0); path.close(); return path; }
  @override
  bool shouldReclip(CustomClipper<ui.Path> oldClipper) => false;
}
class PulsingLocationDot extends StatefulWidget { const PulsingLocationDot({super.key}); @override State<PulsingLocationDot> createState() => _PulsingLocationDotState(); }
class _PulsingLocationDotState extends State<PulsingLocationDot> with SingleTickerProviderStateMixin { late AnimationController _controller; late Animation<double> _animation; @override void initState() { super.initState(); _controller = AnimationController(duration: const Duration(milliseconds: 1500), vsync: this)..repeat(reverse: true); _animation = Tween<double>(begin: 0.8, end: 1.1).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)); } @override void dispose() { _controller.dispose(); super.dispose(); } @override Widget build(BuildContext context) { return AnimatedBuilder(animation: _animation, builder: (context, child) => Transform.scale(scale: _animation.value, child: Stack(alignment: Alignment.center, children: [Container(width: 22, height: 22, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 3)])), Container(width: 16, height: 16, decoration: const BoxDecoration(color: Color(0xFF4285F4), shape: BoxShape.circle))]))); } }