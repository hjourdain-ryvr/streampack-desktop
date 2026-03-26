import 'package:flutter/material.dart';
import '../models.dart';

class ValidationReport extends StatelessWidget {
  final ValidationResult result;
  const ValidationReport({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    if (result.isCombined) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.hls != null) ...[
            _ProtoLabel(label: 'HLS', summary: result.hls!.summary),
            const SizedBox(height: 4),
            _SingleReport(result: result.hls!),
            const SizedBox(height: 12),
          ],
          if (result.dash != null) ...[
            _ProtoLabel(label: 'DASH', summary: result.dash!.summary),
            const SizedBox(height: 4),
            _SingleReport(result: result.dash!),
          ],
        ],
      );
    }
    return _SingleReport(result: result);
  }
}

class _ProtoLabel extends StatelessWidget {
  final String label;
  final ValidationSummary summary;
  const _ProtoLabel({required this.label, required this.summary});

  @override
  Widget build(BuildContext context) {
    final color = _summaryColor(summary, context);
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          border: Border.all(color: color.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 9,
                fontWeight: FontWeight.w700, letterSpacing: 1.2)),
      ),
    ]);
  }
}

class _SingleReport extends StatelessWidget {
  final ValidationResult result;
  const _SingleReport({required this.result});

  @override
  Widget build(BuildContext context) {
    final summaryColor = _summaryColor(result.summary, context);
    final summaryLabel = switch (result.summary) {
      ValidationSummary.pass => 'PASS',
      ValidationSummary.warn => 'WARNINGS',
      ValidationSummary.fail => 'FAILED',
    };
    final summaryIcon = switch (result.summary) {
      ValidationSummary.pass => Icons.check_circle_outline,
      ValidationSummary.warn => Icons.warning_amber_outlined,
      ValidationSummary.fail => Icons.cancel_outlined,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary badge
        Row(children: [
          Icon(summaryIcon, color: summaryColor, size: 14),
          const SizedBox(width: 6),
          Text(summaryLabel,
              style: TextStyle(
                  color: summaryColor, fontSize: 11,
                  fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        ]),
        const SizedBox(height: 6),

        // Top-level checks
        ...result.checks.map((c) => _CheckRow(item: c)),

        // Variants / representations
        if (result.variants.isNotEmpty) ...[
          const SizedBox(height: 4),
          ...result.variants.map((v) => _VariantTile(variant: v)),
        ],
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  final CheckItem item;
  const _CheckRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (item.level) {
      CheckLevel.ok   => (Icons.check, const Color(0xFF00d4aa)),
      CheckLevel.warn => (Icons.warning_amber, const Color(0xFFf5c542)),
      CheckLevel.fail => (Icons.close, const Color(0xFFff4f6a)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 6),
          Text(item.code,
              style: TextStyle(
                  color: color.withOpacity(0.6),
                  fontSize: 10, fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(
            child: Text(item.message,
                style: TextStyle(color: color, fontSize: 10, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _VariantTile extends StatelessWidget {
  final VariantResult variant;
  const _VariantTile({required this.variant});

  @override
  Widget build(BuildContext context) {
    final hasFail = variant.checks.any((c) => c.level == CheckLevel.fail);
    final hasWarn = variant.checks.any((c) => c.level == CheckLevel.warn);
    final color = hasFail
        ? const Color(0xFFff4f6a)
        : hasWarn
            ? const Color(0xFFf5c542)
            : const Color(0xFF00d4aa);

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF181c22),
              border: Border.all(color: const Color(0xFF2e3440)),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(variant.resolution,
                style: const TextStyle(
                    color: Color(0xFF8a92a8),
                    fontSize: 9, fontFamily: 'monospace')),
          ),
          const SizedBox(width: 8),
          Text(variant.uri,
              style: const TextStyle(
                  color: Color(0xFF8a92a8), fontSize: 10, fontFamily: 'monospace')),
          const Spacer(),
          Icon(Icons.circle, color: color, size: 8),
        ]),
        children: variant.checks.map((c) => Padding(
          padding: const EdgeInsets.only(left: 16),
          child: _CheckRow(item: c),
        )).toList(),
      ),
    );
  }
}

Color _summaryColor(ValidationSummary s, BuildContext context) => switch (s) {
  ValidationSummary.pass => const Color(0xFF00d4aa),
  ValidationSummary.warn => const Color(0xFFf5c542),
  ValidationSummary.fail => const Color(0xFFff4f6a),
};
