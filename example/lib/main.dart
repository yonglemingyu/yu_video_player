import 'package:flutter/material.dart';
import 'package:yu_video_player/yu_video_player.dart';

const _vid = 'butterfly_v1';
const _url =
    'https://flutter.github.io/assets-for-api-docs/assets/videos/butterfly.mp4';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'yu_video_player example',
      theme: ThemeData(colorSchemeSeed: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  YUCacheStats? _stats;
  List<YUCacheEntry> _entries = const [];
  String _log = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final stats = await YUVideoPrefixCache.stats();
    final entries = await YUVideoPrefixCache.entries();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _entries = entries;
    });
  }

  Future<void> _prefetch() async {
    setState(() => _log = 'prefetch 已发起');
    await YUVideoPrefixCache.prefetch(_vid, _url);
    // 下载在后台进行，稍等再刷新
    await Future<void>.delayed(const Duration(seconds: 2));
    await _refresh();
    if (!mounted) return;
    setState(() => _log = 'prefetch 完成，刷新统计');
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(title: const Text('前缀缓存示例')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (stats != null) ...[
            Text('条数：${stats.count}'),
            Text('占用：${(stats.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB'),
            Text('全局上限：${(stats.maxTotalBytes / 1024 / 1024).toStringAsFixed(0)} MB'),
            Text('单条上限：${(stats.maxBytesPerVideo / 1024 / 1024).toStringAsFixed(0)} MB'),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(onPressed: _prefetch, child: const Text('预取')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _refresh, child: const Text('刷新')),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  await YUVideoPrefixCache.clearAll();
                  await _refresh();
                },
                child: const Text('清空'),
              ),
            ],
          ),
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_log, style: const TextStyle(color: Colors.grey)),
          ],
          const Divider(height: 32),
          for (final entry in _entries)
            ListTile(
              title: Text(entry.key),
              subtitle: Text(
                '${(entry.bytes / 1024).toStringAsFixed(0)} KB · '
                '${(entry.progress * 100).toStringAsFixed(0)}%',
              ),
            ),
        ],
      ),
    );
  }
}
