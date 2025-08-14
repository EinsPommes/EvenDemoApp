import 'dart:async';
import 'package:demo_ai_even/app.dart';
import 'package:demo_ai_even/services/ble.dart';
import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';

typedef SendResultParse = bool Function(Uint8List value);

// connection states for better tracking
enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  reconnecting,
  error
}

// different error types we might encounter
enum BleErrorType {
  timeout,
  connectionLost,
  deviceNotFound,
  permissionDenied,
  bluetoothOff,
  unknown
}

class BleError {
  final BleErrorType type;
  final String message;
  final dynamic originalError;
  
  BleError(this.type, this.message, [this.originalError]);
  
  @override
  String toString() => 'BleError($type): $message';
}

class BleManager {
  Function()? onStatusChanged;
  Function(BleError)? onError;
  BleManager._() {}

  static BleManager? _instance;
  static BleManager get() {
    if (_instance == null) {
      _instance ??= BleManager._();
      _instance!._init();
    }
    return _instance!;
  }

  static const methodSend = "send";
  static const _eventBleReceive = "eventBleReceive";
  static const _channel = MethodChannel('method.bluetooth');
  
  final eventBleReceive = const EventChannel(_eventBleReceive)
      .receiveBroadcastStream(_eventBleReceive)
      .map((ret) => BleReceive.fromMap(ret));

  Timer? beatHeartTimer;
  Timer? reconnectionTimer;
  
  final List<Map<String, String>> pairedGlasses = [];
  bool isConnected = false;
  String connectionStatus = 'Not connected';
  BleConnectionState _connectionState = BleConnectionState.disconnected;
  
  // reconnection stuff
  int _reconnectionAttempts = 0;
  static const int maxReconnectionAttempts = 5;
  static const int reconnectionDelaySeconds = 3;
  
  // track connection issues
  DateTime? _lastSuccessfulConnection;
  int _consecutiveFailures = 0;
  
  BleConnectionState get connectionState => _connectionState;

  void _init() {}

  void startListening() {
    eventBleReceive.listen(
      (res) {
        try {
          _handleReceivedData(res);
        } catch (e, stackTrace) {
          _handleError(BleError(BleErrorType.unknown, 
            'Error processing received data: $e', e));
          print('Error in startListening: $e\n$stackTrace');
        }
      },
      onError: (error) {
        _handleError(BleError(BleErrorType.unknown, 
          'Stream error: $error', error));
      },
    );
  }

  Future<void> startScan() async {
    try {
      _updateConnectionState(BleConnectionState.scanning);
      await _channel.invokeMethod('startScan');
      print('${DateTime.now()} BLE scan started successfully');
    } catch (e) {
      final error = BleError(BleErrorType.unknown, 'Error starting scan: $e', e);
      _handleError(error);
      _updateConnectionState(BleConnectionState.error);
    }
  }

  Future<void> stopScan() async {
    try {
      await _channel.invokeMethod('stopScan');
      print('${DateTime.now()} BLE scan stopped successfully');
    } catch (e) {
      final error = BleError(BleErrorType.unknown, 'Error stopping scan: $e', e);
      _handleError(error);
    }
  }

  Future<void> connectToGlasses(String deviceName) async {
    try {
      _updateConnectionState(BleConnectionState.connecting);
      await _channel.invokeMethod('connectToGlasses', {'deviceName': deviceName});
      connectionStatus = 'Connecting...';
      _resetConnectionTracking();
      print('${DateTime.now()} Connecting to glasses: $deviceName');
    } catch (e) {
      final error = BleError(BleErrorType.connectionLost, 
        'Error connecting to device $deviceName: $e', e);
      _handleError(error);
      _updateConnectionState(BleConnectionState.error);
    }
  }

  void setMethodCallHandler() {
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  Future<void> _methodCallHandler(MethodCall call) async {
    switch (call.method) {
      case 'glassesConnected':
        _onGlassesConnected(call.arguments);
        break;
      case 'glassesConnecting':
        _onGlassesConnecting();
        break;
      case 'glassesDisconnected':
        _onGlassesDisconnected();
        break;
      case 'foundPairedGlasses':
        _onPairedGlassesFound(Map<String, String>.from(call.arguments));
        break;
      default:
        print('Unknown method: ${call.method}');
    }
  }

  void _onGlassesConnected(dynamic arguments) {
    print("_onGlassesConnected----arguments----$arguments------");
    connectionStatus = 'Connected: \n${arguments['leftDeviceName']} \n${arguments['rightDeviceName']}';
    isConnected = true;
    _updateConnectionState(BleConnectionState.connected);
    
    // reset counters on successful connection
    _consecutiveFailures = 0;
    _reconnectionAttempts = 0;
    _lastSuccessfulConnection = DateTime.now();
    
    // stop trying to reconnect
    reconnectionTimer?.cancel();
    reconnectionTimer = null;

    onStatusChanged?.call();
    startSendBeatHeart();
    
    _showToast('Glasses connected successfully');
  }

  int tryTime = 0;
  void startSendBeatHeart() async {
    beatHeartTimer?.cancel();
    beatHeartTimer = null;

    beatHeartTimer = Timer.periodic(Duration(seconds: 8), (timer) async {
      try {
        if (!isConnected) {
          print('${DateTime.now()} Stopping heartbeat - not connected');
          timer.cancel();
          return;
        }

        bool isSuccess = await Proto.sendHeartBeat();
        if (!isSuccess && tryTime < 2) {
          tryTime++;
          print('${DateTime.now()} Heartbeat failed, retry $tryTime');
          isSuccess = await Proto.sendHeartBeat();
        }
        
        if (!isSuccess) {
          _consecutiveFailures++;
          print('${DateTime.now()} Heartbeat failed after retries. Failures: $_consecutiveFailures');
          
          if (_consecutiveFailures >= 3) {
            print('${DateTime.now()} Multiple heartbeat failures, triggering disconnection');
            _onGlassesDisconnected();
            timer.cancel();
          }
        } else {
          // reset failure count when heartbeat works again
          if (_consecutiveFailures > 0) {
            print('${DateTime.now()} Heartbeat recovered, resetting failure count');
            _consecutiveFailures = 0;
          }
          tryTime = 0;
        }
      } catch (e) {
        print('${DateTime.now()} Error in heartbeat: $e');
        _handleError(BleError(BleErrorType.unknown, 'Heartbeat error: $e', e));
      }
    });
  }

  void _onGlassesConnecting() {
    connectionStatus = 'Connecting...';

      onStatusChanged?.call();
  }

  void _onGlassesDisconnected() {
    connectionStatus = 'Not connected';
    isConnected = false;
    _updateConnectionState(BleConnectionState.disconnected);
    
    // count failures
    _consecutiveFailures++;
    
    // stop heartbeat
    beatHeartTimer?.cancel();
    beatHeartTimer = null;

    onStatusChanged?.call();
    
    // try to reconnect if not too many failures
    if (_consecutiveFailures <= maxReconnectionAttempts) {
      _showToast('Connection lost. Attempting to reconnect...');
      _attemptReconnection();
    } else {
      _showToast('Connection lost. Max reconnection attempts reached.');
      final error = BleError(BleErrorType.connectionLost, 
        'Maximum reconnection attempts reached');
      _handleError(error);
    }
  }

  void _onPairedGlassesFound(Map<String, String> deviceInfo) {
    final String channelNumber = deviceInfo['channelNumber']!;
    final isAlreadyPaired = pairedGlasses.any((glasses) => glasses['channelNumber'] == channelNumber);

    if (!isAlreadyPaired) {
      pairedGlasses.add(deviceInfo);
    }

    onStatusChanged?.call();
  }

  void _handleReceivedData(BleReceive res) {
    try {
      if (res.type == "VoiceChunk") {
        return;
      }

      // check if we got any data
      if (res.data.isEmpty) {
        print('${DateTime.now()} Warning: Received empty data');
        return;
      }

      String cmd = "${res.lr}${res.getCmd().toRadixString(16).padLeft(2, '0')}";
      if (res.getCmd() != 0xf1) {
        print(
          "${DateTime.now()} BleManager receive cmd: $cmd, len: ${res.data.length}, data = ${res.data.hexString}",
        );
      }

      // Handle TouchBar events (0xF5)
      if (res.data[0].toInt() == 0xF5) {
        if (res.data.length < 2) {
          print('${DateTime.now()} Warning: F5 command with insufficient data length');
          return;
        }
        
        final notifyIndex = res.data[1].toInt();
        
        switch (notifyIndex) {
          case 0:
            try {
              App.get.exitAll();
            } catch (e) {
              print('${DateTime.now()} Error in exitAll: $e');
            }
            break;
          case 1: 
            try {
              if (res.lr == 'L') {
                EvenAI.get.lastPageByTouchpad();
              } else {
                EvenAI.get.nextPageByTouchpad();
              }
            } catch (e) {
              print('${DateTime.now()} Error in page navigation: $e');
            }
            break;
          case 23: //BleEvent.evenaiStart:
            try {
              EvenAI.get.toStartEvenAIByOS();
            } catch (e) {
              print('${DateTime.now()} Error starting EvenAI: $e');
            }
            break;
          case 24: //BleEvent.evenaiRecordOver:
            try {
              EvenAI.get.recordOverByOS();
            } catch (e) {
              print('${DateTime.now()} Error in recordOver: $e');
            }
            break;
          default:
            print("${DateTime.now()} Unknown Ble Event: $notifyIndex");
        }
        return;
      }

      // complete the request
      try {
        _reqListen.remove(cmd)?.complete(res);
        _reqTimeout.remove(cmd)?.cancel();
        if (_nextReceive != null) {
          _nextReceive?.complete(res);
          _nextReceive = null;
        }
      } catch (e) {
        print('${DateTime.now()} Error completing request: $e');
      }

    } catch (e, stackTrace) {
      print('${DateTime.now()} Error in _handleReceivedData: $e\n$stackTrace');
      _handleError(BleError(BleErrorType.unknown, 
        'Error handling received data: $e', e));
    }
  }

  String getConnectionStatus() {
    return connectionStatus;
  }

  List<Map<String, String>> getPairedGlasses() {
    return pairedGlasses;
  }


  static final _reqListen = <String, Completer<BleReceive>>{};
  static final _reqTimeout = <String, Timer>{};
  static Completer<BleReceive>? _nextReceive;

  static _checkTimeout(String cmd, int timeoutMs, Uint8List data, String lr) {
    _reqTimeout.remove(cmd);
    var cb = _reqListen.remove(cmd);
    print('${DateTime.now()} _checkTimeout-----timeoutMs----$timeoutMs-----cb----$cb-----');
    if (cb != null) {
      var res = BleReceive();
      res.isTimeout = true;
      //var showData = data.length > 50 ? data.sublist(0, 50) : data;
      print(
          "send Timeout $cmd of $timeoutMs");
      cb.complete(res);
    }

    _reqTimeout[cmd]?.cancel();
    _reqTimeout.remove(cmd);
  }

  static Future<T?> invokeMethod<T>(String method, [dynamic params]) {
    return _channel.invokeMethod(method, params);
  }

  static Future<BleReceive> requestRetry(
    Uint8List data, {
    String? lr,
    Map<String, dynamic>? other,
    int timeoutMs = 200,
    bool useNext = false,
    int retry = 3,
  }) async {
    BleReceive ret;
    
    for (var i = 0; i <= retry; i++) {
      try {
        ret = await request(data,
            lr: lr, other: other, timeoutMs: timeoutMs, useNext: useNext);
        if (!ret.isTimeout) {
          return ret;
        }
        
        // check if still connected before retrying
        if (!BleManager.isBothConnected()) {
          print('${DateTime.now()} Connection lost during requestRetry, aborting');
          break;
        }
        
        // wait a bit before retry
        if (i < retry) {
          await Future.delayed(Duration(milliseconds: 50 * (i + 1)));
          print('${DateTime.now()} Retry attempt ${i + 1} for $lr');
        }
      } catch (e) {
        print('${DateTime.now()} Error in requestRetry attempt $i: $e');
        if (i == retry) {
          // Last attempt failed, create timeout response
          ret = BleReceive();
          ret.isTimeout = true;
          break;
        }
      }
    }
    
    ret = BleReceive();
    ret.isTimeout = true;
    print('${DateTime.now()} requestRetry $lr timeout after $retry attempts (${timeoutMs}ms each)');
    return ret;
  }

  static Future<bool> sendBoth(
    data, {
    int timeoutMs = 250,
    SendResultParse? isSuccess,
    int? retry,
  }) async {
    try {
      // make sure we're connected
      if (!BleManager.isBothConnected()) {
        print('${DateTime.now()} sendBoth failed: Not connected');
        return false;
      }

      // send to left first
      var retL = await BleManager.requestRetry(data,
          lr: "L", timeoutMs: timeoutMs, retry: retry ?? 0);
      
      if (retL.isTimeout) {
        print('${DateTime.now()} sendBoth L timeout');
        return false;
      }

      // check left response
      bool leftSuccess = true;
      if (isSuccess != null) {
        leftSuccess = isSuccess.call(retL.data);
        if (!leftSuccess) {
          print('${DateTime.now()} sendBoth L validation failed');
          return false;
        }
      } else if (retL.data.isNotEmpty && retL.data[1].toInt() != 0xc9) {
        print('${DateTime.now()} sendBoth L response not successful: ${retL.data[1].toInt()}');
        return false;
      }

      // send to right
      var retR = await BleManager.requestRetry(data,
          lr: "R", timeoutMs: timeoutMs, retry: retry ?? 0);
      
      if (retR.isTimeout) {
        print('${DateTime.now()} sendBoth R timeout');
        return false;
      }

      // check right response
      if (isSuccess != null) {
        return isSuccess.call(retR.data);
      } else if (retR.data.isNotEmpty && retR.data[1].toInt() != 0xc9) {
        print('${DateTime.now()} sendBoth R response not successful: ${retR.data[1].toInt()}');
        return false;
      }

      return true;
    } catch (e) {
      print('${DateTime.now()} Error in sendBoth: $e');
      return false;
    }
  }

  static Future sendData(Uint8List data,
      {String? lr, Map<String, dynamic>? other, int secondDelay = 100}) async {

    var params = <String, dynamic>{
      'data': data,
    };
    if (other != null) {
      params.addAll(other);
    }
    dynamic ret;
    if (lr != null) {
      params["lr"] = lr;
      ret = await BleManager.invokeMethod(methodSend, params);
      return ret;
    } else {
      params["lr"] = "L"; // get().slave; 
      var ret = await _channel
          .invokeMethod(methodSend, params); //ret is true or false or null
      if (ret == true) {
        params["lr"] = "R"; // get().master;
        ret = await BleManager.invokeMethod(methodSend, params);
        return ret;
      }
      if (secondDelay > 0) {
        await Future.delayed(Duration(milliseconds: secondDelay));
      }
      params["lr"] = "R"; // get().master;
      ret = await BleManager.invokeMethod(methodSend, params);
      return ret;
    }
  }

  static Future<BleReceive> request(Uint8List data,
      {String? lr,
      Map<String, dynamic>? other,
      int timeoutMs = 1000, //500,
      bool useNext = false}) async {

    var lr0 = lr ?? Proto.lR();
    var completer = Completer<BleReceive>();
    String cmd = "$lr0${data[0].toRadixString(16).padLeft(2, '0')}";

    if (useNext) {
      _nextReceive = completer;
    } else {
      if (_reqListen.containsKey(cmd)) {
        var res = BleReceive();
        res.isTimeout = true;
        _reqListen[cmd]?.complete(res);
        print("already exist key: $cmd");

        _reqTimeout[cmd]?.cancel();
      }
      _reqListen[cmd] = completer;
    }
    print("request key: $cmd, ");

    if (timeoutMs > 0) {
      _reqTimeout[cmd] = Timer(Duration(milliseconds: timeoutMs), () {
        _checkTimeout(cmd, timeoutMs, data, lr0);
      });
    }

    completer.future.then((result) {
      _reqTimeout.remove(cmd)?.cancel();
    });

    await sendData(data, lr: lr, other: other).timeout(
      Duration(seconds: 2),
      onTimeout: () {
        _reqTimeout.remove(cmd)?.cancel();
        var ret = BleReceive();
        ret.isTimeout = true;
        _reqListen.remove(cmd)?.complete(ret);
      },
    );

    return completer.future;
  }

  static bool isBothConnected() {
    //return isConnectedL() && isConnectedR();

    // todo
    return true;
  }

  // helper methods for connection handling
  void _updateConnectionState(BleConnectionState newState) {
    if (_connectionState != newState) {
      print('${DateTime.now()} BLE State changed: $_connectionState -> $newState');
      _connectionState = newState;
    }
  }

  void _handleError(BleError error) {
    print('${DateTime.now()} BLE Error: $error');
    onError?.call(error);
    
    // show user friendly messages
    switch (error.type) {
      case BleErrorType.timeout:
        _showToast('Connection timeout. Please try again.');
        break;
      case BleErrorType.connectionLost:
        _showToast('Connection lost. Reconnecting...');
        break;
      case BleErrorType.deviceNotFound:
        _showToast('Device not found. Please check if glasses are on.');
        break;
      case BleErrorType.bluetoothOff:
        _showToast('Please enable Bluetooth.');
        break;
      default:
        _showToast('Connection error occurred.');
    }
  }

  void _resetConnectionTracking() {
    _consecutiveFailures = 0;
    _reconnectionAttempts = 0;
  }

  void _attemptReconnection() {
    if (_reconnectionAttempts >= maxReconnectionAttempts) {
      print('${DateTime.now()} Max reconnection attempts reached');
      return;
    }

    _reconnectionAttempts++;
    _updateConnectionState(BleConnectionState.reconnecting);
    
    reconnectionTimer?.cancel();
    reconnectionTimer = Timer(
      Duration(seconds: reconnectionDelaySeconds * _reconnectionAttempts),
      () async {
        try {
          print('${DateTime.now()} Reconnection attempt $_reconnectionAttempts');
          
          // try to reconnect to last device
          if (pairedGlasses.isNotEmpty) {
            final lastDevice = pairedGlasses.first;
            final deviceName = "Pair_${lastDevice['channelNumber']}";
            await connectToGlasses(deviceName);
          }
        } catch (e) {
          print('${DateTime.now()} Reconnection attempt failed: $e');
          if (_reconnectionAttempts < maxReconnectionAttempts) {
            _attemptReconnection();
          }
        }
      },
    );
  }

  void _showToast(String message) {
    try {
      Fluttertoast.showToast(
        msg: message,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
    } catch (e) {
      print('${DateTime.now()} Error showing toast: $e');
    }
  }

  static Future<bool> requestList(
    List<Uint8List> sendList, {
    String? lr,
    int? timeoutMs,
  }) async {
    print("requestList---sendList---${sendList.first}----lr---$lr----timeoutMs----$timeoutMs-");

    if (lr != null) {
      return await _requestList(sendList, lr, timeoutMs: timeoutMs);
    } else {
      var rets = await Future.wait([
        _requestList(sendList, "L", keepLast: true, timeoutMs: timeoutMs),
        _requestList(sendList, "R", keepLast: true, timeoutMs: timeoutMs),
      ]);
      if (rets.length == 2 && rets[0] && rets[1]) {
        var lastPack = sendList[sendList.length - 1];
        return await sendBoth(lastPack, timeoutMs: timeoutMs ?? 250);
      } else {
        print("error request lr leg");
      }
    }
    return false;
  }

  static Future<bool> _requestList(List sendList, String lr,
      {bool keepLast = false, int? timeoutMs}) async {
    int len = sendList.length;
    if (keepLast) len = sendList.length - 1;
    for (var i = 0; i < len; i++) {
      var pack = sendList[i];
      var resp = await request(pack, lr: lr, timeoutMs: timeoutMs ?? 350);
      if (resp.isTimeout) {
        return false;
      } else if (resp.data[1].toInt() != 0xc9 && resp.data[1].toInt() != 0xcB) {
        return false;
      }
    }
    return true;
  }

}

extension Uint8ListEx on Uint8List {
  String get hexString {
    return map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}
