import 'package:dio_resilience/dio_resilience.dart';
import 'package:flutter/material.dart';

import 'api_client.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _result = 'Tap a button to run a test';
  bool _isLoading = false;

  Future<void> _runTest(Future<void> Function() fn) async {
    setState(() {
      _result = 'Running...';
      _isLoading = true;
    });
    try {
      await fn();
      setState(() {
        _result = 'Success!';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _result = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dio_resilience Demo'),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Auth state display
              StreamBuilder<AuthState>(
                stream: apiClient.authStateStream,
                builder: (context, snapshot) {
                  final state = snapshot.data?.name ?? 'idle';
                  return Card(
                    color: Colors.blue[50],
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Auth State: $state',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),

              // Result display
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _result,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 24),

              // Test buttons
              ElevatedButton(
                onPressed: _isLoading
                    ? null
                    : () => _runTest(() async {
                          apiClient.resetFlakyCounter();
                          await apiClient.testFlaky();
                        }),
                child: const Text('Test Retry (Flaky)'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isLoading ? null : () => _runTest(apiClient.testAuthRefresh),
                child: const Text('Test Auth Refresh'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isLoading ? null : () => _runTest(apiClient.testTimeout),
                child: const Text('Test Timeout'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isLoading ? null : () => _runTest(apiClient.testDontRetry),
                child: const Text('Test Don\'t Retry (409)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
