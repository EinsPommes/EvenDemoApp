import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/controllers/evenai_model_controller.dart';
import 'package:demo_ai_even/services/api_services_deepseek.dart';
import 'package:demo_ai_even/services/proto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:fluttertoast/fluttertoast.dart';

// states for evenai operations
enum EvenAIState {
  idle,
  starting,
  recording,
  processing,
  sending,
  error
}

class EvenAIError {
  final String message;
  final dynamic originalError;
  final DateTime timestamp;
  
  EvenAIError(this.message, [this.originalError]) : timestamp = DateTime.now();
  
  @override
  String toString() => 'EvenAIError: $message at $timestamp';
}

class EvenAI {
  static EvenAI? _instance;
  static EvenAI get get => _instance ??= EvenAI._();

  static bool _isRunning = false;
  static bool get isRunning => _isRunning;

  bool isReceivingAudio = false;
  List<int> audioDataBuffer = [];
  Uint8List? audioData;

  File? lc3File;
  File? pcmFile;
  int durationS = 0;

  static int maxRetry = 10;
  static int _currentLine = 0;
  static Timer? _timer; // Text sending timer
  static List<String> list = [];
  static List<String> sendReplys = [];

  Timer? _recordingTimer;
  final int maxRecordingDuration = 30;

  static bool _isManual = false;
  
  // track state and errors
  EvenAIState _currentState = EvenAIState.idle;
  int _errorCount = 0;
  static const int maxErrorCount = 3;
  DateTime? _lastErrorTime;
  
  EvenAIState get currentState => _currentState;
  
  // callback for errors
  Function(EvenAIError)? onError;
  
  // battery optimization settings
  static bool _batteryOptimizationEnabled = true;
  static int _displayTimeoutSeconds = 30; // auto-clear display after 30s
  Timer? _displayTimeoutTimer; 

  static set isRunning(bool value) {
    _isRunning = value;
    isEvenAIOpen.value = value;

    isEvenAISyncing.value = value;
  }

  static RxBool isEvenAIOpen = false.obs;

  static RxBool isEvenAISyncing = false.obs;

  int _lastStartTime = 0; // Avoid repeated startup commands of Android Bluetooth in a short period of time
  int _lastStopTime = 0; // Avoid repeated termination commands of Android Bluetooth within a short period of time
  final int startTimeGap = 500; // Filter repeated Bluetooth intervals
  final int stopTimeGap = 500;

  static const _eventSpeechRecognize = "eventSpeechRecognize"; 
  final _eventSpeechRecognizeChannel =
      const EventChannel(_eventSpeechRecognize).receiveBroadcastStream(_eventSpeechRecognize);

  String combinedText = '';

  static final StreamController<String> _textStreamController = StreamController<String>.broadcast();
  static Stream<String> get textStream => _textStreamController.stream;

  static void updateDynamicText(String newText) {
    _textStreamController.add(newText);
  }

  EvenAI._(); 

  void startListening() {
    try {
      combinedText = '';
      _eventSpeechRecognizeChannel.listen((event) {
        try {
          if (event != null && event is Map && event.containsKey("script")) {
            var txt = event["script"] as String;
            combinedText = txt;
            print('${DateTime.now()} Speech recognized: $txt');
          } else {
            print('${DateTime.now()} Invalid speech recognition event: $event');
          }
        } catch (e) {
          _handleError(EvenAIError('Error processing speech event: $e', e));
        }
      }, onError: (error) {
        _handleError(EvenAIError('Speech recognition stream error: $error', error));
      });
    } catch (e) {
      _handleError(EvenAIError('Error starting speech listening: $e', e));
    }
  }

  // receiving starting Even AI request from ble
  void toStartEvenAIByOS() async {
    try {
      _updateState(EvenAIState.starting);
      
      // don't start if already running
      if (isRunning) {
        print('${DateTime.now()} EvenAI already running, ignoring start request');
        return;
      }

      // restart to avoid ble data conflict
      BleManager.get().startSendBeatHeart();

      startListening(); 
      
      // avoid duplicate ble command in short time, especially android
      int currentTime = DateTime.now().millisecondsSinceEpoch;
      if (currentTime - _lastStartTime < startTimeGap) {
        print('${DateTime.now()} EvenAI start request too soon, ignoring');
        return;
      }

      _lastStartTime = currentTime;

      clear();
      isReceivingAudio = true;

      isRunning = true;
      _currentLine = 0;

      await BleManager.invokeMethod("startEvenAI");
      
      await openEvenAIMic();

      startRecordingTimer();
      _updateState(EvenAIState.recording);
      
      _showToast('EvenAI started - speak now');
      
    } catch (e, stackTrace) {
      _handleError(EvenAIError('Error starting EvenAI: $e', e));
      _updateState(EvenAIState.error);
      clear();
      print('${DateTime.now()} Error in toStartEvenAIByOS: $e\n$stackTrace');
    }
  }

  // Monitor the recording time to prevent the recording from ending when the OS exits unexpectedly
  void startRecordingTimer() {
    _recordingTimer = Timer(Duration(seconds: maxRecordingDuration), () {
      if (isReceivingAudio) {
        print("${DateTime.now()} Even AI startRecordingTimer-----exit-----");
        clear();
        //Proto.exit();
      } else {
        _recordingTimer?.cancel();
        _recordingTimer = null;
      }
    });
  }

  // 收到眼镜端Even AI录音结束指令
  Future<void> recordOverByOS() async {
    try {
      print('${DateTime.now()} EvenAI -------recordOverByOS-------');
      _updateState(EvenAIState.processing);

      int currentTime = DateTime.now().millisecondsSinceEpoch;
      if (currentTime - _lastStopTime < stopTimeGap) {
        print('${DateTime.now()} EvenAI stop request too soon, ignoring');
        return;
      }
      _lastStopTime = currentTime;

      isReceivingAudio = false;
      _recordingTimer?.cancel();
      _recordingTimer = null;

      await BleManager.invokeMethod("stopEvenAI");
      await Future.delayed(Duration(seconds: 2));

      print("recordOverByOS----startSendReply---pre------combinedText-------*$combinedText*---");

      if (combinedText.isEmpty) {
        print('${DateTime.now()} No speech recognized');
        updateDynamicText("No Speech Recognized");
        isEvenAISyncing.value = false;
        await startSendReply("No Speech Recognized");
        _updateState(EvenAIState.idle);
        return;
      }

      _showToast('Processing your request...');
      
      try {
        final apiService = ApiDeepSeekService();
        String answer = await apiService.sendChatRequest(combinedText);
      
        print("recordOverByOS----startSendReply---combinedText-------*$combinedText*-----answer----$answer----");

        updateDynamicText("$combinedText\n\n$answer");
        isEvenAISyncing.value = false;
        saveQuestionItem(combinedText, answer);
        
        _updateState(EvenAIState.sending);
        await startSendReply(answer);
        _updateState(EvenAIState.idle);
        
        // start display timeout to save battery
        _startDisplayTimeout();
        
      } catch (e) {
        _handleError(EvenAIError('Error getting AI response: $e', e));
        updateDynamicText("$combinedText\n\nError: Unable to get AI response");
        isEvenAISyncing.value = false;
        await startSendReply("Sorry, I couldn't process your request. Please try again.");
        _updateState(EvenAIState.error);
      }
      
    } catch (e, stackTrace) {
      _handleError(EvenAIError('Error in recordOverByOS: $e', e));
      _updateState(EvenAIState.error);
      clear();
      print('${DateTime.now()} Error in recordOverByOS: $e\n$stackTrace');
    }
  }

  void saveQuestionItem(String title, String content) {
    print("saveQuestionItem----title----$title----content---$content-");
    final controller = Get.find<EvenaiModelController>();
    controller.addItem(title, content);
  }

  int getTotalPages() {
    if (list.isEmpty) {
      return 0;
    }
    if (list.length < 6) {
      return 1;
    }
    int pages = 0;
    int div = list.length ~/ 5;
    int rest = list.length % 5;
    pages = div;
    if (rest != 0) {
      pages++;
    }
    return pages;
  }

  int getCurrentPage() {
    if (_currentLine == 0) {
      return 1;
    }
    int currentPage = 1;
    int div = _currentLine ~/ 5;
    int rest = _currentLine % 5;
    currentPage = 1 + div;
    if (rest != 0) {
      currentPage++;
    }
    return currentPage;
  }

  Future sendNetworkErrorReply(String text) async {
    _currentLine = 0;
    list = EvenAIDataMethod.measureStringList(text);

    String ryplyWords =
        list.sublist(0, min(3, list.length)).map((str) => '$str\n').join();
    String headString = '\n\n';
    ryplyWords = headString + ryplyWords;

    // After sending the network error prompt glasses, exit automatically
    await sendEvenAIReply(ryplyWords, 0x01, 0x60, 0);
    clear();
  }

  Future startSendReply(String text) async {
    _currentLine = 0;
    list = EvenAIDataMethod.measureStringList(text);
   
    if (list.length < 4) {
      String startScreenWords =
          list.sublist(0, min(3, list.length)).map((str) => '$str\n').join();
      String headString = '\n\n';
      startScreenWords = headString + startScreenWords;

      // The glasses need to have 0x30 before they can process 0x40
      bool isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x30, 0);
      
      // Send 0x40 after 3 seconds
      await Future.delayed(Duration(seconds: 3));
      // If already switched to manual mode, no need to send 0x40.
      if (_isManual) {
        return;
      }
      isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x40, 0);
      return;
    }
    if (list.length == 4) {
      String startScreenWords =
          list.sublist(0, 4).map((str) => '$str\n').join();
      String headString = '\n';
      startScreenWords = headString + startScreenWords;

      // // The glasses need to have 0x30 before they can process 0x40
      bool isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x30, 0);
      await Future.delayed(Duration(seconds: 3));
      if (_isManual) {
        return;
      }
      isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x40, 0);
      return;
    }

    if (list.length == 5) {
      String startScreenWords =
          list.sublist(0, 5).map((str) => '$str\n').join();
      // // The glasses need to have 0x30 before they can process 0x40
      bool isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x30, 0);
      await Future.delayed(Duration(seconds: 3));
      if (_isManual) {
        return;
      }
      isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x40, 0);
      return;
    }

    String startScreenWords = list.sublist(0, 5).map((str) => '$str\n').join();
    bool isSuccess = await sendEvenAIReply(startScreenWords, 0x01, 0x30, 0);

    if (isSuccess) {
      _currentLine = 0;
      await updateReplyToOSByTimer();
    } else {
      clear(); 
    }
  }

  Future updateReplyToOSByTimer() async {

    int interval = 5; // The paging interval can be customized
   
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: interval), (timer) async {
      // Switched to manual mode, abolished timer update
      if (_isManual) {
        _timer?.cancel();
        _timer = null;
        return;
      }

      _currentLine = min(_currentLine + 5, list.length - 1);
      sendReplys = list.sublist(_currentLine);

      if (_currentLine > list.length - 1) {
        _timer?.cancel();
        _timer = null;
      } else {
        if (sendReplys.length < 4) {
          var mergedStr = sendReplys
              .sublist(0, sendReplys.length)
              .map((str) => '$str\n')
              .join();

          if (_currentLine >= list.length - 5) {
            await sendEvenAIReply(mergedStr, 0x01, 0x40, 0);
            _timer?.cancel();
            _timer = null;
          } else {
            await sendEvenAIReply(mergedStr, 0x01, 0x30, 0);
          }
        } else {
          var mergedStr = sendReplys
              .sublist(0, min(5, sendReplys.length))
              .map((str) => '$str\n')
              .join();

          if (_currentLine >= list.length - 5) {
            await sendEvenAIReply(mergedStr, 0x01, 0x40, 0);
            _timer?.cancel();
            _timer = null;
          } else {
            await sendEvenAIReply(mergedStr, 0x01, 0x30, 0);
          }
        }
      }
    });
  }

  // Click the TouchBar on the right to turn the page down
  void nextPageByTouchpad() {
    if (!isRunning) return;
    _isManual = true;
    _timer?.cancel();
    _timer = null;

    if (getTotalPages() < 2) {
      manualForJustOnePage();
      return;
    }

    if (_currentLine + 5 > list.length - 1) {
      return;
    } else {
      _currentLine += 5;
    }
    updateReplyToOSByManual();
  }

  // Click the TouchBar on the right to turn the page down
  void lastPageByTouchpad() {
    if (!isRunning) return;
    _isManual = true;
    _timer?.cancel();
    _timer = null;

    if (getTotalPages() < 2) {
      manualForJustOnePage();
      return;
    }

    if (_currentLine - 5 < 0) {
      _currentLine == 0;
    } else {
      _currentLine -= 5;
    }
    updateReplyToOSByManual();
  }

  Future updateReplyToOSByManual() async {
    if (_currentLine < 0 || _currentLine > list.length - 1) {
      return;
    }

    sendReplys = list.sublist(_currentLine);
    if (sendReplys.length < 4) {
      var mergedStr = sendReplys
          .sublist(0, sendReplys.length)
          .map((str) => '$str\n')
          .join();
      await sendEvenAIReply(mergedStr, 0x01, 0x50, 0);
    } else {
      var mergedStr = sendReplys
          .sublist(0, min(5, sendReplys.length))
          .map((str) => '$str\n')
          .join();
      await sendEvenAIReply(mergedStr, 0x01, 0x50, 0);
    }
  }

  // When there is only one page of text, click the page turn TouchBar
  Future manualForJustOnePage() async {
    if (list.length < 4) {
      String screenWords =
          list.sublist(0, min(3, list.length)).map((str) => '$str\n').join();
      String headString = '\n\n';
      screenWords = headString + screenWords;

      await sendEvenAIReply(screenWords, 0x01, 0x50, 0);
      return;
    }

    if (list.length == 4) {
      String screenWords = list.sublist(0, 4).map((str) => '$str\n').join();
      String headString = '\n';
      screenWords = headString + screenWords;

      await sendEvenAIReply(screenWords, 0x01, 0x50, 0);
      return;
    }

    if (list.length == 5) {
      String screenWords = list.sublist(0, 5).map((str) => '$str\n').join();

      await sendEvenAIReply(screenWords, 0x01, 0x50, 0);
      return;
    }
  }

  Future stopEvenAIByOS() async {
    isRunning = false;
    clear();

    await BleManager.invokeMethod("stopEvenAI");
  }

  void clear() {
    try {
      print('${DateTime.now()} EvenAI clearing state');
      
      isReceivingAudio = false;
      isRunning = false;
      _isManual = false;
      _currentLine = 0;
      
      // stop timers
      _recordingTimer?.cancel();
      _recordingTimer = null;
      _timer?.cancel();
      _timer = null;
      _displayTimeoutTimer?.cancel();
      _displayTimeoutTimer = null;
      
      // clear audio data
      audioDataBuffer.clear();
      audioDataBuffer = [];
      audioData = null;
      
      // clear text data
      list = [];
      sendReplys = [];
      combinedText = '';
      
      durationS = 0;
      retryCount = 0;
      
      // reset state
      _updateState(EvenAIState.idle);
      _resetErrorTracking();
      
      // update UI
      isEvenAISyncing.value = false;
      updateDynamicText("Press and hold left TouchBar to engage Even AI.");
      
    } catch (e) {
      print('${DateTime.now()} Error in clear(): $e');
    }
  }

  Future openEvenAIMic() async {
    int retryCount = 0;
    const maxRetries = 3;
    
    while (retryCount < maxRetries) {
      try {
        final (micStartMs, isStartSucc) = await Proto.micOn(lr: "R"); 
        print('${DateTime.now()} openEvenAIMic attempt ${retryCount + 1} - success: $isStartSucc, time: $micStartMs');
        
        if (isStartSucc) {
          print('${DateTime.now()} Microphone opened successfully');
          return;
        }
        
        if (!isReceivingAudio || !isRunning) {
          print('${DateTime.now()} EvenAI stopped, aborting mic opening');
          return;
        }
        
        retryCount++;
        if (retryCount < maxRetries) {
          print('${DateTime.now()} Microphone opening failed, retrying in 1 second...');
          await Future.delayed(Duration(seconds: 1));
        }
        
      } catch (e) {
        retryCount++;
        _handleError(EvenAIError('Error opening microphone (attempt $retryCount): $e', e));
        
        if (retryCount < maxRetries) {
          await Future.delayed(Duration(seconds: 1));
        }
      }
    }
    
    // mic opening failed completely
    _handleError(EvenAIError('Failed to open microphone after $maxRetries attempts'));
    clear();
  }

  // Send text data to the glasses，including status information
  int retryCount = 0;
  Future<bool> sendEvenAIReply(
      String text, int type, int status, int pos) async {
    // todo
    print('${DateTime.now()} sendEvenAIReply---text----$text-----type---$type---status---$status----pos---$pos-');
    if (!isRunning) {
      return false;
    }

    bool isSuccess = await Proto.sendEvenAIData(text,
        newScreen: EvenAIDataMethod.transferToNewScreen(type, status),
        pos: pos,
        current_page_num: getCurrentPage(),
        max_page_num: getTotalPages()); // todo pos
    if (!isSuccess) {
      if (retryCount < maxRetry) {
        retryCount++;
        await sendEvenAIReply(text, type, status, pos);
      } else {
        retryCount = 0;
        // todo
        return false;
      }
    }
    retryCount = 0;
    return true;
  }

  static void dispose() {
    _textStreamController.close();
  }

  // helper methods for state and error handling
  void _updateState(EvenAIState newState) {
    if (_currentState != newState) {
      print('${DateTime.now()} EvenAI State changed: $_currentState -> $newState');
      _currentState = newState;
    }
  }

  void _handleError(EvenAIError error) {
    print('${DateTime.now()} EvenAI Error: $error');
    
    _errorCount++;
    _lastErrorTime = DateTime.now();
    
    // call error callback if set
    onError?.call(error);
    
    // show user friendly error message
    _showToast('Error: ${error.message}');
    
    // stop if too many errors
    if (_errorCount >= maxErrorCount) {
      print('${DateTime.now()} Too many EvenAI errors, stopping');
      clear();
      _showToast('EvenAI stopped due to multiple errors');
    }
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

  void _resetErrorTracking() {
    _errorCount = 0;
    _lastErrorTime = null;
  }

  // battery optimization methods
  void _startDisplayTimeout() {
    if (!_batteryOptimizationEnabled) return;
    
    _displayTimeoutTimer?.cancel();
    _displayTimeoutTimer = Timer(Duration(seconds: _displayTimeoutSeconds), () {
      print('${DateTime.now()} Display timeout - clearing glasses display to save battery');
      _clearGlassesDisplay();
    });
  }

  void _clearGlassesDisplay() async {
    try {
      // send empty text to clear display
      await Proto.sendEvenAIData("",
          newScreen: 0x01,
          pos: 0,
          current_page_num: 1,
          max_page_num: 1);
      print('${DateTime.now()} Glasses display cleared for battery saving');
    } catch (e) {
      print('${DateTime.now()} Error clearing display: $e');
    }
  }

  static void setBatteryOptimization(bool enabled, {int? timeoutSeconds}) {
    _batteryOptimizationEnabled = enabled;
    if (timeoutSeconds != null) {
      _displayTimeoutSeconds = timeoutSeconds;
    }
    print('${DateTime.now()} Battery optimization: $enabled, timeout: ${_displayTimeoutSeconds}s');
  }

  static bool get isBatteryOptimizationEnabled => _batteryOptimizationEnabled;
}

extension EvenAIDataMethod on EvenAI {
  static int transferToNewScreen(int type, int status) {
    int newScreen = status | type;
    return newScreen;
  }

  static List<String> measureStringList(String text, [double? maxW]) {
    final double maxWidth = maxW ?? 488; 
    const double fontSize = 21; // could be customized

    List<String> paragraphs = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    List<String> ret = [];

    TextStyle ts = TextStyle(fontSize: fontSize);

    for (String paragraph in paragraphs) {
      final textSpan = TextSpan(text: paragraph, style: ts);
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
        maxLines: null,
      );

      textPainter.layout(maxWidth: maxWidth);

      final lineCount = textPainter.computeLineMetrics().length;

      var start = 0;
      for (var i = 0; i < lineCount; i++) {
        final line = textPainter.getLineBoundary(TextPosition(offset: start));
        ret.add(paragraph.substring(line.start, line.end).trim());
        start = line.end;
      }
    }
    return ret;
  }
}
