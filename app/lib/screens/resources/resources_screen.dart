import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../services/ws_client.dart';

class ResourcesScreen extends ConsumerStatefulWidget {
  const ResourcesScreen({super.key});

  @override
  ConsumerState<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends ConsumerState<ResourcesScreen> {
  WsClient? _ws;
  Map<String, dynamic>? _info;

  @override
  void initState() {
    super.initState();
    final api = ref.read(apiClientProvider);
    final ws = WsClient.connect(api.wsUrl('/ws/system'));
    _ws = ws;
    ws.events.listen((event) {
      if (mounted) setState(() => _info = event);
    });
  }

  @override
  void dispose() {
    _ws?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final info = _info;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ref.t('resources_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 24),
          if (info == null)
            const CircularProgressIndicator()
          else
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _ResourceCard(
                  icon: Icons.memory,
                  title: ref.t('resources_cpu'),
                  primary: '${info['cpu']['cores']} ${ref.t('resources_cores')}',
                  percent: (info['cpu']['percent'] as num).toDouble() / 100,
                  detail: '${info['cpu']['percent']}% ${ref.t('resources_used')}',
                  colors: colors,
                ),
                _ResourceCard(
                  icon: Icons.developer_board,
                  title: ref.t('resources_ram'),
                  primary: '${info['ram']['total_gb']} GB',
                  percent: (info['ram']['percent'] as num).toDouble() / 100,
                  detail: '${info['ram']['used_gb']} GB ${ref.t('resources_used')}',
                  colors: colors,
                ),
                _ResourceCard(
                  icon: Icons.storage,
                  title: ref.t('resources_disk'),
                  primary: '${info['disk']['total_gb']} GB',
                  percent: info['disk']['total_gb'] > 0 ? (info['disk']['used_gb'] as num) / (info['disk']['total_gb'] as num): 0,
                  detail: '${info['disk']['free_gb']} GB ${ref.t('resources_free')}',
                  colors: colors,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ResourceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String primary;
  final double percent;
  final String detail;
  final AppPalette colors;

  const _ResourceCard({
    required this.icon,
    required this.title,
    required this.primary,
    required this.percent,
    required this.detail,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        width: 260,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: colors.primaryDark, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 14),
            Text(primary, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: percent.clamp(0, 1), minHeight: 6),
            ),
            const SizedBox(height: 8),
            Text(detail, style: TextStyle(fontSize: 12, color: colors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
