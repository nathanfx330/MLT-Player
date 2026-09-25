// lib/ui/widgets/text_prompt_dialog.dart

import 'package:flutter/material.dart';

Future<String?> showTextPromptDialog(
  BuildContext context, {
  required String title,
  required String hint,
  String initialValue = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => TextPromptDialog(
      title: title,
      hint: hint,
      initialValue: initialValue,
    ),
  );
}

class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.hint,
    this.initialValue = '',
  });

  final String title;
  final String hint;
  final String initialValue;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) {
      Navigator.of(context).pop(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCEL'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('SAVE'),
        ),
      ],
    );
  }
}
