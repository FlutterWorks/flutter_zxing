import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:flutter_beep/flutter_beep.dart';

import '../../generated_bindings.dart';
import '../logic/zxing.dart';
import '../utils/extentions.dart';
import '../utils/isolate_utils.dart';
import 'scanner_overlay.dart';

class ReaderWidget extends StatefulWidget {
  const ReaderWidget({
    super.key,
    required this.onScan,
    this.onControllerCreated,
    this.codeFormat = Format.Any,
    this.showCroppingRect = true,
    this.scannerOverlay,
    this.showFlashlight = true,
    this.allowPinchZoom = true,
    this.scanDelay = const Duration(milliseconds: 1000), // 1000ms delay
    this.cropPercent = 0.5, // 50% of the screen
    this.resolution = ResolutionPreset.high,
  });

  final Function(CodeResult) onScan;
  final Function(CameraController?)? onControllerCreated;
  final int codeFormat;
  final bool showCroppingRect;
  final ScannerOverlay? scannerOverlay;
  final bool showFlashlight;
  final bool allowPinchZoom;
  final Duration scanDelay;
  final double cropPercent;
  final ResolutionPreset resolution;

  @override
  State<ReaderWidget> createState() => _ReaderWidgetState();
}

class _ReaderWidgetState extends State<ReaderWidget>
    with TickerProviderStateMixin {
  List<CameraDescription>? cameras;
  CameraController? controller;
  bool _cameraOn = false;

  double _zoom = 1.0;
  double _scaleFactor = 1.0;
  double _maxZoomLevel = 1.0;
  double _minZoomLevel = 1.0;

  bool isAndroid() => Theme.of(context).platform == TargetPlatform.android;

  // true when code detecting is ongoing
  bool _isProcessing = false;

  /// Instance of [IsolateUtils]
  IsolateUtils? isolateUtils;

  @override
  void initState() {
    super.initState();

    initStateAsync();
  }

  Future<void> initStateAsync() async {
    // Spawn a new isolate
    await startCameraProcessing();

    availableCameras().then((List<CameraDescription> cameras) {
      setState(() {
        this.cameras = cameras;
        if (cameras.isNotEmpty) {
          onNewCameraSelected(cameras.first);
        }
      });
    });

    SystemChannels.lifecycle.setMessageHandler((String? message) async {
      debugPrint(message);
      final CameraController? cameraController = controller;
      if (cameraController == null || !cameraController.value.isInitialized) {
        return;
      }
      if (mounted) {
        if (message == AppLifecycleState.paused.toString()) {
          await cameraController.stopImageStream();
          await cameraController.dispose();
          _cameraOn = false;
          setState(() {});
        }
        if (message == AppLifecycleState.resumed.toString()) {
          _cameraOn = true;
          onNewCameraSelected(cameraController.description);
        }
      }
      return null;
    });
  }

  @override
  void dispose() {
    stopCameraProcessing();
    controller?.dispose();
    super.dispose();
  }

  Future<void> onNewCameraSelected(CameraDescription cameraDescription) async {
    if (controller != null) {
      await controller!.dispose();
    }

    controller = CameraController(
      cameraDescription,
      widget.resolution,
      enableAudio: false,
      imageFormatGroup:
          isAndroid() ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
    );
    final CameraController? cameraController = controller;
    if (cameraController == null) {
      return;
    }
    try {
      await cameraController.initialize();
      await cameraController.setFlashMode(FlashMode.off);
      _maxZoomLevel = await cameraController.getMaxZoomLevel();
      _minZoomLevel = await cameraController.getMinZoomLevel();
      cameraController.startImageStream(processImageStream);
    } on CameraException catch (e) {
      debugPrint('${e.code}: ${e.description}');
    }

    cameraController.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });

    if (mounted) {
      _cameraOn = true;
      setState(() {});
    }

    widget.onControllerCreated?.call(cameraController);
  }

  Future<void> processImageStream(CameraImage image) async {
    if (!_isProcessing) {
      _isProcessing = true;
      try {
        final CodeResult result = await processCameraImage(
          image,
          format: widget.codeFormat,
          cropPercent: widget.showCroppingRect ? widget.cropPercent : 0,
        );
        if (result.isValidBool) {
          widget.onScan(result);
          setState(() {});
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      } on FileSystemException catch (e) {
        debugPrint(e.message);
      } catch (e) {
        debugPrint(e.toString());
      }
      await Future<void>.delayed(widget.scanDelay);
      _isProcessing = false;
    }

    return;
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    final double cropSize = min(size.width, size.height) * widget.cropPercent;
    return Stack(
      children: <Widget>[
        // Camera preview
        Center(
          child: _cameraPreviewWidget(cropSize),
        ),
      ],
    );
  }

  // Display the preview from the camera.
  Widget _cameraPreviewWidget(double cropSize) {
    final CameraController? cameraController = controller;
    final bool isCameraReady = cameras != null &&
        (cameras?.isNotEmpty ?? false) &&
        _cameraOn &&
        !(cameraController == null || !cameraController.value.isInitialized);
    final Size size = MediaQuery.of(context).size;
    final double cameraMaxSize = max(size.width, size.height);
    return Stack(
      children: <Widget>[
        if (!isCameraReady) Container(color: Colors.black),
        if (isCameraReady)
          SizedBox(
            width: cameraMaxSize,
            height: cameraMaxSize,
            child: ClipRRect(
              child: OverflowBox(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: cameraMaxSize,
                    child: CameraPreview(
                      cameraController,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (widget.showCroppingRect)
          Container(
            decoration: ShapeDecoration(
              shape: widget.scannerOverlay ??
                  ScannerOverlay(
                    borderColor: Theme.of(context).primaryColor,
                    overlayColor: Colors.black45,
                    borderRadius: 1,
                    borderLength: 16,
                    borderWidth: 8,
                    cutOutSize: cropSize,
                  ),
            ),
          ),
        if (widget.allowPinchZoom)
          GestureDetector(
            onScaleStart: (ScaleStartDetails details) {
              _zoom = _scaleFactor;
            },
            onScaleUpdate: (ScaleUpdateDetails details) {
              _scaleFactor =
                  (_zoom * details.scale).clamp(_minZoomLevel, _maxZoomLevel);
              cameraController?.setZoomLevel(_scaleFactor);
            },
          ),
        if (widget.showFlashlight)
          Positioned(
            bottom: 20,
            left: 20,
            child: FloatingActionButton(
              onPressed: () {
                if (cameraController != null) {
                  FlashMode mode = cameraController.value.flashMode;
                  if (mode == FlashMode.torch) {
                    mode = FlashMode.off;
                  } else {
                    mode = FlashMode.torch;
                  }
                  cameraController.setFlashMode(mode);
                  setState(() {});
                }
              },
              backgroundColor: Colors.black26,
              child: Icon(_flashIcon(cameraController)),
            ),
          )
      ],
    );
  }

  IconData _flashIcon(CameraController? cameraController) {
    final FlashMode mode = cameraController?.value.flashMode ?? FlashMode.torch;
    switch (mode) {
      case FlashMode.torch:
        return Icons.flash_on;
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.auto:
        return Icons.flash_auto;
    }
  }
}
