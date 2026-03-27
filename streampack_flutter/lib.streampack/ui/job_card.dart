import 'package:flutter/material.dart';
import '../models.dart';
import '../job_runner.dart';
import '../l10n.dart';
import 'validation_report.dart';

class JobCard extends StatefulWidget {
  final Job job;
  final JobRunner runner;
  const JobCard({super.key, required this.job, required this.runner});
  @override
  State<JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<JobCard> {
  bool _validationExpanded = false;

  @override
  Widget build(BuildContext context) {
    final job    = widget.job;
    final theme  = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final red    = theme.colorScheme.error;
    final yellow = theme.colorScheme.secondary;
    final l      = context.l10n;

    final borderColor = switch (job.status) {
      JobStatus.done       => accent.withOpacity(0.3),
      JobStatus.error      => red.withOpacity(0.3),
      JobStatus.validating => yellow.withOpacity(0.25),
      _                    => const Color(0xFF2e3848),
    };

    final canDismiss = job.status == JobStatus.done ||
        job.status == JobStatus.error || job.status == JobStatus.cancelled;

    final statusLabel = switch (job.status) {
      JobStatus.queued     => l.jobStatusQueued,
      JobStatus.running    => l.jobStatusRunning,
      JobStatus.validating => l.jobStatusValidating,
      JobStatus.done       => l.jobStatusDone,
      JobStatus.error      => l.jobStatusError,
      JobStatus.cancelled  => l.jobStatusCancelled,
    };

    final statusColor = switch (job.status) {
      JobStatus.queued     => const Color(0xFF9aa3b8),
      JobStatus.running    => const Color(0xFF00d4aa),
      JobStatus.validating => const Color(0xFFf5c542),
      JobStatus.done       => const Color(0xFF00d4aa),
      JobStatus.error      => const Color(0xFFff4f6a),
      JobStatus.cancelled  => const Color(0xFFf5c542),
    };

    final card = Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: BorderSide(color: borderColor)),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(children: [
            _IdBadge(job.id),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(job.inputBasename,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              Text('→ ${job.hlsOutputDir}',
                  style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 10, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis),
            ])),
          ]),
          const SizedBox(height: 8),

          // Badges
          Wrap(spacing: 4, runSpacing: 4, children: [
            ...job.resolutions.map((r) => _Badge(r.label)),
            _Badge('${job.segmentDuration}s seg'),
            _Badge(job.format.name.toUpperCase(),
                color: accent.withOpacity(0.15), textColor: accent,
                borderColor: accent.withOpacity(0.3)),
            if (job.status == JobStatus.running && job.currentPass.isNotEmpty)
              _Badge('${job.currentPass.toUpperCase()} pass',
                  color: yellow.withOpacity(0.1), textColor: yellow,
                  borderColor: yellow.withOpacity(0.3)),
          ]),
          const SizedBox(height: 8),

          // Progress bar
          ClipRRect(borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: job.status == JobStatus.validating ? null : job.progress,
              minHeight: 5,
              backgroundColor: const Color(0xFF20252f),
              valueColor: AlwaysStoppedAnimation(
                  job.status == JobStatus.validating ? yellow : accent),
            )),
          const SizedBox(height: 8),

          // Footer
          Row(children: [
            // Status pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  border: Border.all(color: statusColor),
                  borderRadius: BorderRadius.circular(999)),
              child: Text(statusLabel,
                  style: TextStyle(color: statusColor, fontSize: 9, fontFamily: 'monospace'))),
            const SizedBox(width: 8),
            Text(
              job.status == JobStatus.validating
                  ? l.jobValidating
                  : '${(job.progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace')),
            const SizedBox(width: 8),
            Text(job.elapsedLabel,
                style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace')),
            const Spacer(),
            if (job.status == JobStatus.queued || job.status == JobStatus.running)
              TextButton(
                onPressed: () => widget.runner.cancel(job),
                style: TextButton.styleFrom(foregroundColor: red,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text(l.jobCancel, style: const TextStyle(fontSize: 10))),
          ]),

          // Skipped renditions
          if (job.skippedRenditions != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: yellow.withOpacity(0.08),
                  border: Border.all(color: yellow.withOpacity(0.2)),
                  borderRadius: BorderRadius.circular(6)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber, color: yellow, size: 13),
                const SizedBox(width: 6),
                Expanded(child: Text(l.skippedRenditions(job.skippedRenditions!),
                    style: TextStyle(color: yellow, fontSize: 10, fontFamily: 'monospace'))),
              ]),
            ),
          ],

          // Error
          if (job.error != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: red.withOpacity(0.08),
                  border: Border.all(color: red.withOpacity(0.2)),
                  borderRadius: BorderRadius.circular(6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('FFMPEG ERROR', style: TextStyle(color: red.withOpacity(0.7),
                    fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                const SizedBox(height: 4),
                SelectableText(job.error!, style: TextStyle(color: red, fontSize: 10, fontFamily: 'monospace')),
              ]),
            ),
          ],

          // Validation
          if (job.validation != null) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _validationExpanded = !_validationExpanded),
              borderRadius: BorderRadius.circular(6),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(_validationExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 14, color: const Color(0xFF9aa3b8)),
                  const SizedBox(width: 4),
                  Text(l.jobValidationReport,
                      style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 10, fontWeight: FontWeight.w600)),
                ])),
            ),
            if (_validationExpanded) ...[
              const SizedBox(height: 4),
              ValidationReport(result: job.validation!),
            ],
          ],
        ],
      )),
    );

    if (!canDismiss) return card;

    return Stack(clipBehavior: Clip.none, children: [
      card,
      Positioned(top: 6, right: 6,
        child: Tooltip(message: l.jobRemoveTooltip,
          child: InkWell(onTap: () => widget.runner.remove(job),
            borderRadius: BorderRadius.circular(999),
            child: const Padding(padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 13, color: Color(0xFF9aa3b8)))))),
    ]);
  }
}

class _IdBadge extends StatelessWidget {
  final String id;
  const _IdBadge(this.id);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: const Color(0xFF00d4aa).withOpacity(0.1),
        borderRadius: BorderRadius.circular(4)),
    child: Text('#$id', style: const TextStyle(color: Color(0xFF00d4aa),
        fontSize: 9, fontFamily: 'monospace', fontWeight: FontWeight.w600)));
}

class _Badge extends StatelessWidget {
  final String label;
  final Color? color, textColor, borderColor;
  const _Badge(this.label, {this.color, this.textColor, this.borderColor});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: color ?? const Color(0xFF20252f),
        border: Border.all(color: borderColor ?? const Color(0xFF4d5870)),
        borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: TextStyle(
        color: textColor ?? const Color(0xFF9aa3b8), fontSize: 9, fontFamily: 'monospace')));
}
