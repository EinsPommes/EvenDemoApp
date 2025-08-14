import 'dart:convert';
import 'dart:typed_data';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/evenai_proto.dart';
import 'package:demo_ai_even/utils/utils.dart';

class Proto {
  static String lR() {
    // todo
    if (BleManager.isBothConnected()) return "R";
    //if (BleManager.isConnectedR()) return "R";
    return "L";
  }

  /// Returns the time consumed by the command and whether it is successful
  static Future<(int, bool)> micOn({
    String? lr,
  }) async {
    try {
      var begin = Utils.getTimestampMs();
      var data = Uint8List.fromList([0x0E, 0x01]);
      
      print('${DateTime.now()} Proto.micOn - sending command to $lr');
      var receive = await BleManager.request(data, lr: lr, timeoutMs: 2000);

      var end = Utils.getTimestampMs();
      var startMic = (begin + ((end - begin) ~/ 2));

      if (receive.isTimeout) {
        print('${DateTime.now()} Proto.micOn - timeout');
        return (startMic, false);
      }

      if (receive.data.isEmpty) {
        print('${DateTime.now()} Proto.micOn - empty response');
        return (startMic, false);
      }

      bool success = receive.data[1] == 0xc9;
      print('${DateTime.now()} Proto.micOn - startMic: $startMic, success: $success, response: ${receive.data[1]}');
      
      return (startMic, success);
    } catch (e) {
      print('${DateTime.now()} Proto.micOn - error: $e');
      return (0, false);
    }
  }

  /// Even AI
  static int _evenaiSeq = 0;
  // AI result transmission (also compatible with AI startup and Q&A status synchronization)
  static Future<bool> sendEvenAIData(String text,
      {int? timeoutMs,
      required int newScreen,
      required int pos,
      required int current_page_num,
      required int max_page_num}) async {
    try {
      // check input params
      if (text.isEmpty) {
        print('${DateTime.now()} sendEvenAIData - empty text provided');
        return false;
      }

      if (current_page_num < 0 || max_page_num < 1 || current_page_num > max_page_num) {
        print('${DateTime.now()} sendEvenAIData - invalid page numbers: current=$current_page_num, max=$max_page_num');
        return false;
      }

      var data = utf8.encode(text);
      var syncSeq = _evenaiSeq & 0xff;

      List<Uint8List> dataList = EvenaiProto.evenaiMultiPackListV2(0x4E,
          data: data,
          syncSeq: syncSeq,
          newScreen: newScreen,
          pos: pos,
          current_page_num: current_page_num,
          max_page_num: max_page_num);
      _evenaiSeq++;

      print('${DateTime.now()} proto--sendEvenAIData---text length: ${text.length}---seq: $_evenaiSeq---newScreen: $newScreen---pages: $current_page_num/$max_page_num---packets: ${dataList.length}');

      // make sure we're connected
      if (!BleManager.isBothConnected()) {
        print('${DateTime.now()} sendEvenAIData - not connected');
        return false;
      }

      // send to left first
      bool isSuccessL = await BleManager.requestList(dataList,
          lr: "L", timeoutMs: timeoutMs ?? 2000);

      if (!isSuccessL) {
        print("${DateTime.now()} sendEvenAIData failed L");
        return false;
      }

      // send to right
      bool isSuccessR = await BleManager.requestList(dataList,
          lr: "R", timeoutMs: timeoutMs ?? 2000);

      if (!isSuccessR) {
        print("${DateTime.now()} sendEvenAIData failed R");
        return false;
      }

      print('${DateTime.now()} sendEvenAIData successful for both sides');
      return true;
      
    } catch (e) {
      print('${DateTime.now()} sendEvenAIData error: $e');
      return false;
    }
  }

  static int _beatHeartSeq = 0;
  static Future<bool> sendHeartBeat() async {
    try {
      var length = 6;
      var data = Uint8List.fromList([
        0x25,
        length & 0xff,
        (length >> 8) & 0xff,
        _beatHeartSeq % 0xff,
        0x04,
        _beatHeartSeq % 0xff
      ]);
      _beatHeartSeq++;

      print('${DateTime.now()} sendHeartBeat seq: $_beatHeartSeq');
      
      // make sure we're connected
      if (!BleManager.isBothConnected()) {
        print('${DateTime.now()} sendHeartBeat - not connected');
        return false;
      }

      // send to left
      var retL = await BleManager.request(data, lr: "L", timeoutMs: 1500);

      if (retL.isTimeout) {
        print('${DateTime.now()} sendHeartBeat L timeout');
        return false;
      }

      if (retL.data.isEmpty || retL.data.length < 6) {
        print('${DateTime.now()} sendHeartBeat L invalid response length: ${retL.data.length}');
        return false;
      }

      if (retL.data[0].toInt() != 0x25 || retL.data[4].toInt() != 0x04) {
        print('${DateTime.now()} sendHeartBeat L invalid response: cmd=${retL.data[0]}, status=${retL.data.length > 4 ? retL.data[4] : 'N/A'}');
        return false;
      }

      // send to right
      var retR = await BleManager.request(data, lr: "R", timeoutMs: 1500);
      
      if (retR.isTimeout) {
        print('${DateTime.now()} sendHeartBeat R timeout');
        return false;
      }

      if (retR.data.isEmpty || retR.data.length < 6) {
        print('${DateTime.now()} sendHeartBeat R invalid response length: ${retR.data.length}');
        return false;
      }

      if (retR.data[0].toInt() != 0x25 || retR.data[4].toInt() != 0x04) {
        print('${DateTime.now()} sendHeartBeat R invalid response: cmd=${retR.data[0]}, status=${retR.data.length > 4 ? retR.data[4] : 'N/A'}');
        return false;
      }

      print('${DateTime.now()} sendHeartBeat successful');
      return true;
      
    } catch (e) {
      print('${DateTime.now()} sendHeartBeat error: $e');
      return false;
    }
  }

  static Future<String> getLegSn(String lr) async {
    var cmd = Uint8List.fromList([0x34]);
    var resp = await BleManager.request(cmd, lr: lr);
    var sn = String.fromCharCodes(resp.data.sublist(2, 18).toList());
    return sn;
  }

  // tell the glasses to exit function to dashboard
  static Future<bool> exit() async {
    print("send exit all func");
    var data = Uint8List.fromList([0x18]);

    var retL = await BleManager.request(data, lr: "L", timeoutMs: 1500);
    print('${DateTime.now()} exit----L----ret---${retL.data}--');
    if (retL.isTimeout) {
      return false;
    } else if (retL.data.isNotEmpty && retL.data[1].toInt() == 0xc9) {
      var retR = await BleManager.request(data, lr: "R", timeoutMs: 1500);
      print('${DateTime.now()} exit----R----retR---${retR.data}--');
      if (retR.isTimeout) {
        return false;
      } else if (retR.data.isNotEmpty && retR.data[1].toInt() == 0xc9) {
        return true;
      } else {
        return false;
      }
    } else {
      return false;
    }
  }

  static List<Uint8List> _getPackList(int cmd, Uint8List data,
      {int count = 20}) {
    final realCount = count - 3;
    List<Uint8List> send = [];
    int maxSeq = data.length ~/ realCount;
    if (data.length % realCount > 0) {
      maxSeq++;
    }
    for (var seq = 0; seq < maxSeq; seq++) {
      var start = seq * realCount;
      var end = start + realCount;
      if (end > data.length) {
        end = data.length;
      }
      var itemData = data.sublist(start, end);
      var pack = Utils.addPrefixToUint8List([cmd, maxSeq, seq], itemData);
      send.add(pack);
    }
    return send;
  }

  static Future<void> sendNewAppWhiteListJson(String whitelistJson) async {
    print("proto -> sendNewAppWhiteListJson: whitelist = $whitelistJson");
    final whitelistData = utf8.encode(whitelistJson);
    //  2、转换为接口格式
    final dataList = _getPackList(0x04, whitelistData, count: 180);
    print(
        "proto -> sendNewAppWhiteListJson: length = ${dataList.length}, dataList = $dataList");
    for (var i = 0; i < 3; i++) {
      final isSuccess =
          await BleManager.requestList(dataList, timeoutMs: 300, lr: "L");
      if (isSuccess) {
        return;
      }
    }
  }

  /// 发送通知
  ///
  /// - app [Map] 通知消息数据
  static Future<void> sendNotify(Map appData, int notifyId,
      {int retry = 6}) async {
    final notifyJson = jsonEncode({
      "ncs_notification": appData,
    });
    final dataList =
        _getNotifyPackList(0x4B, notifyId, utf8.encode(notifyJson));
    print(
        "proto -> sendNotify: notifyId = $notifyId, data length = ${dataList.length} , data = $dataList, app = $notifyJson");
    for (var i = 0; i < retry; i++) {
      final isSuccess =
          await BleManager.requestList(dataList, timeoutMs: 1000, lr: "L");
      if (isSuccess) {
        return;
      }
    }
  }

  static List<Uint8List> _getNotifyPackList(
      int cmd, int msgId, Uint8List data) {
    List<Uint8List> send = [];
    int maxSeq = data.length ~/ 176;
    if (data.length % 176 > 0) {
      maxSeq++;
    }
    for (var seq = 0; seq < maxSeq; seq++) {
      var start = seq * 176;
      var end = start + 176;
      if (end > data.length) {
        end = data.length;
      }
      var itemData = data.sublist(start, end);
      var pack =
          Utils.addPrefixToUint8List([cmd, msgId, maxSeq, seq], itemData);
      send.add(pack);
    }
    return send;
  }
}
