// lib/ui/widgets/redleaf_hub_onboarding_dialog.dart

import 'package:flutter/material.dart';

import '../../services/redleaf_connection_service.dart';
import '../../services/redleaf_shared_credential_vault.dart';

/// Launched by Redleaf Hub for a database that has not yet been imported and
/// synced into MLT Player. The Hub passes only the project folder and server
/// URL; authentication is performed inside MLT Player.
class RedleafHubOnboardingDialog extends StatefulWidget {
  const RedleafHubOnboardingDialog({
    super.key,
    required this.expectedInstanceId,
    required this.suggestedName,
    required this.serverUrl,
    required this.connection,
    required this.onImport,
    this.existingInTrash = false,
    this.hasCachedSnapshot = false,
    this.onRestoreCached,
    this.savedCredentials,
    this.keyringWarning,
  });

  final String expectedInstanceId;
  final String suggestedName;
  final String serverUrl;
  final RedleafConnectionService connection;
  final Future<void> Function(String projectName, bool restoreFromTrash)
      onImport;
  final bool existingInTrash;
  final bool hasCachedSnapshot;
  final Future<void> Function()? onRestoreCached;
  final RedleafSavedCredentials? savedCredentials;
  final String? keyringWarning;

  @override
  State<RedleafHubOnboardingDialog> createState() =>
      _RedleafHubOnboardingDialogState();
}

class _RedleafHubOnboardingDialogState
    extends State<RedleafHubOnboardingDialog> {
  late final TextEditingController _server;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _projectName;

  bool _busy = false;
  bool _showPassword = false;
  bool _useSavedLogin = false;
  String? _error;

  bool get _canRestoreOffline =>
      widget.existingInTrash &&
      widget.hasCachedSnapshot &&
      widget.onRestoreCached != null;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.serverUrl);
    _username = TextEditingController(
      text: widget.savedCredentials?.username ?? widget.connection.username,
    );
    _password = TextEditingController();
    _projectName = TextEditingController(text: widget.suggestedName);
    _useSavedLogin = widget.savedCredentials != null;
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _projectName.dispose();
    super.dispose();
  }

  Future<void> _restoreCached() async {
    final restore = widget.onRestoreCached;
    if (_busy || restore == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await restore();
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInAndImport() async {
    if (_busy) return;
    final name = _projectName.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Choose an MLT Player project name.');
      return;
    }
    final server = _server.text.trim();
    final alreadyConnected = widget.connection.isConnected &&
        widget.connection.instanceId == widget.expectedInstanceId &&
        widget.connection.serverUrl == server;

    final useSavedLogin = _useSavedLogin && widget.savedCredentials != null;
    if (!alreadyConnected &&
        !useSavedLogin &&
        (_username.text.trim().isEmpty || _password.text.isEmpty)) {
      setState(() => _error = 'Enter your Redleaf username and password.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!alreadyConnected) {
        final authenticated = await widget.connection.signIn(
          serverUrl: server,
          username: useSavedLogin
              ? widget.savedCredentials!.username
              : _username.text.trim(),
          password: useSavedLogin
              ? widget.savedCredentials!.password
              : _password.text,
        );
        if (!authenticated) {
          // An outdated saved secret should never cause an endless retry
          // loop. Switch to manual entry while leaving Hub's keyring alone.
          if (useSavedLogin && mounted) {
            setState(() => _useSavedLogin = false);
          }
          throw StateError(
            widget.connection.lastError ??
                'Could not sign in to this Redleaf server.',
          );
        }
      }

      // Do not trust a server merely because its login succeeded. It must
      // identify the exact Redleaf database selected by Hub.
      if (!widget.connection.isConnected ||
          widget.connection.instanceId != widget.expectedInstanceId) {
        widget.connection.disconnect();
        throw StateError(
          'The signed-in Redleaf server is not the project selected in '
          'Redleaf Hub. Check which project is running on this port.',
        );
      }

      await widget.onImport(name, widget.existingInTrash);
      if (mounted) {
        _password.clear();
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existingInTrash
            ? 'Restore Redleaf project'
            : 'Add Redleaf project to MLT Player',
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.existingInTrash
                    ? 'This Redleaf project is in MLT Player Trash. '
                        'Restore the saved project rather than create a duplicate.'
                    : 'Redleaf Hub opened this project, but MLT Player does not '
                        'have a synced snapshot yet. Sign in and choose an '
                        'MLT Player name to import its transcripts and catalogs.',
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              if (_canRestoreOffline) ...[
                const SizedBox(height: 12),
                const Text(
                  'A cached snapshot exists. You can restore it without '
                  'signing in, or sign in below to refresh the catalog.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restoreCached,
                  icon: const Icon(Icons.restore),
                  label: const Text('RESTORE SAVED PROJECT'),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _projectName,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'MLT Player project name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _server,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Redleaf server',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              if (widget.savedCredentials != null) ...[
                CheckboxListTile(
                  value: _useSavedLogin,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                            () => _useSavedLogin = value ?? false,
                          ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Use saved Redleaf login from Hub'),
                  subtitle: Text(
                    'Account: ${widget.savedCredentials!.username}',
                    style: const TextStyle(color: Colors.white60),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (widget.keyringWarning != null) ...[
                Text(
                  widget.keyringWarning!,
                  style: const TextStyle(
                    color: Colors.amberAccent,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _username,
                enabled: !_busy && !_useSavedLogin,
                decoration: const InputDecoration(
                  labelText: 'Redleaf username',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                enabled: !_busy && !_useSavedLogin,
                obscureText: !_showPassword,
                onSubmitted: (_) => _signInAndImport(),
                decoration: InputDecoration(
                  labelText: 'Redleaf password',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed: _busy
                        ? null
                        : () => setState(
                              () => _showPassword = !_showPassword,
                            ),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Saved credentials, when selected, are read from the '
                'Linux login keyring, not passed in the Hub launch command. '
                'MLT Player verifies the Redleaf database identity before importing.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('CANCEL'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _signInAndImport,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_outlined),
          label: Text(
            _busy
                ? 'CONNECTING…'
                : widget.existingInTrash
                    ? 'SIGN IN AND RESTORE'
                    : 'SIGN IN AND IMPORT',
          ),
        ),
      ],
    );
  }
}
