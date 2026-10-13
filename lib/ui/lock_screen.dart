import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_lock.dart';
import '../data/company_manager.dart';
import '../util/format.dart';

/// Shown instead of the app while the active company is locked with a PIN.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock, required this.companies});
  final AppLock lock;
  final CompanyManager companies;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final pin = TextEditingController();
  String? error;

  void _try() {
    final ok = widget.lock.unlock(widget.companies.activeId, enDigits(pin.text.trim()));
    if (!ok) {
      setState(() => error = widget.lock.waitSeconds > 0
          ? 'چند بار اشتباه زدید. ${faDigits('${widget.lock.waitSeconds}')} ثانیه دیگر دوباره امتحان کنید.'
          : 'رمز اشتباه است.');
      pin.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.companies;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/logo.png', width: 96, height: 96),
              const SizedBox(height: 16),
              Text(c.activeInfo.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('برای ورود رمز را وارد کنید'),
              const SizedBox(height: 20),
              TextField(
                controller: pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: AppLock.maxLength,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9۰-۹٠-٩]'))],
                onSubmitted: (_) => _try(),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.lock_outline), counterText: '', errorText: error),
              ),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _try, child: const Text('ورود'))),
              if (c.companies.length > 1) ...[
                const SizedBox(height: 16),
                PopupMenuButton<String>(
                  onSelected: c.switchTo,
                  itemBuilder: (_) => [for (final x in c.companies) PopupMenuItem(value: x.id, child: Text(x.name))],
                  child: const Padding(padding: EdgeInsets.all(8), child: Text('ورود به شرکت دیگر')),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
