import 'dart:async';

import 'package:flutter/material.dart';

import '../../../api.dart';
import '../../../core/ui/adaptive_size.dart';
import '../../../models.dart';

class AuthScreen extends StatefulWidget {
  final AstraApi api;
  final Future<void> Function(AuthResult result) onAuthorized;

  const AuthScreen({super.key, required this.api, required this.onAuthorized});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  Timer? _countdownTimer;
  bool _loading = false;
  int _remainingSeconds = 0;
  PhoneCodeSession? _session;

  bool get _isPhoneStep => _session == null;

  bool get _canSendCode {
    final digits = _phoneController.text.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 10;
  }

  bool get _canVerify {
    if (_session == null) return false;
    return _codeController.text.trim().length >= 4;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (!_canSendCode || _loading) return;

    setState(() => _loading = true);
    try {
      final session = await widget.api.requestPhoneCode(_phoneController.text);
      if (!mounted) return;
      _codeController.clear();
      _startCountdown(session.expiresInSeconds);
      setState(() {
        _session = session;
      });
      _showSnack('Code sent to ${session.phone}');
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _verifyCode() async {
    if (!_canVerify || _loading || _session == null) return;

    setState(() => _loading = true);
    try {
      final result = await widget.api.verifyPhoneCode(
        phone: _session!.phone,
        codeToken: _session!.codeToken,
        code: _codeController.text.trim(),
      );
      await widget.onAuthorized(result);
    } catch (error) {
      _showSnack(error.toString());
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _remainingSeconds = seconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remainingSeconds <= 1) {
        timer.cancel();
        setState(() => _remainingSeconds = 0);
        return;
      }
      setState(() => _remainingSeconds -= 1);
    });
  }

  void _goBackToPhoneStep() {
    _countdownTimer?.cancel();
    setState(() {
      _session = null;
      _remainingSeconds = 0;
      _codeController.clear();
    });
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = context.sp(22);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              theme.colorScheme.surface,
              theme.colorScheme.surfaceContainerLowest,
              theme.colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: context.sp(540)),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(padding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HeroBlock(session: _session),
                    SizedBox(height: context.sp(22)),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _isPhoneStep
                          ? _PhoneStep(
                              controller: _phoneController,
                              canContinue: _canSendCode && !_loading,
                              loading: _loading,
                              onChanged: () => setState(() {}),
                              onContinue: _requestCode,
                            )
                          : _CodeStep(
                              session: _session!,
                              controller: _codeController,
                              canContinue: _canVerify && !_loading,
                              loading: _loading,
                              remainingSeconds: _remainingSeconds,
                              onChanged: () => setState(() {}),
                              onBack: _goBackToPhoneStep,
                              onContinue: _verifyCode,
                              onResend: _requestCode,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroBlock extends StatelessWidget {
  final PhoneCodeSession? session;

  const _HeroBlock({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.all(context.sp(24)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.sp(30)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer,
            theme.colorScheme.surfaceContainerHigh,
          ],
        ),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: context.sp(58),
            height: context.sp(58),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(context.sp(18)),
              color: theme.colorScheme.primary,
            ),
            child: Icon(
              Icons.send_rounded,
              color: theme.colorScheme.onPrimary,
              size: context.sp(28),
            ),
          ),
          SizedBox(height: context.sp(16)),
          Text(
            'oMsg',
            style: TextStyle(
              fontSize: context.sp(34),
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          SizedBox(height: context.sp(8)),
          Text(
            session == null
                ? 'Sign in with your phone number. We send a one-time code and continue from there.'
                : 'Enter the code from SMS. New accounts will finish setup on the next screen.',
            style: TextStyle(
              fontSize: context.sp(15),
              height: 1.45,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: context.sp(18)),
          Wrap(
            spacing: context.sp(8),
            runSpacing: context.sp(8),
            children: [
              _StepBadge(
                icon: Icons.call_rounded,
                label: 'Phone',
                active: session == null,
              ),
              _StepBadge(
                icon: Icons.password_rounded,
                label: 'Code',
                active: session != null,
              ),
              const _StepBadge(
                icon: Icons.person_outline_rounded,
                label: 'Profile',
                active: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhoneStep extends StatelessWidget {
  final TextEditingController controller;
  final bool canContinue;
  final bool loading;
  final VoidCallback onChanged;
  final VoidCallback onContinue;

  const _PhoneStep({
    required this.controller,
    required this.canContinue,
    required this.loading,
    required this.onChanged,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('phone-step'),
      child: Padding(
        padding: EdgeInsets.all(context.sp(20)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your phone number',
              style: TextStyle(
                fontSize: context.sp(22),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(8)),
            Text(
              'Use the number that will be linked to your account and searchable by contacts.',
              style: TextStyle(
                fontSize: context.sp(14),
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            SizedBox(height: context.sp(18)),
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '+7 900 000 00 00',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              onChanged: (_) => onChanged(),
            ),
            SizedBox(height: context.sp(18)),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canContinue ? onContinue : null,
                child: loading
                    ? SizedBox(
                        width: context.sp(18),
                        height: context.sp(18),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CodeStep extends StatelessWidget {
  final PhoneCodeSession session;
  final TextEditingController controller;
  final bool canContinue;
  final bool loading;
  final int remainingSeconds;
  final VoidCallback onChanged;
  final VoidCallback onBack;
  final VoidCallback onContinue;
  final VoidCallback onResend;

  const _CodeStep({
    required this.session,
    required this.controller,
    required this.canContinue,
    required this.loading,
    required this.remainingSeconds,
    required this.onChanged,
    required this.onBack,
    required this.onContinue,
    required this.onResend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('code-step'),
      child: Padding(
        padding: EdgeInsets.all(context.sp(20)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter verification code',
              style: TextStyle(
                fontSize: context.sp(22),
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: context.sp(8)),
            Text(
              session.phone,
              style: TextStyle(
                fontSize: context.sp(14),
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: context.sp(6)),
            Text(
              session.isRegistered
                  ? 'Existing account detected. Enter the code to continue.'
                  : 'This number is new. After verification you will choose your public profile details.',
              style: TextStyle(
                fontSize: context.sp(14),
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            SizedBox(height: context.sp(18)),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'Code from SMS',
                prefixIcon: Icon(Icons.lock_open_rounded),
              ),
              onChanged: (_) => onChanged(),
              onSubmitted: (_) {
                if (canContinue) {
                  onContinue();
                }
              },
            ),
            SizedBox(height: context.sp(4)),
            Row(
              children: [
                Expanded(
                  child: Text(
                    remainingSeconds > 0
                        ? 'Code expires in ${_formatSeconds(remainingSeconds)}'
                        : 'Didn\'t receive it? Request another code.',
                    style: TextStyle(
                      fontSize: context.sp(13),
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: loading ? null : onBack,
                  child: const Text('Change number'),
                ),
              ],
            ),
            SizedBox(height: context.sp(10)),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        remainingSeconds == 0 && !loading ? onResend : null,
                    child: const Text('Resend code'),
                  ),
                ),
                SizedBox(width: context.sp(10)),
                Expanded(
                  child: FilledButton(
                    onPressed: canContinue ? onContinue : null,
                    child: loading
                        ? SizedBox(
                            width: context.sp(18),
                            height: context.sp(18),
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Open messenger'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSeconds(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _StepBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  const _StepBadge({
    required this.icon,
    required this.label,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.sp(12),
        vertical: context.sp(10),
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: active
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : theme.colorScheme.surfaceContainerHighest,
        border: Border.all(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.25)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: context.sp(16),
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          SizedBox(width: context.sp(6)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.sp(13),
              fontWeight: FontWeight.w600,
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
