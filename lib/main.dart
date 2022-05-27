import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:image/image.dart' as imglib;
import 'package:collection/collection.dart';
import 'package:restart_app/restart_app.dart';

Future<void> main() async {
  // Ensure that plugin services are initialized so that `availableCameras()`
  // can be called before `runApp()`
  WidgetsFlutterBinding.ensureInitialized();

  // Obtain a list of the available cameras on the device.
  final cameras = await availableCameras();
  // Get a specific camera from the list of available cameras.
  final firstCamera = _getFrontCamera(cameras);

  runApp(
    MaterialApp(
      theme: ThemeData.dark(),
      home: TakePictureScreen(
        // Pass the appropriate camera to the TakePictureScreen widget.
        camera: firstCamera,
      ),
    ),
  );
}

CameraDescription _getFrontCamera(List<CameraDescription> cameras) {
  return cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.front);
}

// A screen that allows users to take a picture using a given camera.
class TakePictureScreen extends StatefulWidget {
  const TakePictureScreen({
    super.key,
    required this.camera,
  });

  final CameraDescription camera;

  @override
  TakePictureScreenState createState() => TakePictureScreenState();
}

class TakePictureScreenState extends State<TakePictureScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  var _imageIsProcessing = false;
  final List<int> _durations = [];
  var _titleText = 'connecting to server';
  DateTime _lastUpdate = DateTime.now();

  // use jpg to save network, and bmp to increase fps
  final _imgEncoder = imglib.JpegEncoder(quality: 90);
  // final _imgEncoder = imglib.BmpEncoder();

  final _wsChannel = WebSocketChannel.connect(
    // Uri.parse('wss://echo.websocket.events'),
    Uri.parse('ws://kl-bio-lukas-gpu.keyless.technology:8880/predict_liveness'),
    // Uri.parse('ws://kl-bio-lukas-gpu.keyless.technology:8880/echo_bytes'),
    // Uri.parse('ws://kl-bio-lukas-cpu.keyless.technology:8880/send_image_jpg'),
    // Uri.parse('ws://kl-bio-lukas-cpu.keyless.technology:8880/echo_bytes'),
  );

  @override
  void initState() {
    super.initState();
    // To display the current output from the Camera,
    // create a CameraController.
    _controller = CameraController(
      // Get a specific camera from the list of available cameras.
      widget.camera,
      // Define the resolution to use.
      ResolutionPreset.medium,
    );

    // set listener to the websocket stream
    _wsChannel.stream.listen( (event) {
      print('WS event: $event');
      // var wsText = const Utf8Decoder().convert(event);
      var wsText = event;
      var fps = _durations.isNotEmpty ? 1000 / (_durations.sum / _durations.length) : 0;
      _titleText = 'fps:${fps.toStringAsFixed(0)} $wsText';
      setState(() {});
    });

    // Next, initialize the controller. This returns a Future.
    _initializeControllerFuture = _controller.initialize();
    _initializeControllerFuture.then( (value) {
      _controller.startImageStream((image) async {
        if (_imageIsProcessing) {
          return;
        }
        _imageIsProcessing = true;

        if ((DateTime.now().millisecondsSinceEpoch - _lastUpdate.millisecondsSinceEpoch) > 10) {
          var start = DateTime.now().millisecondsSinceEpoch;

          var convertedImage = _convertYUV420toJpg(image);
          var conversionEnd = DateTime.now().millisecondsSinceEpoch;
          print('yuv conversion took ${conversionEnd - start} ms');

          var encodedBytes = _imgEncoder.encodeImage(convertedImage);
          var encodedEnd = DateTime.now().millisecondsSinceEpoch;
          print('compress took ${encodedEnd - conversionEnd} ms');


          _wsChannel.sink.add(encodedBytes);

          _lastUpdate = DateTime.now();
          print('websocket took ${_lastUpdate.millisecondsSinceEpoch - encodedEnd} ms');

          var duration = _lastUpdate.millisecondsSinceEpoch - start;
          print('Processing total: $duration ms');
          _durations.add(duration);
          if (_durations.length > 20) {
            _durations.removeAt(0);
          }
        }
        _imageIsProcessing = false;

      });
    });
  }

  imglib.Image _convertYUV420toJpg(CameraImage image) {
    const shift = (0xFF << 24);
    try {
      final int width = image.width;
      final int height = image.height;
      final int uvRowStride = image.planes[1].bytesPerRow;
      final int uvPixelStride = image.planes[1].bytesPerPixel!;

      // imgLib -> Image package from https://pub.dartlang.org/packages/image
      var img = imglib.Image(height, width); // Create Image buffer

      // Fill image buffer with plane[0] from YUV420_888
      for(int x=0; x < width; x++) {
        for(int y=0; y < height; y++) {
          final int uvIndex = uvPixelStride * (x/2).floor() + uvRowStride*(y/2).floor();
          final int index = y * width + x;

          final yp = image.planes[0].bytes[index];
          final up = image.planes[1].bytes[uvIndex];
          final vp = image.planes[2].bytes[uvIndex];
          // Calculate pixel color
          int r = (yp + vp * 1436 / 1024 - 179).round().clamp(0, 255);
          int g = (yp - up * 46549 / 131072 + 44 -vp * 93604 / 131072 + 91).round().clamp(0, 255);
          int b = (yp + up * 1814 / 1024 - 227).round().clamp(0, 255);
          // color: 0x FF  FF  FF  FF
          //           A   B   G   R
          if (img.boundsSafe(height-y, x)){
            img.setPixelRgba(height-y, x, r, g ,b ,shift);
          }
        }
      }
      return img;
    } catch (e) {
      print(">>>>>>>>>>>> ERROR ${e.toString()}");
    }
    return imglib.Image(0, 0);
  }

  @override
  void dispose() {
    // Dispose of the controller when the widget is disposed.
    _wsChannel.sink.close();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titleText)),
      // You must wait until the controller is initialized before displaying the
      // camera preview. Use a FutureBuilder to display a loading spinner until the
      // controller has finished initializing.
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            // If the Future is complete, display the preview.
            return CameraPreview(_controller);
          } else {
            // Otherwise, display a loading indicator.
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: Icon(Icons.navigation),
        label: Text('Restart'),
        onPressed: () {
          print('Restart button pressed');
          Restart.restartApp();
        },
      )
    );
  }
}
