import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ota_update/ota_update.dart';

// ═══════════════════════════════════════════════════════════════════════
// IN-APP OTA UPDATER — checks the latest GitHub Release for this repo,
// compares versions, and downloads + installs the newer APK. The code repo
// is public, so the releases API needs no token. (Same as BodyComp.)
// ═══════════════════════════════════════════════════════════════════════

const String kRepoOwner = 'scenicprints';
const String kRepoName = 'pantry';

class ReleaseInfo {
  final String version; // tag minus any leading "v"
  final String notes; // release body — "What's New"
  final String apkUrl; // direct download URL of the .apk asset

  ReleaseInfo(
      {required this.version, required this.notes, required this.apkUrl});
}

class Updater {
  static Future<String> currentVersion() async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static Future<ReleaseInfo?> fetchLatest() async {
    final Uri uri = Uri.parse(
        'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest');
    final http.Response resp = await http
        .get(uri, headers: <String, String>{'Accept': 'application/vnd.github+json'});
    if (resp.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final String tag = (data['tag_name'] as String?) ?? '';
    final String version = tag.replaceFirst(RegExp(r'^v'), '');
    final String notes = ((data['body'] as String?) ?? '').trim();

    String? apkUrl;
    for (final dynamic a in (data['assets'] as List<dynamic>? ?? <dynamic>[])) {
      final Map<String, dynamic> m = a as Map<String, dynamic>;
      final String name = (m['name'] as String?) ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        apkUrl = m['browser_download_url'] as String?;
        break;
      }
    }
    if (version.isEmpty || apkUrl == null) {
      return null;
    }
    return ReleaseInfo(version: version, notes: notes, apkUrl: apkUrl);
  }

  /// True if [a] is a strictly higher semantic version than [b].
  static bool isNewer(String a, String b) {
    final List<int> pa = _parse(a), pb = _parse(b);
    for (int i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) {
        return pa[i] > pb[i];
      }
    }
    return false;
  }

  static List<int> _parse(String v) {
    final List<String> parts = v.split('.');
    return List<int>.generate(
        3,
        (int i) => i < parts.length
            ? (int.tryParse(parts[i].split('+').first) ?? 0)
            : 0);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// UPDATE CARD — drop-in widget for the Settings screen.
// ═══════════════════════════════════════════════════════════════════════

enum _State { idle, checking, upToDate, available, downloading, error }

class UpdateCard extends StatefulWidget {
  final Color accent;
  const UpdateCard({super.key, required this.accent});
  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  _State _s = _State.idle;
  String _current = '';
  ReleaseInfo? _release;
  String _msg = '';
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    Updater.currentVersion().then((String v) {
      if (mounted) {
        setState(() => _current = v);
      }
    });
  }

  Future<void> _check() async {
    setState(() {
      _s = _State.checking;
      _msg = '';
    });
    try {
      final ReleaseInfo? r = await Updater.fetchLatest();
      if (!mounted) {
        return;
      }
      if (r == null) {
        setState(() {
          _s = _State.error;
          _msg = 'No published release found yet.';
        });
        return;
      }
      if (Updater.isNewer(r.version, _current)) {
        setState(() {
          _release = r;
          _s = _State.available;
        });
      } else {
        setState(() => _s = _State.upToDate);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _s = _State.error;
        _msg = 'Check failed. Are you online?';
      });
    }
  }

  void _install() {
    final ReleaseInfo? r = _release;
    if (r == null) {
      return;
    }
    setState(() {
      _s = _State.downloading;
      _progress = 0;
    });
    try {
      OtaUpdate()
          .execute(r.apkUrl, destinationFilename: 'pantry-${r.version}.apk')
          .listen((OtaEvent event) {
        if (!mounted) {
          return;
        }
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            setState(() => _progress = int.tryParse(event.value ?? '0') ?? 0);
            break;
          case OtaStatus.INSTALLING:
          case OtaStatus.INSTALLATION_DONE:
            break;
          case OtaStatus.CANCELED:
            setState(() => _s = _State.available);
            break;
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            setState(() {
              _s = _State.error;
              _msg = 'Allow "install unknown apps" for Pantry, then retry.';
            });
            break;
          case OtaStatus.ALREADY_RUNNING_ERROR:
            setState(() {
              _s = _State.error;
              _msg = 'An update is already in progress.';
            });
            break;
          case OtaStatus.DOWNLOAD_ERROR:
          case OtaStatus.CHECKSUM_ERROR:
          case OtaStatus.INSTALLATION_ERROR:
          case OtaStatus.INTERNAL_ERROR:
            setState(() {
              _s = _State.error;
              _msg = 'Download failed: ${event.value ?? ''}';
            });
            break;
        }
      });
    } catch (e) {
      setState(() {
        _s = _State.error;
        _msg = 'Could not start update.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF232323))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('APP UPDATES',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
          Text(_current.isEmpty ? '' : 'v$_current',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ]),
        const SizedBox(height: 12),
        _body(),
      ]),
    );
  }

  Widget _body() {
    final Color accent = widget.accent;
    switch (_s) {
      case _State.checking:
        return Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
          const SizedBox(width: 12),
          Text('Checking for updates…',
              style: TextStyle(fontSize: 13, color: Colors.grey[400])),
        ]);

      case _State.downloading:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Downloading update… $_progress%',
              style: TextStyle(fontSize: 13, color: Colors.grey[300])),
          const SizedBox(height: 8),
          ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF111111),
                  valueColor: AlwaysStoppedAnimation<Color>(accent))),
          const SizedBox(height: 8),
          Text("The installer will open automatically when it's ready.",
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ]);

      case _State.available:
        final ReleaseInfo r = _release!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Update available — v${r.version}',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: accent)),
          if (r.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text("WHAT'S NEW",
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[600],
                    letterSpacing: 1,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(r.notes,
                style: TextStyle(
                    fontSize: 13, color: Colors.grey[300], height: 1.5)),
          ],
          const SizedBox(height: 14),
          SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                  onPressed: _install,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10))),
                  child: const Text('Download & Install',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)))),
        ]);

      case _State.upToDate:
        return Row(children: [
          Icon(Icons.check_circle_rounded, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
              child: Text("You're on the latest version.",
                  style: TextStyle(fontSize: 13, color: Colors.grey[300]))),
          _checkButton('Re-check'),
        ]);

      case _State.error:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_msg,
              style: const TextStyle(fontSize: 13, color: Color(0xFFCC8855))),
          const SizedBox(height: 10),
          _checkButton('Retry'),
        ]);

      case _State.idle:
        return Row(children: [
          Expanded(
              child: Text('Check GitHub for a newer build.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500]))),
          _checkButton('Check'),
        ]);
    }
  }

  Widget _checkButton(String label) {
    return OutlinedButton(
        onPressed: _check,
        style: OutlinedButton.styleFrom(
            foregroundColor: widget.accent,
            side: BorderSide(
                color: Color.fromRGBO(
                    (widget.accent.r * 255).round(),
                    (widget.accent.g * 255).round(),
                    (widget.accent.b * 255).round(),
                    0.4)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8))),
        child: Text(label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)));
  }
}
