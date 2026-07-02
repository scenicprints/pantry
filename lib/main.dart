import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'food_lookup.dart';
import 'github_sync.dart';
import 'label_parser.dart';
import 'models.dart';
import 'storage.dart';
import 'updater.dart';

// ═══════════════════════════════════════════════════════════════════════
// PANTRY — inventory & cost tracker. Scans groceries, tracks remaining
// weight + cost, and syncs pantry.json to GitHub for the AI chef to read.
// ═══════════════════════════════════════════════════════════════════════

const Color kBg = Color(0xFF0E0F12);
const Color kCard = Color(0xFF1A1A1A);
const Color kBorder = Color(0xFF232323);
const Color kAccent = Color(0xFF6FCF97); // fresh green
const Color kWarn = Color(0xFFE0A458); // amber for expiring

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalCache.init();
  runApp(const PantryApp());
}

class PantryApp extends StatelessWidget {
  const PantryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pantry',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kCard,
        ),
        fontFamily: 'Roboto',
      ),
      home: const HomePage(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ROOT STATE — owns the pantry, persists locally, syncs to GitHub.
// ═══════════════════════════════════════════════════════════════════════

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<PantryItem> _items = <PantryItem>[];
  List<QuickAddItem> _quick = <QuickAddItem>[];
  int _tab = 0;
  bool _syncing = false;
  String _syncMsg = '';

  @override
  void initState() {
    super.initState();
    final PantryData d = LocalCache.load();
    _items = d.pantry;
    _quick = d.quickAdd;
    _syncFromRemote();
  }

  PantryData get _data => PantryData(pantry: _items, quickAdd: _quick);

  // Pull the newest remote file and merge it in (remote may have been edited
  // elsewhere; local has anything not yet pushed).
  Future<void> _syncFromRemote() async {
    setState(() {
      _syncing = true;
      _syncMsg = '';
    });
    final RemotePantry? remote = await PantrySync.fetch();
    if (!mounted) {
      return;
    }
    if (remote == null) {
      setState(() {
        _syncing = false;
        _syncMsg = 'Offline — showing local copy.';
      });
      return;
    }
    final PantryData merged = PantryData.merge(remote.data, _data);
    LocalCache.save(merged, DateTime.now());
    setState(() {
      _items = merged.pantry;
      _quick = merged.quickAdd;
      _syncing = false;
      _syncMsg = PantrySync.canWrite ? '' : 'Read-only — write token not set.';
    });
  }

  // Every change: stamp, save locally, then merge-push to GitHub in the
  // background. On success we adopt whatever is now live (keeps ids/merges
  // consistent). On failure the local copy stands and syncs next time.
  Future<void> _mutate(void Function() change) async {
    setState(change);
    final DateTime now = DateTime.now();
    LocalCache.save(_data, now);
    if (!PantrySync.canWrite) {
      return;
    }
    setState(() => _syncing = true);
    final PantryData? live = await PantrySync.push(_data, now);
    if (!mounted) {
      return;
    }
    setState(() {
      if (live != null) {
        _items = live.pantry;
        _quick = live.quickAdd;
      }
      _syncing = false;
      _syncMsg = live == null ? 'Change saved locally — will sync later.' : '';
    });
  }

  // ── mutations ─────────────────────────────────────────────────────────

  void _addItem(PantryItem item) => _mutate(() => _items.add(item));

  void _replaceItem(PantryItem item) => _mutate(() {
        final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
        if (i >= 0) {
          _items[i] = item;
        }
      });

  void _deleteItem(PantryItem item) =>
      _mutate(() => _items.removeWhere((PantryItem x) => x.id == item.id));

  void _logUsage(PantryItem item, double gramsUsed) => _mutate(() {
        final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
        if (i < 0) {
          return;
        }
        final double left = (_items[i].remainingWeightG - gramsUsed);
        _items[i].remainingWeightG = left < 0 ? 0 : left;
        _items[i].updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      });

  void _saveQuickAdd(PantryItem item) => _mutate(() {
        _quick.removeWhere(
            (QuickAddItem q) => q.name.toLowerCase() == item.name.toLowerCase());
        _quick.add(QuickAddItem(
          name: item.name,
          barcode: item.barcode,
          lastPrice: item.price,
          macrosPer100g: item.macrosPer100g,
          lastTotalWeightG: item.totalWeightG,
        ));
      });

  void _deleteQuickAdd(QuickAddItem q) =>
      _mutate(() => _quick.removeWhere((QuickAddItem x) => x.name == q.name));

  // ── add flows ─────────────────────────────────────────────────────────

  Future<void> _startAdd({AddPrefill? prefill}) async {
    final PantryItem? made = await Navigator.of(context).push(
      MaterialPageRoute<PantryItem>(
        builder: (_) => AddItemPage(prefill: prefill),
      ),
    );
    if (made != null) {
      _addItem(made);
    }
  }

  Future<void> _addByBarcode() async {
    final String? code = await Navigator.of(context).push(
      MaterialPageRoute<String>(builder: (_) => const ScanPage()),
    );
    if (code == null || !mounted) {
      return;
    }
    _showLoader('Looking up barcode…');
    ProductInfo? info;
    try {
      info = await OpenFoodFacts.fetchByBarcode(code);
    } catch (_) {}
    if (!mounted) {
      return;
    }
    Navigator.pop(context); // dismiss loader
    if (info == null) {
      _snack("Barcode not found — enter it by hand.");
      _startAdd(prefill: AddPrefill(barcode: code));
      return;
    }
    _startAdd(
      prefill: AddPrefill(
        name: info.name,
        barcode: info.barcode ?? code,
        macros: info.macrosPer100g,
        totalWeightG: info.packGrams,
      ),
    );
  }

  Future<void> _addByLabel() async {
    XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
          source: ImageSource.camera, maxWidth: 2200, imageQuality: 92);
    } catch (_) {}
    if (shot == null || !mounted) {
      return;
    }
    _showLoader('Reading label…');
    String text = '';
    final TextRecognizer recognizer =
        TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final RecognizedText r =
          await recognizer.processImage(InputImage.fromFilePath(shot.path));
      text = r.text;
    } catch (_) {
    } finally {
      await recognizer.close();
    }
    if (!mounted) {
      return;
    }
    Navigator.pop(context); // dismiss loader
    final LabelParse parse = parseNutritionLabel(text);
    if (!parse.hasAnything) {
      _snack("Couldn't read the label — fill it in or retake the photo.");
      _startAdd();
      return;
    }
    final per100 = parse.toPer100g();
    _startAdd(
      prefill: AddPrefill(
        macros: per100 == null
            ? Macros(
                proteinG: parse.protein ?? 0,
                calories: parse.calories ?? 0,
                carbsG: parse.carbs ?? 0,
                fatG: parse.fat ?? 0,
              )
            : Macros(
                proteinG: per100.proteinG ?? 0,
                calories: per100.calories ?? 0,
                carbsG: per100.carbsG ?? 0,
                fatG: per100.fatG ?? 0,
              ),
        macrosNote: per100 == null
            ? 'Label was per serving and serving grams were not read — '
                'these numbers are per serving; correct them to per 100 g.'
            : null,
      ),
    );
  }

  Future<void> _reAdd(QuickAddItem q) async {
    _startAdd(
      prefill: AddPrefill(
        name: q.name,
        barcode: q.barcode,
        macros: q.macrosPer100g,
        price: q.lastPrice,
        totalWeightG: q.lastTotalWeightG,
      ),
    );
  }

  // ── shared UI helpers ─────────────────────────────────────────────────

  void _showLoader(String msg) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(14)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: kAccent),
            const SizedBox(height: 14),
            Text(msg, style: const TextStyle(color: Colors.white70)),
          ]),
        ),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF2A2A2A), content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      PantryTab(
        items: _items,
        onTapItem: _openItem,
        onAddBarcode: _addByBarcode,
        onAddLabel: _addByLabel,
        onAddManual: () => _startAdd(),
      ),
      QuickAddTab(
        quick: _quick,
        onReAdd: _reAdd,
        onDelete: _deleteQuickAdd,
      ),
      SettingsTab(
        syncing: _syncing,
        onSyncNow: _syncFromRemote,
        itemCount: _items.length,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Row(children: [
          const Icon(Icons.kitchen_rounded, color: kAccent, size: 22),
          const SizedBox(width: 8),
          const Text('Pantry',
              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          const Spacer(),
          if (_syncing)
            const SizedBox(
                width: 16,
                height: 16,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
        ]),
        bottom: _syncMsg.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Container(
                  width: double.infinity,
                  color: const Color(0xFF201A12),
                  padding:
                      const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
                  child: Text(_syncMsg,
                      style: const TextStyle(fontSize: 11, color: kWarn)),
                ),
              ),
      ),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        backgroundColor: kCard,
        indicatorColor: kAccent.withValues(alpha: 0.18),
        selectedIndex: _tab,
        onDestinationSelected: (int i) => setState(() => _tab = i),
        destinations: const <NavigationDestination>[
          NavigationDestination(
              icon: Icon(Icons.list_alt_rounded), label: 'Pantry'),
          NavigationDestination(
              icon: Icon(Icons.bolt_rounded), label: 'Quick-Add'),
          NavigationDestination(
              icon: Icon(Icons.settings_rounded), label: 'Settings'),
        ],
      ),
    );
  }

  void _openItem(PantryItem item) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => ItemSheet(
        item: item,
        onLogUsage: (double g) {
          Navigator.pop(context);
          _logUsage(item, g);
        },
        onEdit: () async {
          Navigator.pop(context);
          final PantryItem? edited = await Navigator.of(context).push(
            MaterialPageRoute<PantryItem>(
              builder: (_) => AddItemPage(existing: item),
            ),
          );
          if (edited != null) {
            _replaceItem(edited);
          }
        },
        onDelete: () {
          Navigator.pop(context);
          _deleteItem(item);
        },
        onSaveQuickAdd: () {
          Navigator.pop(context);
          _saveQuickAdd(item);
          _snack('${item.name} saved to Quick-Add.');
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// PANTRY TAB
// ═══════════════════════════════════════════════════════════════════════

class PantryTab extends StatelessWidget {
  final List<PantryItem> items;
  final void Function(PantryItem) onTapItem;
  final VoidCallback onAddBarcode;
  final VoidCallback onAddLabel;
  final VoidCallback onAddManual;

  const PantryTab({
    super.key,
    required this.items,
    required this.onTapItem,
    required this.onAddBarcode,
    required this.onAddLabel,
    required this.onAddManual,
  });

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    // Expiring first, then alphabetical.
    final List<PantryItem> sorted = <PantryItem>[...items]..sort((a, b) {
        final bool ea = a.isExpiringSoon(now), eb = b.isExpiringSoon(now);
        if (ea != eb) {
          return ea ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kAccent,
        foregroundColor: Colors.black,
        onPressed: () => _showAddMenu(context),
        icon: const Icon(Icons.add),
        label: const Text('Add', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: sorted.isEmpty
          ? _empty()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: sorted.length,
              itemBuilder: (_, int i) =>
                  _row(context, sorted[i], now),
            ),
    );
  }

  Widget _empty() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.kitchen_outlined, size: 54, color: Colors.grey[700]),
          const SizedBox(height: 14),
          Text('Your pantry is empty.',
              style: TextStyle(color: Colors.grey[500], fontSize: 15)),
          const SizedBox(height: 4),
          Text('Tap Add to scan your first item.',
              style: TextStyle(color: Colors.grey[700], fontSize: 13)),
        ]),
      );

  Widget _row(BuildContext context, PantryItem it, DateTime now) {
    final bool expiring = it.isExpiringSoon(now);
    final double pct = it.totalWeightG > 0
        ? (it.remainingWeightG / it.totalWeightG).clamp(0, 1)
        : 0;
    return GestureDetector(
      onTap: () => onTapItem(it),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: expiring ? kWarn.withValues(alpha: 0.5) : kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(it.name,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (expiring)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: kWarn.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20)),
                child: const Text('EXPIRING',
                    style: TextStyle(
                        fontSize: 9,
                        color: kWarn,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6)),
              ),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct.toDouble(),
              minHeight: 5,
              backgroundColor: const Color(0xFF111111),
              valueColor: AlwaysStoppedAnimation<Color>(
                  expiring ? kWarn : kAccent),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('${_fmt(it.remainingWeightG)} / ${_fmt(it.totalWeightG)} g',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
            const Spacer(),
            Text(
                '\$${it.price.toStringAsFixed(2)}  ·  '
                '\$${it.pricePerGram.toStringAsFixed(4)}/g',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ]),
          if (it.expirationDate != null && it.expirationDate!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Expires ${it.expirationDate}',
                style: TextStyle(
                    fontSize: 11,
                    color: expiring ? kWarn : Colors.grey[600])),
          ],
        ]),
      ),
    );
  }

  void _showAddMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          _menuTile(context, Icons.qr_code_scanner_rounded, 'Scan barcode',
              'Look up macros from Open Food Facts', () {
            Navigator.pop(context);
            onAddBarcode();
          }),
          _menuTile(context, Icons.document_scanner_rounded,
              'Scan nutrition label', 'Read macros with the camera (OCR)', () {
            Navigator.pop(context);
            onAddLabel();
          }),
          _menuTile(context, Icons.edit_rounded, 'Enter manually',
              'Type it all in yourself', () {
            Navigator.pop(context);
            onAddManual();
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _menuTile(BuildContext context, IconData icon, String title,
      String sub, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: kAccent),
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(sub, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      onTap: onTap,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ITEM SHEET — log usage / edit / delete / save as quick-add
// ═══════════════════════════════════════════════════════════════════════

class ItemSheet extends StatefulWidget {
  final PantryItem item;
  final void Function(double gramsUsed) onLogUsage;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSaveQuickAdd;

  const ItemSheet({
    super.key,
    required this.item,
    required this.onLogUsage,
    required this.onEdit,
    required this.onDelete,
    required this.onSaveQuickAdd,
  });

  @override
  State<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<ItemSheet> {
  final TextEditingController _used = TextEditingController();

  @override
  void dispose() {
    _used.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PantryItem it = widget.item;
    final Macros m = it.macrosPer100g;
    return Padding(
      padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 18,
          bottom: MediaQuery.of(context).viewInsets.bottom + 18),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: kBorder, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(it.name,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
              '${_fmt(it.remainingWeightG)} g left of ${_fmt(it.totalWeightG)} g',
              style: TextStyle(color: Colors.grey[500], fontSize: 13)),
        ),
        const SizedBox(height: 12),
        Row(children: [
          _macro('P', m.proteinG),
          _macro('Cal', m.calories),
          _macro('C', m.carbsG),
          _macro('F', m.fatG),
        ]),
        const SizedBox(height: 18),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text('LOG USAGE',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _used,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
              ],
              decoration: _dec('grams used'),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: () {
              final double g = double.tryParse(_used.text.trim()) ?? 0;
              if (g > 0) {
                widget.onLogUsage(g);
              }
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Subtract',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: widget.onSaveQuickAdd,
              icon: const Icon(Icons.bolt_rounded, size: 18),
              label: const Text('Quick-Add'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: kAccent,
                  side: BorderSide(color: kAccent.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 12)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Edit'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.grey[300],
                  side: const BorderSide(color: kBorder),
                  padding: const EdgeInsets.symmetric(vertical: 12)),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            onPressed: widget.onDelete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: const Color(0xFFCC6B6B),
          ),
        ]),
      ]),
    );
  }

  Widget _macro(String label, double v) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
              color: kBg, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(v.toStringAsFixed(v >= 100 ? 0 : 1),
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text(label,
                style: TextStyle(fontSize: 10, color: Colors.grey[500])),
          ]),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════
// ADD / EDIT ITEM
// ═══════════════════════════════════════════════════════════════════════

/// Values to pre-fill the Add form with (from a scan or a quick-add).
class AddPrefill {
  final String? name;
  final String? barcode;
  final Macros? macros;
  final double? totalWeightG;
  final double? price;
  final String? macrosNote; // shown as a warning under the macro fields

  const AddPrefill({
    this.name,
    this.barcode,
    this.macros,
    this.totalWeightG,
    this.price,
    this.macrosNote,
  });
}

class AddItemPage extends StatefulWidget {
  final AddPrefill? prefill;
  final PantryItem? existing;
  const AddItemPage({super.key, this.prefill, this.existing});

  @override
  State<AddItemPage> createState() => _AddItemPageState();
}

class _AddItemPageState extends State<AddItemPage> {
  late final TextEditingController _name;
  late final TextEditingController _barcode;
  late final TextEditingController _protein;
  late final TextEditingController _calories;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;
  late final TextEditingController _total;
  late final TextEditingController _price;
  String? _expiration; // 'YYYY-MM-DD'
  String? _note;

  @override
  void initState() {
    super.initState();
    final PantryItem? e = widget.existing;
    final AddPrefill? p = widget.prefill;
    final Macros m = e?.macrosPer100g ?? p?.macros ?? const Macros();
    _name = TextEditingController(text: e?.name ?? p?.name ?? '');
    _barcode = TextEditingController(text: e?.barcode ?? p?.barcode ?? '');
    _protein = TextEditingController(text: _pf(m.proteinG));
    _calories = TextEditingController(text: _pf(m.calories));
    _carbs = TextEditingController(text: _pf(m.carbsG));
    _fat = TextEditingController(text: _pf(m.fatG));
    _total = TextEditingController(
        text: _pf(e?.totalWeightG ?? p?.totalWeightG ?? 0));
    _price = TextEditingController(text: _pf(e?.price ?? p?.price ?? 0));
    _expiration = e?.expirationDate;
    _note = p?.macrosNote;
  }

  static String _pf(double? v) =>
      (v == null || v == 0) ? '' : _fmt(v);

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name, _barcode, _protein, _calories, _carbs, _fat, _total, _price
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  void _save() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Color(0xFF2A2A2A),
          content: Text('Give the item a name.')));
      return;
    }
    final double total = _d(_total);
    final Macros macros = Macros(
      proteinG: _d(_protein),
      calories: _d(_calories),
      carbsG: _d(_carbs),
      fatG: _d(_fat),
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final String today = _todayStr();

    final PantryItem? e = widget.existing;
    final PantryItem item = PantryItem(
      id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      totalWeightG: total,
      // On edit, keep whatever is remaining unless total shrank below it.
      remainingWeightG: e == null
          ? total
          : (e.remainingWeightG > total ? total : e.remainingWeightG),
      price: _d(_price),
      macrosPer100g: macros,
      expirationDate: _expiration,
      dateAdded: e?.dateAdded ?? today,
      lastPrice: _d(_price),
      updatedAtMs: nowMs,
    );
    Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final bool editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(editing ? 'Edit item' : 'Add item'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _field('Name', _name, hint: 'e.g. ground turkey'),
          _field('Barcode (optional)', _barcode,
              hint: 'digits', number: false),
          const SizedBox(height: 10),
          _sectionLabel('MACROS — per 100 g'),
          Row(children: [
            Expanded(child: _numField('Protein g', _protein)),
            const SizedBox(width: 10),
            Expanded(child: _numField('Calories', _calories)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _numField('Carbs g', _carbs)),
            const SizedBox(width: 10),
            Expanded(child: _numField('Fat g', _fat)),
          ]),
          if (_note != null) ...[
            const SizedBox(height: 8),
            Text(_note!,
                style: const TextStyle(fontSize: 12, color: kWarn)),
          ],
          const SizedBox(height: 16),
          _sectionLabel('AMOUNT & COST'),
          Row(children: [
            Expanded(child: _numField('Total weight g', _total)),
            const SizedBox(width: 10),
            Expanded(child: _numField('Price \$', _price)),
          ]),
          const SizedBox(height: 6),
          _pricePerGramPreview(),
          const SizedBox(height: 16),
          _sectionLabel('EXPIRATION (optional)'),
          _expirationPickerRow(),
          const SizedBox(height: 26),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: Text(editing ? 'Save changes' : 'Add to pantry',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pricePerGramPreview() {
    final double total = _d(_total);
    final double price = _d(_price);
    final double ppg = total > 0 ? price / total : 0;
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
          total > 0
              ? 'Price per gram: \$${ppg.toStringAsFixed(4)}/g'
              : 'Enter total weight to compute price per gram.',
          style: TextStyle(fontSize: 12, color: Colors.grey[500])),
    );
  }

  Widget _expirationPickerRow() {
    return Row(children: [
      Expanded(
        child: Text(_expiration ?? 'No expiration set',
            style: TextStyle(
                color: _expiration == null ? Colors.grey[600] : Colors.white)),
      ),
      if (_expiration != null)
        TextButton(
          onPressed: () => setState(() => _expiration = null),
          child: const Text('Clear', style: TextStyle(color: Color(0xFFCC6B6B))),
        ),
      OutlinedButton.icon(
        onPressed: _pickDate,
        icon: const Icon(Icons.event_rounded, size: 18),
        label: const Text('Pick date'),
        style: OutlinedButton.styleFrom(
            foregroundColor: kAccent,
            side: BorderSide(color: kAccent.withValues(alpha: 0.4))),
      ),
    ]);
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      builder: (BuildContext ctx, Widget? child) => Theme(
        data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.dark(
                primary: kAccent, onPrimary: Colors.black, surface: kCard)),
        child: child!,
      ),
    );
    if (d != null) {
      setState(() => _expiration =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
  }

  Widget _sectionLabel(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(s,
            style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                letterSpacing: 1,
                fontWeight: FontWeight.w600)),
      );

  Widget _field(String label, TextEditingController c,
      {String? hint, bool number = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: _dec(hint ?? label, label: label),
      ),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: (_) => setState(() {}), // refresh price-per-gram preview
      decoration: _dec(label, label: label),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// QUICK-ADD TAB
// ═══════════════════════════════════════════════════════════════════════

class QuickAddTab extends StatelessWidget {
  final List<QuickAddItem> quick;
  final void Function(QuickAddItem) onReAdd;
  final void Function(QuickAddItem) onDelete;

  const QuickAddTab({
    super.key,
    required this.quick,
    required this.onReAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (quick.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bolt_outlined, size: 54, color: Colors.grey[700]),
          const SizedBox(height: 14),
          Text('No quick-add items yet.',
              style: TextStyle(color: Colors.grey[500], fontSize: 15)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
                'Open any pantry item and tap “Quick-Add” to save it here for one-tap re-adding.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[700], fontSize: 13)),
          ),
        ]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: quick.length,
      itemBuilder: (_, int i) {
        final QuickAddItem q = quick[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: ListTile(
            title: Text(q.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                'Last \$${q.lastPrice.toStringAsFixed(2)}'
                '${q.macrosPer100g.proteinG > 0 ? '  ·  ${_fmt(q.macrosPer100g.proteinG)}g protein/100g' : ''}',
                style: TextStyle(color: Colors.grey[500], fontSize: 12)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                onPressed: () => onDelete(q),
                icon: const Icon(Icons.close_rounded, size: 18),
                color: Colors.grey[600],
              ),
              FilledButton(
                onPressed: () => onReAdd(q),
                style: FilledButton.styleFrom(
                    backgroundColor: kAccent, foregroundColor: Colors.black),
                child: const Text('Re-add',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SETTINGS TAB
// ═══════════════════════════════════════════════════════════════════════

class SettingsTab extends StatelessWidget {
  final bool syncing;
  final VoidCallback onSyncNow;
  final int itemCount;

  const SettingsTab({
    super.key,
    required this.syncing,
    required this.onSyncNow,
    required this.itemCount,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GITHUB SYNC',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                    letterSpacing: 1,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(children: [
              Icon(
                  PantrySync.canWrite
                      ? Icons.cloud_done_rounded
                      : Icons.cloud_off_rounded,
                  size: 18,
                  color: PantrySync.canWrite ? kAccent : kWarn),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    PantrySync.canWrite
                        ? 'Writing to $kDataRepoOwner/$kDataRepoName → $kPantryPath'
                        : 'Read-only build — write token not configured.',
                    style: TextStyle(fontSize: 13, color: Colors.grey[300])),
              ),
            ]),
            const SizedBox(height: 6),
            Text('$itemCount items tracked',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: syncing ? null : onSyncNow,
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: Text(syncing ? 'Syncing…' : 'Sync now'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: kAccent,
                    side: BorderSide(color: kAccent.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(vertical: 12)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        const UpdateCard(accent: kAccent),
        const SizedBox(height: 20),
        Center(
          child: Text('Pantry — feeds the AI chef',
              style: TextStyle(color: Colors.grey[700], fontSize: 12)),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// BARCODE SCANNER
// ═══════════════════════════════════════════════════════════════════════

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates, formats: <BarcodeFormat>[
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
    BarcodeFormat.code128,
  ]);
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) {
      return;
    }
    for (final Barcode b in capture.barcodes) {
      final String? code = b.rawValue;
      if (code != null && code.isNotEmpty) {
        _handled = true;
        Navigator.pop(context, code);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Scan barcode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Stack(children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 260,
            height: 160,
            decoration: BoxDecoration(
                border: Border.all(color: kAccent, width: 3),
                borderRadius: BorderRadius.circular(16)),
          ),
        ),
        Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Text('Point at a product barcode',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400])),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SHARED HELPERS
// ═══════════════════════════════════════════════════════════════════════

/// Format grams/weights: no decimals when whole, one otherwise.
String _fmt(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

String _todayStr() {
  final DateTime n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

InputDecoration _dec(String hint, {String? label}) => InputDecoration(
      hintText: hint,
      labelText: label,
      labelStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
      hintStyle: TextStyle(color: Colors.grey[700]),
      filled: true,
      fillColor: kCard,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kBorder)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kAccent)),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kBorder)),
    );
