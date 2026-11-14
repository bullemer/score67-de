import 'package:flutter/material.dart';

/// Below this height (a phone in landscape, or any phone with the keyboard
/// open) the dialog drops its margins and moves the buttons up next to the
/// title, so the fields keep the little room the keyboard leaves.
const compactDialogHeight = 420.0;

/// AlertDialog replacement for dialogs with text fields. An AlertDialog keeps
/// its title and button rows at full size, so in landscape with the keyboard
/// open they used up all of the space and the field being typed into was not
/// visible at all.
///
/// The widget tree is the same in both layouts: the content keeps its state
/// and the keyboard stays open when the layout switches as the keyboard opens.
class InputDialog extends StatelessWidget {
  final Widget title;
  final Widget content;
  final List<Widget> actions;

  /// Wraps content that does not scroll by itself, so it never overflows.
  final bool scrollable;
  const InputDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.vertical;
    final compact = availableHeight < compactDialogHeight;
    final theme = Theme.of(context);
    final buttons = Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      children: actions,
    );
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: compact
          ? const EdgeInsets.fromLTRB(8, 4, 8, 4)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: compact
                  ? const EdgeInsets.fromLTRB(16, 4, 8, 0)
                  : const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Row(
                children: [
                  Expanded(
                    child: DefaultTextStyle(
                      style: compact
                          ? theme.textTheme.titleMedium!
                          : theme.textTheme.headlineSmall!,
                      maxLines: compact ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                      child: title,
                    ),
                  ),
                  if (compact) Flexible(child: buttons),
                ],
              ),
            ),
            Flexible(
              key: const ValueKey('content'),
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, compact ? 10 : 0, 24, 8),
                child: scrollable
                    ? SingleChildScrollView(child: content)
                    : content,
              ),
            ),
            if (!compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: buttons,
              ),
          ],
        ),
      ),
    );
  }
}
