// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:demo_ai_even/ble_manager.dart';
import 'package:demo_ai_even/services/evenai.dart';
import 'package:demo_ai_even/views/even_list_page.dart';
import 'package:demo_ai_even/views/features_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Timer? scanTimer;
  bool isScanning = false;
  bool batteryOptimizationEnabled = true;

  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
  }

  void _initializeBluetooth() {
    try {
      BleManager.get().setMethodCallHandler();
      BleManager.get().startListening();
      BleManager.get().onStatusChanged = _refreshPage;
      
      // handle ble errors
      BleManager.get().onError = (error) {
        print('${DateTime.now()} BLE Error in HomePage: $error');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Bluetooth Error: ${error.message}'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      };
      
      // handle evenai errors
      EvenAI.get.onError = (error) {
        print('${DateTime.now()} EvenAI Error in HomePage: $error');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('EvenAI Error: ${error.message}'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      };
      
    } catch (e) {
      print('${DateTime.now()} Error initializing Bluetooth: $e');
    }
  }

  void _refreshPage() => setState(() {});

  Future<void> _startScan() async {
    try {
      if (isScanning) {
        print('${DateTime.now()} Scan already in progress');
        return;
      }

      setState(() => isScanning = true);
      await BleManager.get().startScan();
      
      scanTimer?.cancel();
      scanTimer = Timer(15.seconds, () {
        print('${DateTime.now()} Scan timeout, stopping scan');
        _stopScan();
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scanning for glasses...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('${DateTime.now()} Error starting scan: $e');
      setState(() => isScanning = false);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error starting scan: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopScan() async {
    try {
      if (isScanning) {
        await BleManager.get().stopScan();
        setState(() => isScanning = false);
        scanTimer?.cancel();
        scanTimer = null;
        print('${DateTime.now()} Scan stopped');
      }
    } catch (e) {
      print('${DateTime.now()} Error stopping scan: $e');
      setState(() => isScanning = false);
    }
  }

  Widget blePairedList() => Expanded(
        child: ListView.separated(
          separatorBuilder: (context, index) => const SizedBox(height: 5),
          itemCount: BleManager.get().getPairedGlasses().length,
          itemBuilder: (context, index) {
            final glasses = BleManager.get().getPairedGlasses()[index];
            return GestureDetector(
              onTap: () async {
                try {
                  String channelNumber = glasses['channelNumber']!;
                  print('${DateTime.now()} Attempting to connect to Pair_$channelNumber');
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Connecting to glasses...'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                  
                  await BleManager.get().connectToGlasses("Pair_$channelNumber");
                  _refreshPage();
                } catch (e) {
                  print('${DateTime.now()} Error connecting to glasses: $e');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to connect: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: Container(
                height: 72,
                padding: const EdgeInsets.only(left: 16, right: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Pair: ${glasses['channelNumber']}'),
                        Text(
                            'Left: ${glasses['leftDeviceName']} \nRight: ${glasses['rightDeviceName']}'),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Even AI Demo'),
          actions: [
            // battery optimization toggle
            InkWell(
              onTap: () {
                setState(() {
                  batteryOptimizationEnabled = !batteryOptimizationEnabled;
                });
                BleManager.setBatteryOptimizationMode(batteryOptimizationEnabled);
                EvenAI.setBatteryOptimization(batteryOptimizationEnabled);
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(batteryOptimizationEnabled 
                      ? 'Battery optimization enabled' 
                      : 'Battery optimization disabled'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: Padding(
                padding: EdgeInsets.only(left: 8, top: 12, bottom: 14, right: 8),
                child: Icon(
                  batteryOptimizationEnabled ? Icons.battery_saver : Icons.battery_full,
                  color: batteryOptimizationEnabled ? Colors.green : Colors.grey,
                ),
              ),
            ),
            InkWell(
              onTap: () {
                print("To Features Page...");
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const FeaturesPage()),
                );
              },
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: const Padding(
                padding:
                    EdgeInsets.only(left: 16, top: 12, bottom: 14, right: 16),
                child: Icon(Icons.menu),
              ),
            ),
          ],
        ),
        body: Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () async {
                  if (BleManager.get().getConnectionStatus() ==
                      'Not connected') {
                    _startScan();
                  }
                },
                child: Container(
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: Text(BleManager.get().getConnectionStatus(),
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
              if (BleManager.get().getConnectionStatus() == 'Not connected')
                blePairedList(),
              if (BleManager.get().isConnected)
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      // todo
                      print("To AI History List...");
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const EvenAIListPage(),
                        ),
                      );
                    },
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(16),
                      alignment: Alignment.topCenter,
                      child: SingleChildScrollView(
                        child: StreamBuilder<String>(
                          stream: EvenAI.textStream,
                          initialData:
                              "Press and hold left TouchBar to engage Even AI.",
                          builder: (context, snapshot) => Obx(
                            () => EvenAI.isEvenAISyncing.value
                                ? const SizedBox(
                                    width: 50,
                                    height: 50,
                                    child: CircularProgressIndicator(),
                                  ) // Color(0xFFFEF991)
                                : Text(
                                    snapshot.data ?? "Loading...",
                                    style: TextStyle(
                                        fontSize: 14,
                                        color: BleManager.get().isConnected
                                            ? Colors.black
                                            : Colors.grey.withOpacity(0.5)),
                                    textAlign: TextAlign.center,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    try {
      scanTimer?.cancel();
      scanTimer = null;
      isScanning = false;
      
      // cleanup callbacks
      BleManager.get().onStatusChanged = null;
      BleManager.get().onError = null;
      EvenAI.get.onError = null;
      
      print('${DateTime.now()} HomePage disposed');
    } catch (e) {
      print('${DateTime.now()} Error in HomePage dispose: $e');
    }
    super.dispose();
  }
}
