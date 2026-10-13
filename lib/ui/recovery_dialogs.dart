import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_lock.dart';
import '../util/format.dart';

/// Shows a recovery key once. The dialog cannot be closed until the person
/// confirms they saved it, because only its hash is kept.
Future<void> showRecoveryKey(BuildContext context, String key, {String title = 'کلید بازیابی رمز'}) {
  var saved = false;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('اگر رمز را فراموش کردید، فقط با این کلید می‌توانید رمز تازه بسازید. آن را روی کاغذ بنویسید یا در یک مدیر رمز نگه دارید، نه روی همین دستگاه. این کلید دیگر نمایش داده نمی‌شود.'),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(color: Theme.of(dc).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(key, textAlign: TextAlign.center, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: key));
                  if (dc.mounted) ScaffoldMessenger.of(dc).showSnackBar(const SnackBar(content: Text('کپی شد.')));
                },
                icon: const Icon(Icons.copy),
                label: const Text('کپی'),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: saved,
              onChanged: (v) => set(() => saved = v ?? false),
              title: const Text('کلید را در جای امن نوشتم'),
            ),
          ]),
        ),
        actions: [FilledButton(onPressed: saved ? () => Navigator.pop(dc) : null, child: const Text('بستن'))],
      ),
    ),
  );
}

/// Asks for the recovery key (or the owner's master phrase) and a new PIN.
/// Returns true when the PIN was reset (the app is unlocked and a new key was shown).
Future<bool> showRecoverPin(BuildContext context, AppLock lock, String companyId) async {
  final key = TextEditingController(), a = TextEditingController(), b = TextEditingController();
  String? err;
  final newKey = await showDialog<String>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: const Text('بازیابی رمز'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!lock.hasRecoveryKey(companyId) && !lock.masterEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'برای این رمز کلید بازیابی ساخته نشده بود. راه‌های دیگر (اسکریپت بازنشانی قفل یا پشتیبان) در راهنمای برنامه (README) توضیح داده شده است.',
                    style: TextStyle(color: Theme.of(dc).colorScheme.error),
                  ),
                ),
              TextField(controller: key, textDirection: TextDirection.ltr, autofocus: true, decoration: InputDecoration(labelText: lock.masterEnabled ? 'کلید بازیابی یا کلید مالک' : 'کلید بازیابی', hintText: 'XXXX-XXXX-XXXX-XXXX')),
              const SizedBox(height: 10),
              TextField(controller: a, obscureText: true, keyboardType: TextInputType.number, maxLength: AppLock.maxLength, decoration: const InputDecoration(labelText: 'رمز جدید (۴ تا ۸ رقم)', counterText: '')),
              const SizedBox(height: 10),
              TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: AppLock.maxLength, decoration: const InputDecoration(labelText: 'تکرار رمز جدید', counterText: '')),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(err!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              final pin = enDigits(a.text.trim());
              if (!AppLock.validPin(pin)) return set(() => err = 'رمز باید ۴ تا ۸ رقم باشد.');
              if (pin != enDigits(b.text.trim())) return set(() => err = 'تکرار رمز یکسان نیست.');
              final k = await lock.recover(companyId, key.text, pin);
              if (k != null) {
                if (dc.mounted) Navigator.pop(dc, k);
              } else {
                set(() => err = lock.waitSeconds > 0
                    ? 'چند بار اشتباه زدید. ${faDigits('${lock.waitSeconds}')} ثانیه دیگر دوباره امتحان کنید.'
                    : 'کلید اشتباه است.');
              }
            },
            child: const Text('تغییر رمز'),
          ),
        ],
      ),
    ),
  );
  if (newKey == null) return false;
  if (context.mounted) await showRecoveryKey(context, newKey, title: 'کلید بازیابی تازه');
  return true;
}
