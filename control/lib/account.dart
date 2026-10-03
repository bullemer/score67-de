import 'package:flutter/material.dart';

/// Optional email sign-in (no password): a link by email signs this browser
/// in; boards linked to the address can then be controlled on any device.
typedef AccountApi =
    Future<dynamic> Function(String, String, Map<String, dynamic>?);

String _errorCode(Object e) {
  final text = e.toString();
  return text.startsWith('ApiError:') ? text.substring(9) : 'network';
}

const _muted = TextStyle(color: Color(0xffb5c2d4));

class AccountPanel extends StatefulWidget {
  final AccountApi api;
  final String Function(String) t;
  final String language;

  /// Called after logout (sign-in completes on the page the link opens).
  final VoidCallback? onChanged;

  /// Intro text above the form; hidden where the context already explains it.
  final bool intro;

  /// Draw as a card (dashboard); nothing is drawn while email is unavailable.
  final bool card;
  const AccountPanel({
    super.key,
    required this.api,
    required this.t,
    required this.language,
    this.onChanged,
    this.intro = true,
    this.card = false,
  });
  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  final email = TextEditingController();
  bool loading = true, enabled = false, busy = false;
  String? signedIn, sentTo;
  String error = '';
  String t(String key) => widget.t(key);

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final r = await widget.api('/api/account', 'GET', null);
      enabled = r['mail_enabled'] == true;
      signedIn = r['email'];
    } catch (_) {
      enabled = false;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> send() async {
    final address = email.text.trim();
    if (address.isEmpty) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.api('/api/account/login', 'POST', {
        'email': address,
        'language': widget.language,
      });
      sentTo = address;
    } catch (e) {
      error = _errorCode(e);
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> logout() async {
    setState(() => busy = true);
    try {
      await widget.api('/api/account/logout', 'POST', {});
      signedIn = null;
      widget.onChanged?.call();
    } catch (e) {
      error = _errorCode(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading || !enabled) return const SizedBox.shrink();
    if (!widget.card) return content();
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff151e2a),
        borderRadius: BorderRadius.circular(16),
      ),
      child: content(),
    );
  }

  Widget content() {
    if (signedIn != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_user_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('account.signed_in').replaceAll('{email}', signedIn!),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: busy ? null : logout,
                child: Text(t('account.logout')),
              ),
            ],
          ),
          Text(t('account.signed_in.note'), style: _muted),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('account.title'),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        if (widget.intro) ...[
          const SizedBox(height: 6),
          Text(t('account.intro'), style: _muted),
        ],
        const SizedBox(height: 10),
        if (sentTo != null) ...[
          Text(t('account.sent').replaceAll('{email}', sentTo!)),
          TextButton(
            onPressed: () => setState(() => sentTo = null),
            child: Text(t('account.other')),
          ),
        ] else ...[
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            maxLength: 254,
            onSubmitted: (_) => busy ? null : send(),
            decoration: InputDecoration(
              labelText: t('account.email'),
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: busy ? null : send,
            child: Text(t('account.send')),
          ),
        ],
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              t('error.$error'),
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
      ],
    );
  }
}

/// The page a sign-in link opens (/login#t=...). Signing in needs a tap, so
/// mail scanners that open links do not use up the single-use token.
class LoginConfirm extends StatefulWidget {
  final AccountApi api;
  final String Function(String) t;
  final String token;
  final void Function(String) navigate;
  const LoginConfirm({
    super.key,
    required this.api,
    required this.t,
    required this.token,
    required this.navigate,
  });
  @override
  State<LoginConfirm> createState() => _LoginConfirmState();
}

class _LoginConfirmState extends State<LoginConfirm> {
  bool busy = false;
  String error = '';
  Map<String, dynamic>? result;
  String t(String key) => widget.t(key);

  Future<void> confirm() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      result = Map<String, dynamic>.from(
        await widget.api('/api/account/verify', 'POST', {
          'token': widget.token,
        }),
      );
    } catch (e) {
      error = _errorCode(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final done = result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('account.confirm.title'),
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        if (widget.token.length < 20)
          Text(t('account.missing_token'))
        else if (done == null) ...[
          Text(t('account.confirm.text'), style: _muted),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : confirm,
            child: Text(t('account.confirm')),
          ),
        ] else ...[
          Text(
            t('account.signed_in').replaceAll('{email}', done['email']),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if ((done['linked'] ?? 0) > 0)
            Text(t('account.linked').replaceAll('{n}', '${done['linked']}')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => widget.navigate('/dashboard'),
            child: Text(t('dashboard')),
          ),
        ],
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              t('error.$error'),
              style: const TextStyle(color: Color(0xffffb4ab)),
            ),
          ),
      ],
    );
  }
}

/// Teilen tab: which email the board is linked to, link or unlink it.
class OwnerPanel extends StatefulWidget {
  final AccountApi api;
  final String Function(String) t;
  final String slug, language;
  final bool enabled;
  const OwnerPanel({
    super.key,
    required this.api,
    required this.t,
    required this.slug,
    required this.language,
    required this.enabled,
  });
  @override
  State<OwnerPanel> createState() => _OwnerPanelState();
}

class _OwnerPanelState extends State<OwnerPanel> {
  Map<String, dynamic>? owner;
  bool mailEnabled = false, busy = false;
  String error = '';
  String t(String key) => widget.t(key);

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final info = await widget.api('/api/account', 'GET', null);
      mailEnabled = info['mail_enabled'] == true;
      owner = Map<String, dynamic>.from(
        await widget.api('/api/s/${widget.slug}/owner', 'GET', null),
      );
    } catch (e) {
      error = _errorCode(e);
    }
    if (mounted) setState(() {});
  }

  Future<void> setLinked(bool linked) async {
    if (!linked) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(t('owner.unlink.confirm')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('owner.unlink')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.api('/api/s/${widget.slug}/owner', 'PUT', {
        'linked': linked,
      });
      await load();
    } catch (e) {
      error = _errorCode(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final o = owner;
    if (o == null || (!mailEnabled && o['email'] == null)) {
      return const SizedBox.shrink();
    }
    final email = o['email'] as String?;
    final signedIn = o['signed_in'] as String?;
    final can = widget.enabled && !busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t('owner.title'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        if (email != null) ...[
          Text(
            t('owner.linked').replaceAll('{email}', email),
            style: const TextStyle(fontSize: 14),
          ),
          OutlinedButton(
            onPressed: can ? () => setLinked(false) : null,
            child: Text(t('owner.unlink')),
          ),
        ] else ...[
          Text(t('owner.none'), style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          if (signedIn != null)
            FilledButton(
              onPressed: can ? () => setLinked(true) : null,
              child: Text(t('owner.link').replaceAll('{email}', signedIn)),
            )
          else
            AccountPanel(
              api: widget.api,
              t: widget.t,
              language: widget.language,
              intro: false,
            ),
        ],
        if (error.isNotEmpty)
          Text(
            t('error.$error'),
            style: const TextStyle(color: Color(0xffffb4ab)),
          ),
      ],
    );
  }
}
