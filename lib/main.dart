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
// amount + cost, and syncs pantry.json to GitHub for the AI chef to read.
// ═══════════════════════════════════════════════════════════════════════

const Color kBg = Color(0xFF0E0F12);
const Color kCard = Color(0xFF1A1A1A);
const Color kBorder = Color(0xFF232323);
const Color kAccent = Color(0xFF6FCF97); // fresh green
const Color kWarn = Color(0xFFE0A458); // amber for expiring
const Color kDanger = Color(0xFFCC6B6B);

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
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kCard),
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

  // Deletes are tombstoned (not removed) so they propagate through the merge
  // instead of being resurrected from the remote copy on the next sync.
  void _deleteItem(PantryItem item) => _mutate(() {
        final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
        if (i >= 0) {
          _items[i].deleted = true;
          _items[i].updatedAtMs = DateTime.now().millisecondsSinceEpoch;
        }
      });

  /// Adjust remaining amount. [add] true = bought more (raises remaining and,
  /// if it would exceed total, total too). false = used some (clamps at 0).
  void _adjust(PantryItem item, double amount, bool add) => _mutate(() {
        final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
        if (i < 0) {
          return;
        }
        final PantryItem it = _items[i];
        if (add) {
          it.remaining += amount;
          it.total += amount;
        } else {
          final double left = it.remaining - amount;
          it.remaining = left < 0 ? 0 : left;
        }
        it.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
      });

  void _saveQuickAdd(PantryItem item) => _mutate(() {
        _quick.removeWhere(
            (QuickAddItem q) => q.name.toLowerCase() == item.name.toLowerCase());
        _quick.add(QuickAddItem(
          name: item.name,
          barcode: item.barcode,
          unit: item.unit,
          lastPrice: item.price,
          macros: item.macros,
          servingSize: item.servingSize,
          servingUnit: item.servingUnit,
          lastTotal: item.total,
        ));
      });

  void _deleteQuickAdd(QuickAddItem q) => _mutate(() {
        final int i = _quick.indexWhere((QuickAddItem x) => x.name == q.name);
        if (i >= 0) {
          _quick[i].deleted = true;
        }
      });

  // ── add flows ─────────────────────────────────────────────────────────

  Future<void> _startAdd({AddPrefill? prefill}) async {
    final PantryItem? made = await Navigator.of(context).push(
      MaterialPageRoute<PantryItem>(builder: (_) => AddItemPage(prefill: prefill)),
    );
    if (made != null) {
      _addItem(made);
    }
  }

  Future<void> _addByBarcode() async {
    final String? code = await Navigator.of(context)
        .push(MaterialPageRoute<String>(builder: (_) => const ScanPage()));
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
    Navigator.pop(context);
    if (info == null) {
      _snack("Barcode not found — enter it by hand.");
      _startAdd(prefill: AddPrefill(barcode: code));
      return;
    }
    // Open Food Facts gives per-100 g. Convert to per-serving using the
    // product's serving grams when known; otherwise present a 100 g serving.
    final double sg = (info.servingGrams != null && info.servingGrams! > 0)
        ? info.servingGrams!
        : 100;
    _startAdd(
      prefill: AddPrefill(
        name: info.name,
        barcode: info.barcode ?? code,
        macros: info.macrosPer100g.scale(sg / 100),
        servingSize: sg,
        servingUnit: 'g',
        total: info.packGrams,
      ),
    );
  }

  Future<void> _addByLabel() async {
    XFile? shot;
    try {
      shot = await ImagePicker()
          .pickImage(source: ImageSource.camera, maxWidth: 2200, imageQuality: 92);
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
    Navigator.pop(context);
    final LabelParse parse = parseNutritionLabel(text);
    if (!parse.hasAnything) {
      _snack("Couldn't read the label — fill it in or retake the photo.");
      _startAdd();
      return;
    }
    // US labels are already per serving — use the numbers as-is.
    final double? sg = parse.servingGrams;
    _startAdd(
      prefill: AddPrefill(
        macros: Macros(
          proteinG: parse.protein ?? 0,
          calories: parse.calories ?? 0,
          carbsG: parse.carbs ?? 0,
          fatG: parse.fat ?? 0,
        ),
        servingSize: (sg != null && sg > 0) ? sg : 0,
        servingUnit: 'g',
        macrosNote: (sg == null || sg <= 0)
            ? 'Read the macros per serving — set the serving size to match.'
            : null,
      ),
    );
  }

  void _reAdd(QuickAddItem q) {
    _startAdd(
      prefill: AddPrefill(
        name: q.name,
        barcode: q.barcode,
        unit: q.unit,
        macros: q.macros,
        servingSize: q.servingSize,
        servingUnit: q.servingUnit,
        price: q.lastPrice,
        total: q.lastTotal,
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
          decoration:
              BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(14)),
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
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: const Color(0xFF2A2A2A), content: Text(msg)));
  }

  void _showAddMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          _menuTile(Icons.qr_code_scanner_rounded, 'Scan barcode',
              'Look up macros from Open Food Facts', () {
            Navigator.pop(context);
            _addByBarcode();
          }),
          _menuTile(Icons.document_scanner_rounded, 'Scan nutrition label',
              'Read macros with the camera (OCR)', () {
            Navigator.pop(context);
            _addByLabel();
          }),
          _menuTile(Icons.edit_rounded, 'Enter manually',
              'Type it in — weight or count', () {
            Navigator.pop(context);
            _startAdd();
          }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _menuTile(
      IconData icon, String title, String sub, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: kAccent),
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle:
          Text(sub, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Tombstoned (deleted) entries stay in the lists for sync but never show.
    final List<PantryItem> visibleItems =
        _items.where((PantryItem i) => !i.deleted).toList();
    final List<QuickAddItem> visibleQuick =
        _quick.where((QuickAddItem q) => !q.deleted).toList();
    final List<Widget> pages = <Widget>[
      PantryTab(items: visibleItems, onTapItem: _openItem),
      QuickAddTab(
          quick: visibleQuick, onReAdd: _reAdd, onDelete: _deleteQuickAdd),
      SettingsTab(
          syncing: _syncing,
          onSyncNow: _syncFromRemote,
          itemCount: visibleItems.length),
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
                child: CircularProgressIndicator(strokeWidth: 2, color: kAccent)),
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
      // FAB lives on the OUTER Scaffold so it is positioned above the bottom
      // NavigationBar (fixes the nav-bar overlap). Only shown on the Pantry tab.
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              backgroundColor: kAccent,
              foregroundColor: Colors.black,
              onPressed: _showAddMenu,
              icon: const Icon(Icons.add),
              label: const Text('Add',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            )
          : null,
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        backgroundColor: kCard,
        indicatorColor: kAccent.withValues(alpha: 0.18),
        selectedIndex: _tab,
        onDestinationSelected: (int i) => setState(() => _tab = i),
        destinations: const <NavigationDestination>[
          NavigationDestination(
              icon: Icon(Icons.list_alt_rounded), label: 'Pantry'),
          NavigationDestination(icon: Icon(Icons.bolt_rounded), label: 'Quick-Add'),
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
        onAdjust: (double amount, bool add) {
          Navigator.pop(context);
          _adjust(item, amount, add);
        },
        onEdit: () async {
          Navigator.pop(context);
          final PantryItem? edited = await Navigator.of(context).push(
            MaterialPageRoute<PantryItem>(
                builder: (_) => AddItemPage(existing: item)),
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

  const PantryTab({super.key, required this.items, required this.onTapItem});

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final List<PantryItem> sorted = <PantryItem>[...items]..sort((a, b) {
        final bool ea = a.isExpiringSoon(now), eb = b.isExpiringSoon(now);
        if (ea != eb) {
          return ea ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    if (sorted.isEmpty) {
      return _empty();
    }
    // Bottom padding clears the FAB + the phone's gesture inset.
    final double bottomPad = 96 + MediaQuery.of(context).viewPadding.bottom;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      itemCount: sorted.length,
      itemBuilder: (_, int i) => _row(context, sorted[i], now),
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
    final double pct =
        it.total > 0 ? (it.remaining / it.total).clamp(0, 1).toDouble() : 0;
    final String u = it.unitLabel;
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
            if (it.isCount)
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                    color: kBg, borderRadius: BorderRadius.circular(20)),
                child: Text('COUNT',
                    style: TextStyle(
                        fontSize: 9,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6)),
              ),
            if (expiring)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
              value: pct,
              minHeight: 5,
              backgroundColor: const Color(0xFF111111),
              valueColor:
                  AlwaysStoppedAnimation<Color>(expiring ? kWarn : kAccent),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('${_fmt(it.remaining)} / ${_fmt(it.total)} $u',
                style: TextStyle(fontSize: 12, color: Colors.grey[400])),
            const Spacer(),
            Text(
                '\$${it.price.toStringAsFixed(2)}  ·  '
                '\$${it.pricePer.toStringAsFixed(it.isCount ? 2 : 4)}/$u',
                style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          ]),
          if (it.expirationDate != null && it.expirationDate!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Expires ${it.expirationDate}',
                style: TextStyle(
                    fontSize: 11, color: expiring ? kWarn : Colors.grey[600])),
          ],
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ITEM SHEET — ± adjust / edit / delete / save as quick-add
// ═══════════════════════════════════════════════════════════════════════

class ItemSheet extends StatefulWidget {
  final PantryItem item;
  final void Function(double amount, bool add) onAdjust;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSaveQuickAdd;

  const ItemSheet({
    super.key,
    required this.item,
    required this.onAdjust,
    required this.onEdit,
    required this.onDelete,
    required this.onSaveQuickAdd,
  });

  @override
  State<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<ItemSheet> {
  final TextEditingController _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _do(bool add) {
    final double a = double.tryParse(_amount.text.trim()) ?? 0;
    if (a > 0) {
      widget.onAdjust(a, add);
    }
  }

  @override
  Widget build(BuildContext context) {
    final PantryItem it = widget.item;
    final Macros m = it.macros;
    final String u = it.unitLabel;
    return Padding(
      padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 18,
          // viewInsets = keyboard; viewPadding.bottom = the phone's gesture /
          // nav bar. Include both so the action row is never hidden behind it.
          bottom: MediaQuery.of(context).viewInsets.bottom +
              MediaQuery.of(context).viewPadding.bottom +
              18),
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
          child: Text('${_fmt(it.remaining)} $u left of ${_fmt(it.total)} $u',
              style: TextStyle(color: Colors.grey[500], fontSize: 13)),
        ),
        if (!m.isEmpty) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
                it.servingLabel.isEmpty
                    ? 'PER SERVING'
                    : 'PER SERVING · ${it.servingLabel}',
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[600],
                    letterSpacing: 1,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 6),
          Row(children: [
            _macro('P', m.proteinG),
            _macro('Cal', m.calories),
            _macro('C', m.carbsG),
            _macro('F', m.fatG),
          ]),
        ],
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('ADJUST AMOUNT',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[500],
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
          ],
          decoration: _dec(it.isCount ? 'count' : 'grams'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _do(false),
              icon: const Icon(Icons.remove_rounded),
              label: const Text('Use'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kDanger,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _do(true),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Use = cooked/consumed.  Add = bought more.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600])),
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
            color: kDanger,
          ),
        ]),
      ]),
    );
  }

  Widget _macro(String label, double v) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration:
              BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(v.toStringAsFixed(v >= 100 ? 0 : 1),
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
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
  final String? unit; // 'g' | 'count'
  final Macros? macros; // per serving
  final double? servingSize;
  final String? servingUnit;
  final double? total;
  final double? price;
  final String? macrosNote;

  const AddPrefill({
    this.name,
    this.barcode,
    this.unit,
    this.macros,
    this.servingSize,
    this.servingUnit,
    this.total,
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
  late final TextEditingController _serving;
  late final TextEditingController _customUnit;
  String? _expiration;
  String? _note;
  late String _unit; // 'g' | 'count'
  late String _servingUnit; // one of kServingUnits, or '__custom__'

  @override
  void initState() {
    super.initState();
    final PantryItem? e = widget.existing;
    final AddPrefill? p = widget.prefill;
    final Macros m = e?.macros ?? p?.macros ?? const Macros();
    _unit = e?.unit ?? p?.unit ?? kUnitGrams;
    _name = TextEditingController(text: e?.name ?? p?.name ?? '');
    _barcode = TextEditingController(text: e?.barcode ?? p?.barcode ?? '');
    _protein = TextEditingController(text: _pf(m.proteinG));
    _calories = TextEditingController(text: _pf(m.calories));
    _carbs = TextEditingController(text: _pf(m.carbsG));
    _fat = TextEditingController(text: _pf(m.fatG));
    _total =
        TextEditingController(text: _pf(e?.total ?? p?.total ?? 0));
    _price = TextEditingController(text: _pf(e?.price ?? p?.price ?? 0));
    _serving = TextEditingController(
        text: _pf(e?.servingSize ?? p?.servingSize ?? 0));
    // Serving unit: use the preset if it matches one, else treat as custom.
    final String su = e?.servingUnit ?? p?.servingUnit ?? 'g';
    if (kServingUnits.contains(su)) {
      _servingUnit = su;
      _customUnit = TextEditingController();
    } else {
      _servingUnit = '__custom__';
      _customUnit = TextEditingController(text: su);
    }
    _expiration = e?.expirationDate;
    _note = p?.macrosNote;
  }

  static String _pf(double? v) => (v == null || v == 0) ? '' : _fmt(v);

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name, _barcode, _protein, _calories, _carbs, _fat, _total, _price,
      _serving, _customUnit
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
  bool get _isCount => _unit == kUnitCount;

  /// The resolved serving unit string (preset or the typed custom value).
  String get _resolvedServingUnit => _servingUnit == '__custom__'
      ? (_customUnit.text.trim().isEmpty ? 'serving' : _customUnit.text.trim())
      : _servingUnit;

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
    final PantryItem? e = widget.existing;
    final PantryItem item = PantryItem(
      id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      unit: _unit,
      total: total,
      remaining: e == null
          ? total
          : (e.remaining > total ? total : e.remaining),
      price: _d(_price),
      macros: macros,
      servingSize: _d(_serving),
      servingUnit: _resolvedServingUnit,
      expirationDate: _expiration,
      dateAdded: e?.dateAdded ?? _todayStr(),
      lastPrice: _d(_price),
      updatedAtMs: nowMs,
    );
    Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final bool editing = widget.existing != null;
    final String u = _isCount ? 'count' : 'g';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(editing ? 'Edit item' : 'Add item'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 40 + MediaQuery.of(context).viewPadding.bottom),
        children: [
          _field('Name', _name, hint: 'e.g. ground turkey / eggs'),
          _field('Barcode (optional)', _barcode, hint: 'digits'),
          const SizedBox(height: 12),
          _sectionLabel('TRACK BY'),
          SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(
                  value: kUnitGrams,
                  label: Text('Weight (g)'),
                  icon: Icon(Icons.scale_rounded, size: 18)),
              ButtonSegment<String>(
                  value: kUnitCount,
                  label: Text('Count'),
                  icon: Icon(Icons.tag_rounded, size: 18)),
            ],
            selected: <String>{_unit},
            onSelectionChanged: (Set<String> s) =>
                setState(() => _unit = s.first),
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                      ? kAccent.withValues(alpha: 0.18)
                      : kCard),
              foregroundColor:
                  WidgetStateProperty.all(Colors.grey[200]),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel('SERVING SIZE'),
          Row(children: [
            Expanded(flex: 2, child: _numField('Size', _serving)),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: _servingUnitDropdown()),
          ]),
          if (_servingUnit == '__custom__') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _customUnit,
              onChanged: (_) => setState(() {}),
              decoration: _dec('e.g. cookie, scoop, slice', label: 'Custom unit'),
            ),
          ],
          const SizedBox(height: 16),
          _sectionLabel('MACROS — per serving'),
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
            Text(_note!, style: const TextStyle(fontSize: 12, color: kWarn)),
          ],
          const SizedBox(height: 16),
          _sectionLabel('AMOUNT & COST'),
          Row(children: [
            Expanded(
                child: _numField(
                    _isCount ? 'Total count' : 'Total weight g', _total)),
            const SizedBox(width: 10),
            Expanded(child: _numField('Price \$', _price)),
          ]),
          const SizedBox(height: 6),
          _pricePerPreview(u),
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
                  style:
                      const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pricePerPreview(String u) {
    final double total = _d(_total);
    final double price = _d(_price);
    final double ppg = total > 0 ? price / total : 0;
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
          total > 0
              ? 'Price per ${_isCount ? "item" : "gram"}: '
                  '\$${ppg.toStringAsFixed(_isCount ? 2 : 4)}/$u'
              : 'Enter total ${_isCount ? "count" : "weight"} to compute price per ${_isCount ? "item" : "gram"}.',
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
          child: const Text('Clear', style: TextStyle(color: kDanger)),
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
            style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                letterSpacing: 1,
                fontWeight: FontWeight.w600)),
      );

  Widget _field(String label, TextEditingController c, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        decoration: _dec(hint ?? label, label: label),
      ),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: (_) => setState(() {}),
      decoration: _dec(label, label: label),
    );
  }

  Widget _servingUnitDropdown() {
    return DropdownButtonFormField<String>(
      initialValue: _servingUnit,
      isExpanded: true,
      dropdownColor: kCard,
      decoration: _dec('Unit', label: 'Unit'),
      items: <DropdownMenuItem<String>>[
        for (final String u in kServingUnits)
          DropdownMenuItem<String>(value: u, child: Text(u)),
        const DropdownMenuItem<String>(
            value: '__custom__', child: Text('custom…')),
      ],
      onChanged: (String? v) =>
          setState(() => _servingUnit = v ?? 'g'),
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
    final double bottomPad = 24 + MediaQuery.of(context).viewPadding.bottom;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      itemCount: quick.length,
      itemBuilder: (_, int i) {
        final QuickAddItem q = quick[i];
        final String macroNote = q.macros.isEmpty
            ? ''
            : '  ·  ${_fmt(q.macros.proteinG)}g protein/serving';
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: ListTile(
            title: Text(q.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('Last \$${q.lastPrice.toStringAsFixed(2)}$macroNote',
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
    final double bottomPad = 40 + MediaQuery.of(context).viewPadding.bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPad),
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
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: <BarcodeFormat>[
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
