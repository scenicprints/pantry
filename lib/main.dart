import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'cook.dart';
import 'food_lookup.dart';
import 'github_sync.dart';
import 'label_parser.dart';
import 'models.dart';
import 'notifications.dart';
import 'pricebook.dart';
import 'spending.dart';
import 'storage.dart';
import 'theme.dart';
import 'updater.dart';

// ═══════════════════════════════════════════════════════════════════════
// PANTRY — inventory & cost tracker + AI chef. Scans groceries, tracks
// remaining amount + cost, syncs pantry.json to GitHub, and cooks from it.
// The warm editorial palette + fonts live in theme.dart.
// ═══════════════════════════════════════════════════════════════════════

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalCache.init();
  await Notifications.init();
  runApp(const PantryApp());
}

class PantryApp extends StatelessWidget {
  const PantryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pantry',
      debugShowCheckedModeBanner: false,
      theme: buildPantryTheme(),
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
  SpendingLog _usage = const SpendingLog();
  PriceBook _prices = const PriceBook();
  int _tab = 0;
  bool _syncing = false;
  String _syncMsg = '';

  @override
  void initState() {
    super.initState();
    final PantryData d = LocalCache.load();
    _items = d.pantry;
    _quick = d.quickAdd;
    _usage = SpendingLog.decode(LocalCache.loadUsage());
    // Seed the price book from what's already in the pantry so owned items are
    // priceable immediately, even before the first remote sync.
    _prices = PriceBook.decode(LocalCache.loadPriceBook())
        .withPantry(_items, DateTime.now());
    LocalCache.savePriceBook(_prices.encode());
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
    _items = merged.pantry;
    _quick = merged.quickAdd;
    // Best-effort sync of the spending ledger and price book too. Failures are
    // ignored (they fall back to the local copy).
    await _syncSpending();
    await _syncPrices();
    if (!mounted) {
      return;
    }
    setState(() {
      _syncing = false;
      _syncMsg = PantrySync.canWrite ? '' : 'Read-only — write token not set.';
    });
  }

  /// Merge the remote ledger onto the local one (union by id) and, if this
  /// build can write, push the union back.
  Future<void> _syncSpending() async {
    final ({SpendingLog log, String? sha})? remote = await SpendingSync.fetch();
    if (remote == null) {
      return;
    }
    SpendingLog merged = SpendingLog.merge(remote.log, _usage);
    if (SpendingSync.canWrite) {
      final SpendingLog? live = await SpendingSync.push(merged);
      if (live != null) {
        merged = live;
      }
    }
    _usage = merged;
    LocalCache.saveUsage(merged.encode());
  }

  /// Merge the remote price book with the local one, re-seed from the current
  /// pantry, and push back when possible.
  Future<void> _syncPrices() async {
    final ({PriceBook book, String? sha})? remote = await PriceBookSync.fetch();
    if (remote == null) {
      return;
    }
    PriceBook merged = PriceBook.merge(remote.book, _prices)
        .withPantry(_items, DateTime.now());
    if (PriceBookSync.canWrite) {
      final PriceBook? live = await PriceBookSync.push(merged);
      if (live != null) {
        merged = live;
      }
    }
    _prices = merged;
    LocalCache.savePriceBook(merged.encode());
  }

  /// Record a consumption event in the spending ledger. Called when the user
  /// uses some of a tracked, priced item (the Use(−) button). Untracked or
  /// unpriced items contribute no cost, so they're skipped.
  Future<void> _logUsage(PantryItem item, double consumed) async {
    if (item.untracked || consumed <= 0 || item.pricePer <= 0) {
      return;
    }
    final UsageEntry e = UsageEntry.forUse(item, consumed, DateTime.now());
    setState(() => _usage = _usage.add(e));
    LocalCache.saveUsage(_usage.encode());
    if (!SpendingSync.canWrite) {
      return;
    }
    final SpendingLog? live = await SpendingSync.push(_usage);
    if (!mounted || live == null) {
      return;
    }
    setState(() => _usage = live);
    LocalCache.saveUsage(_usage.encode());
  }

  /// Remember an item's current unit price (kept even after it's used up) so
  /// the chef can price it as a future new buy.
  Future<void> _recordPrice(PantryItem item) async {
    final PriceBook updated = _prices.withItem(item, DateTime.now());
    if (identical(updated, _prices)) {
      return; // nothing priceable to record
    }
    setState(() => _prices = updated);
    LocalCache.savePriceBook(_prices.encode());
    if (!PriceBookSync.canWrite) {
      return;
    }
    final PriceBook? live = await PriceBookSync.push(_prices);
    if (!mounted || live == null) {
      return;
    }
    setState(() => _prices = live);
    LocalCache.savePriceBook(_prices.encode());
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

  void _addItem(PantryItem item) {
    _mutate(() => _items.add(item));
    _recordPrice(item);
  }

  void _replaceItem(PantryItem item) {
    _mutate(() {
      final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
      if (i >= 0) {
        _items[i] = item;
      }
    });
    _recordPrice(item);
  }

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
  /// When a "use" empties a tracked item it moves to the Used-up history; we
  /// offer an Undo that restores what was there before.
  void _adjust(PantryItem item, double amount, bool add) {
    double? restore;
    double consumed = 0; // amount actually used (for the spending ledger)
    _mutate(() {
      final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
      if (i < 0) {
        return;
      }
      final PantryItem it = _items[i];
      if (add) {
        if (it.remaining <= 0 && !it.untracked) {
          // Restocking a used-up item: start fresh so the fill bar reads
          // correctly instead of piling onto a stale total.
          it.total = amount;
          it.remaining = amount;
        } else {
          it.remaining += amount;
          it.total += amount;
        }
      } else {
        // Capture the pre-use amount only when this use is what empties it,
        // so the Undo restores the exact prior remaining.
        if (it.remaining > 0 && it.remaining - amount <= 0 && !it.untracked) {
          restore = it.remaining;
        }
        // Money-used = what actually left the jar (clamped at what's there).
        consumed = amount <= it.remaining ? amount : it.remaining;
        final double left = it.remaining - amount;
        it.remaining = left < 0 ? 0 : left;
      }
      it.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    });
    if (!add && consumed > 0) {
      _logUsage(item, consumed);
    }
    if (restore != null) {
      _snackUsedUp(item, restore!);
    }
  }

  void _snackUsedUp(PantryItem item, double restore) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('${item.name} used up — moved to History.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _mutate(() {
            final int i = _items.indexWhere((PantryItem x) => x.id == item.id);
            if (i >= 0) {
              _items[i].remaining = restore;
              _items[i].updatedAtMs = DateTime.now().millisecondsSinceEpoch;
            }
          }),
        ),
      ));
  }

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

  Future<void> _addBySearch() async {
    final ProductInfo? info = await Navigator.of(context).push(
      MaterialPageRoute<ProductInfo>(builder: (_) => const FoodSearchPage()),
    );
    if (info == null || !mounted) {
      return;
    }
    // Open Food Facts is per-100 g. Convert to per-serving using the product's
    // serving grams when known; otherwise present a 100 g serving.
    final double sg = (info.servingGrams != null && info.servingGrams! > 0)
        ? info.servingGrams!
        : 100;
    _startAdd(
      prefill: AddPrefill(
        name: info.name,
        barcode: info.barcode,
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
            Text(msg, style: const TextStyle(color: kMuted)),
          ]),
        ),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: kInk, content: Text(msg)));
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
          _menuTile(Icons.search_rounded, 'Search foods',
              'Find macros by name (Open Food Facts)', () {
            Navigator.pop(context);
            _addBySearch();
          }),
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
          Text(sub, style: TextStyle(color: kMuted, fontSize: 12)),
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
      CookTab(items: visibleItems, prices: _prices),
      QuickAddTab(
          quick: visibleQuick, onReAdd: _reAdd, onDelete: _deleteQuickAdd),
      SettingsTab(
          syncing: _syncing,
          onSyncNow: _syncFromRemote,
          itemCount: visibleItems.length,
          spending: _usage),
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
                  color: kWarn.withValues(alpha: 0.16),
                  padding:
                      const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
                  child: Text(_syncMsg,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8A5A22),
                          fontWeight: FontWeight.w600)),
                ),
              ),
      ),
      // FAB lives on the OUTER Scaffold so it is positioned above the bottom
      // NavigationBar (fixes the nav-bar overlap). Only shown on the Pantry tab.
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              backgroundColor: kAccent,
              foregroundColor: Colors.white,
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
          NavigationDestination(
              icon: Icon(Icons.restaurant_menu_rounded), label: 'Cook'),
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

class PantryTab extends StatefulWidget {
  final List<PantryItem> items;
  final void Function(PantryItem) onTapItem;

  const PantryTab({super.key, required this.items, required this.onTapItem});

  @override
  State<PantryTab> createState() => _PantryTabState();
}

class _PantryTabState extends State<PantryTab> {
  String _filter = 'All';
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    if (widget.items.isEmpty) {
      return _empty();
    }
    final String q = _query.trim().toLowerCase();
    final bool hasSpices = widget.items.any((PantryItem i) => i.spice);
    final bool hasUsedUp = widget.items.any((PantryItem i) => i.usedUp);
    // Build the chip set, then fall back to All if the active filter's chip is
    // gone (e.g. the last Used-up item got restocked while that tab was open).
    final List<String> cats = <String>[
      'All',
      'Pantry',
      if (hasSpices) 'Spices',
      if (hasUsedUp) 'Used up',
    ];
    final String f = cats.contains(_filter) ? _filter : 'All';
    bool inFilter(PantryItem i) {
      switch (f) {
        case 'Used up':
          return i.usedUp;
        case 'Pantry':
          return !i.usedUp && i.category == 'Pantry';
        case 'Spices':
          return !i.usedUp && i.category == 'Spices';
        default: // 'All' — everything still on hand
          return !i.usedUp;
      }
    }

    final List<PantryItem> visible = widget.items
        .where((PantryItem i) =>
            inFilter(i) && (q.isEmpty || i.name.toLowerCase().contains(q)))
        .toList()
      ..sort((PantryItem a, PantryItem b) {
        final bool ea = a.isExpiringSoon(now), eb = b.isExpiringSoon(now);
        if (ea != eb) {
          return ea ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final bool showBar = cats.length > 2; // more than All + Pantry
    final double bottomPad = 96 + MediaQuery.of(context).viewPadding.bottom;
    return Column(children: [
      _searchField(),
      if (showBar) _filterBar(cats, f),
      Expanded(
        child: visible.isEmpty
            ? Center(
                child: Text(
                    q.isNotEmpty ? 'No matches for “$_query”.' : 'Nothing in $f yet.',
                    style: TextStyle(color: kMuted)))
            : ListView.builder(
                padding: EdgeInsets.fromLTRB(12, 2, 12, bottomPad),
                itemCount: visible.length,
                itemBuilder: (_, int i) => _row(context, visible[i], now),
              ),
      ),
    ]);
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: TextField(
        controller: _search,
        onChanged: (String v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search pantry',
          hintStyle: TextStyle(color: kFaint),
          prefixIcon: Icon(Icons.search_rounded, size: 20, color: kMuted),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: kMuted,
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                    FocusScope.of(context).unfocus();
                  },
                ),
          isDense: true,
          filled: true,
          fillColor: kCard,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kBorder)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kBorder)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kAccent)),
        ),
      ),
    );
  }

  Widget _filterBar(List<String> cats, String active) {
    // Custom pills instead of Material ChoiceChip: a Container hugs its text
    // with explicit padding inside a horizontal scroll, so the label can't be
    // clipped either vertically or horizontally regardless of font metrics.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: <Widget>[
          for (final String c in cats) _chip(c, active == c),
        ],
      ),
    );
  }

  Widget _chip(String c, bool selected) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? kAccent.withValues(alpha: 0.18) : kCard,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => setState(() => _filter = c),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: selected ? kAccent : kBorder)),
            child: Text(
              c,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: TextStyle(
                  fontSize: 13.5,
                  height: 1.0,
                  color: selected ? kAccent : kInk,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.kitchen_outlined, size: 54, color: kFaint),
          const SizedBox(height: 14),
          Text('Your pantry is empty.',
              style: TextStyle(color: kMuted, fontSize: 15)),
          const SizedBox(height: 4),
          Text('Tap Add to scan your first item.',
              style: TextStyle(color: kFaint, fontSize: 13)),
        ]),
      );

  Widget _badge(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontSize: 9,
                color: color,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6)),
      );

  Widget _row(BuildContext context, PantryItem it, DateTime now) {
    final bool expiring = it.isExpiringSoon(now);
    final double pct =
        it.total > 0 ? (it.remaining / it.total).clamp(0, 1).toDouble() : 0;
    final String u = it.unitLabel;
    return GestureDetector(
      onTap: () => widget.onTapItem(it),
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
            if (it.spice)
              _badge('SPICE', kOlive)
            else if (it.quantityUnknown)
              _badge('ON HAND', kOlive)
            else if (it.isCount)
              _badge('COUNT', kMuted),
            if (it.usedUp)
              _badge('USED UP', kDanger)
            else if (expiring)
              _badge('EXPIRING', kWarn),
          ]),
          if (it.untracked) ...[
            const SizedBox(height: 8),
            Text(
                it.spice
                    ? 'Spice · always on hand'
                    : 'On hand · amount not tracked',
                style: TextStyle(fontSize: 12, color: kOlive)),
          ] else ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 5,
                backgroundColor: kInset,
                valueColor:
                    AlwaysStoppedAnimation<Color>(expiring ? kWarn : kAccent),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Text('${_fmt(it.remaining)} / ${_fmt(it.total)} $u',
                  style: TextStyle(fontSize: 12, color: kMuted)),
              const Spacer(),
              Text(
                  '\$${it.price.toStringAsFixed(2)}  ·  '
                  '\$${it.pricePer.toStringAsFixed(it.isCount ? 2 : 4)}/$u',
                  style: TextStyle(fontSize: 12, color: kMuted)),
            ]),
          ],
          if (it.expirationDate != null && it.expirationDate!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Expires ${it.expirationDate}',
                style: TextStyle(
                    fontSize: 11, color: expiring ? kWarn : kMuted)),
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
          child: Text(
              it.untracked
                  ? (it.spice
                      ? 'Spice · always on hand'
                      : 'On hand · amount not tracked')
                  : '${_fmt(it.remaining)} $u left of ${_fmt(it.total)} $u',
              style: TextStyle(color: kMuted, fontSize: 13)),
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
                    color: kMuted,
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
        if (it.usedUp) ...[
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: widget.onEdit,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add back to pantry'),
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
          ),
        ),
        const SizedBox(height: 6),
        Text('Opens the full form, prefilled — set the new amount, price and '
            'date just like a new item.',
            style: TextStyle(fontSize: 11, color: kMuted)),
        ] else if (!it.untracked) ...[
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('ADJUST AMOUNT',
              style: TextStyle(
                  fontSize: 11,
                  color: kMuted,
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
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Use = cooked/consumed.  Add = bought more.',
            style: TextStyle(fontSize: 11, color: kMuted)),
        ],
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
          // A used-up item's primary "Add back to pantry" already opens this
          // same form, so the redundant Edit button is hidden for it.
          if (!it.usedUp) ...[
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: widget.onEdit,
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Edit'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: kInk,
                    side: const BorderSide(color: kBorder),
                    padding: const EdgeInsets.symmetric(vertical: 12)),
              ),
            ),
          ],
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
              BoxDecoration(color: kInset, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(v.toStringAsFixed(v >= 100 ? 0 : 1),
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            Text(label, style: TextStyle(fontSize: 10, color: kMuted)),
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
  late final TextEditingController _servings; // servings per container
  late final TextEditingController _available; // on-hand amount (remaining)
  late final TextEditingController _price;
  late final TextEditingController _serving;
  late final TextEditingController _customUnit;
  String? _expiration;
  String? _note;
  late String _unit; // 'g' | 'count'
  late String _servingUnit; // one of kServingUnits, or '__custom__'
  bool _spice = false;
  bool _quantityUnknown = false;

  /// Amount/cost aren't tracked for spices or quantity-unknown items.
  bool get _untracked => _spice || _quantityUnknown;

  @override
  void initState() {
    super.initState();
    final PantryItem? e = widget.existing;
    final AddPrefill? p = widget.prefill;
    final Macros m = e?.macros ?? p?.macros ?? const Macros();
    _spice = e?.spice ?? false;
    _quantityUnknown = e?.quantityUnknown ?? false;
    _unit = e?.unit ?? p?.unit ?? kUnitGrams;
    _name = TextEditingController(text: e?.name ?? p?.name ?? '');
    _barcode = TextEditingController(text: e?.barcode ?? p?.barcode ?? '');
    _protein = TextEditingController(text: _pf(m.proteinG));
    _calories = TextEditingController(text: _pf(m.calories));
    _carbs = TextEditingController(text: _pf(m.carbsG));
    _fat = TextEditingController(text: _pf(m.fatG));
    // Servings per container is derived from total ÷ serving size (both are
    // known on edit / from a barcode); blank when we can't derive it.
    final double eTotal = e?.total ?? p?.total ?? 0;
    final double sSize = e?.servingSize ?? p?.servingSize ?? 0;
    _servings = TextEditingController(
        text: (eTotal > 0 && sSize > 0) ? _fmt(eTotal / sSize) : '');
    _available = TextEditingController(text: e != null ? _pf(e.remaining) : '');
    _price = TextEditingController(text: _pf(e?.price ?? p?.price ?? 0));
    _serving = TextEditingController(text: _pf(sSize));
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
      _name, _barcode, _protein, _calories, _carbs, _fat, _servings, _available,
      _price, _serving, _customUnit
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
  bool get _isCount => _unit == kUnitCount;

  /// Total = serving size × servings per container. If servings is blank,
  /// one serving is assumed. With no serving size, the total is just whatever
  /// is on hand.
  double get _computedTotal {
    final double s = _d(_serving);
    final double n = _d(_servings);
    if (s > 0) {
      return n > 0 ? s * n : s;
    }
    return _d(_available);
  }

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
    // Spices / quantity-unknown items don't track amount or cost.
    final double total = _untracked ? 0 : _computedTotal;
    final double avail = _d(_available);
    final double remaining = _untracked
        ? 0
        : (avail > 0 ? avail : total).clamp(0, total).toDouble();
    final double price = _untracked ? 0 : _d(_price);
    final Macros macros = _untracked
        ? const Macros()
        : Macros(
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
      remaining: remaining,
      price: price,
      macros: macros,
      servingSize: _untracked ? 0 : _d(_serving),
      servingUnit: _resolvedServingUnit,
      expirationDate: _expiration,
      // Re-adding a used-up item is a fresh purchase, so stamp today; a normal
      // edit of an in-stock item keeps its original date.
      dateAdded: (e != null && !e.usedUp) ? e.dateAdded : _todayStr(),
      lastPrice: price,
      updatedAtMs: nowMs,
      spice: _spice,
      quantityUnknown: _quantityUnknown,
    );
    Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    // Editing an in-stock item shows "Edit item"; adding fresh OR re-adding a
    // used-up item both read as "Add item".
    final bool editing =
        widget.existing != null && !(widget.existing!.usedUp);
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
          const SizedBox(height: 8),
          _typeToggles(),
          if (!_untracked) ...[
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
                  WidgetStateProperty.all(kInk),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel('SERVING SIZE & COUNT'),
          Row(children: [
            Expanded(flex: 2, child: _numField('Serving size', _serving)),
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
          const SizedBox(height: 10),
          _numField('Servings per container', _servings),
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
          _totalDisplay(u),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _numField(
                    _isCount ? 'Available now (ct)' : 'Available now (g)',
                    _available)),
            const SizedBox(width: 10),
            Expanded(child: _numField('Price \$', _price)),
          ]),
          const SizedBox(height: 6),
          _pricePerPreview(u),
          ],
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
                  foregroundColor: Colors.white,
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

  /// Auto-calculated total (serving size × servings), shown live.
  Widget _totalDisplay(String u) {
    final double total = _computedTotal;
    final double s = _d(_serving);
    final double n = _d(_servings);
    final String detail = (s > 0 && n > 0)
        ? '${_fmt(s)} × ${_fmt(n)}'
        : (s > 0 ? '1 serving' : 'from Available');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
          color: kInset, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Text('Total', style: labelCaps()),
        const Spacer(),
        Text('${_fmt(total)} $u',
            style: mono(size: 16, weight: FontWeight.w700, color: kInk)),
        const SizedBox(width: 8),
        Text('($detail)', style: TextStyle(fontSize: 11, color: kMuted)),
      ]),
    );
  }

  Widget _pricePerPreview(String u) {
    final double total = _computedTotal;
    final double price = _d(_price);
    final double ppg = total > 0 ? price / total : 0;
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
          total > 0
              ? 'Price per ${_isCount ? "item" : "gram"}: '
                  '\$${ppg.toStringAsFixed(_isCount ? 2 : 4)}/$u'
              : 'Set serving size (and servings) or Available to compute price.',
          style: TextStyle(fontSize: 12, color: kMuted)),
    );
  }

  Widget _expirationPickerRow() {
    return Row(children: [
      Expanded(
        child: Text(_expiration ?? 'No expiration set',
            style: TextStyle(
                color: _expiration == null ? kMuted : kInk)),
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
                primary: kAccent, onPrimary: Colors.white, surface: kCard)),
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
                color: kMuted,
                letterSpacing: 1,
                fontWeight: FontWeight.w600)),
      );

  Widget _typeToggles() {
    return Column(children: [
      _toggleRow(
          'I have it — amount & cost unknown',
          'For stuff you bought before tracking. The chef knows you have it.',
          _quantityUnknown,
          (bool v) => setState(() => _quantityUnknown = v)),
      const SizedBox(height: 8),
      _toggleRow(
          'Spice',
          'Its own pantry category. Never-ending, no cost to track.',
          _spice,
          (bool v) => setState(() => _spice = v)),
    ]);
  }

  Widget _toggleRow(
      String title, String sub, bool value, ValueChanged<bool> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Row(children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                Text(sub, style: TextStyle(fontSize: 11.5, color: kMuted)),
                const SizedBox(height: 8),
              ]),
        ),
        Switch(
            value: value,
            activeTrackColor: kAccent,
            onChanged: onChanged),
      ]),
    );
  }

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
          Icon(Icons.bolt_outlined, size: 54, color: kFaint),
          const SizedBox(height: 14),
          Text('No quick-add items yet.',
              style: TextStyle(color: kMuted, fontSize: 15)),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
                'Open any pantry item and tap “Quick-Add” to save it here for one-tap re-adding.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kFaint, fontSize: 13)),
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
                style: TextStyle(color: kMuted, fontSize: 12)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                onPressed: () => onDelete(q),
                icon: const Icon(Icons.close_rounded, size: 18),
                color: kMuted,
              ),
              FilledButton(
                onPressed: () => onReAdd(q),
                style: FilledButton.styleFrom(
                    backgroundColor: kAccent, foregroundColor: Colors.white),
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
  final SpendingLog spending;

  const SettingsTab({
    super.key,
    required this.syncing,
    required this.onSyncNow,
    required this.itemCount,
    required this.spending,
  });

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 40 + MediaQuery.of(context).viewPadding.bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPad),
      children: [
        SpendingCard(log: spending),
        const SizedBox(height: 14),
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
                    color: kMuted,
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
                    style: TextStyle(fontSize: 13, color: kInk)),
              ),
            ]),
            const SizedBox(height: 6),
            Text('$itemCount items tracked',
                style: TextStyle(fontSize: 12, color: kMuted)),
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
        const ChefSettingsCard(),
        const SizedBox(height: 14),
        const UpdateCard(accent: kAccent),
        const SizedBox(height: 20),
        Center(
          child: Text('Pantry — scans, tracks, and cooks',
              style: TextStyle(color: kFaint, fontSize: 12)),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SPENDING CARD — weekly (Sun–Sat) and monthly spend, counted by what's been
// USED (consumed), not what was bought. A jar bought once but used over months
// only shows cost on the weeks it's actually drawn from.
// ═══════════════════════════════════════════════════════════════════════

class SpendingCard extends StatelessWidget {
  final SpendingLog log;
  const SpendingCard({super.key, required this.log});

  static String _m(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final double week = log.weekTotal(now);
    final double lastWeek = log.lastWeekTotal(now);
    final double month = log.monthTotal(now);
    final double lastMonth = log.lastMonthTotal(now);
    final double avgWeek = log.averagePerWeek();
    final double avgMonth = log.averagePerMonth();
    final List<MapEntry<String, double>> top = log.topItems(
        SpendingLog.monthStart(now), DateTime(now.year, now.month + 1, 1),
        limit: 3);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.payments_rounded, size: 16, color: kAccent),
          const SizedBox(width: 8),
          Text('SPENDING',
              style: TextStyle(
                  fontSize: 11,
                  color: kMuted,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 2),
        Text('By what you use, not what you buy',
            style: TextStyle(fontSize: 11, color: kFaint)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _stat('This week', week, 'Sun–Sat')),
          const SizedBox(width: 12),
          Expanded(child: _stat('This month', month, _monthLabel(now))),
        ]),
        const SizedBox(height: 12),
        _deltaRow('Last week', lastWeek),
        const SizedBox(height: 4),
        _deltaRow('Last month', lastMonth),
        const SizedBox(height: 8),
        _deltaRow('Avg / week', avgWeek, valueColor: kOlive),
        const SizedBox(height: 4),
        _deltaRow('Avg / month', avgMonth, valueColor: kOlive),
        if (top.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('TOP THIS MONTH',
              style: TextStyle(
                  fontSize: 10,
                  color: kMuted,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final MapEntry<String, double> e in top) _topRow(e.key, e.value),
        ],
        if (log.entries.isEmpty) ...[
          const SizedBox(height: 10),
          Text(
              'Nothing logged yet — costs show up here as you use items '
              '(the − button on a pantry item).',
              style: TextStyle(fontSize: 12, color: kMuted, height: 1.4)),
        ],
      ]),
    );
  }

  Widget _stat(String label, double value, String sub) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
      decoration: BoxDecoration(
          color: kInset, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: kMuted)),
        const SizedBox(height: 6),
        Text(_m(value),
            style: const TextStyle(
                fontSize: 24, fontWeight: FontWeight.w700, color: kAccent)),
        const SizedBox(height: 2),
        Text(sub, style: TextStyle(fontSize: 10, color: kFaint)),
      ]),
    );
  }

  Widget _deltaRow(String label, double value, {Color valueColor = kInk}) {
    return Row(children: [
      Text(label, style: TextStyle(fontSize: 13, color: kMuted)),
      const Spacer(),
      Text(_m(value),
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: valueColor)),
    ]);
  }

  Widget _topRow(String name, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: kInk))),
        const SizedBox(width: 10),
        Text(_m(value),
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: kOlive)),
      ]),
    );
  }

  static String _monthLabel(DateTime now) {
    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return months[now.month - 1];
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
              style: TextStyle(color: kMuted)),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// FOOD SEARCH — find a product by name (Open Food Facts), pick one to prefill
// the Add form. Returns the chosen ProductInfo (per-100 g macros) on pop.
// ═══════════════════════════════════════════════════════════════════════

class FoodSearchPage extends StatefulWidget {
  const FoodSearchPage({super.key});

  @override
  State<FoodSearchPage> createState() => _FoodSearchPageState();
}

class _FoodSearchPageState extends State<FoodSearchPage> {
  final TextEditingController _q = TextEditingController();
  Timer? _debounce;
  int _reqId = 0; // guards against out-of-order responses
  bool _loading = false;
  bool _searched = false;
  List<ProductInfo> _results = <ProductInfo>[];

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().length < 2) {
      setState(() {
        _results = <ProductInfo>[];
        _searched = false;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(v));
  }

  Future<void> _run(String v) async {
    final int id = ++_reqId;
    setState(() {
      _loading = true;
      _searched = true;
    });
    List<ProductInfo> res = <ProductInfo>[];
    try {
      res = await OpenFoodFacts.search(v);
    } catch (_) {}
    if (!mounted || id != _reqId) {
      return; // a newer query superseded this one
    }
    setState(() {
      _results = res;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 16 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: const Text('Search foods'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _q,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            onSubmitted: (String v) {
              _debounce?.cancel();
              if (v.trim().length >= 2) {
                _run(v);
              }
            },
            decoration: _dec('e.g. greek yogurt, chicken breast').copyWith(
              prefixIcon: Icon(Icons.search_rounded, color: kMuted),
              suffixIcon: _q.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: kMuted,
                      onPressed: () {
                        _q.clear();
                        _onChanged('');
                        setState(() {});
                      },
                    ),
            ),
          ),
        ),
        Expanded(child: _body(bottomPad)),
      ]),
    );
  }

  Widget _body(double bottomPad) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kAccent));
    }
    if (!_searched) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Type a food name to search Open Food Facts.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted, fontSize: 14, height: 1.5)),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No matches. Try a different name, or scan the '
              'barcode / label instead.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kMuted, fontSize: 14, height: 1.5)),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(12, 4, 12, bottomPad),
      itemCount: _results.length,
      itemBuilder: (_, int i) => _resultRow(_results[i]),
    );
  }

  Widget _resultRow(ProductInfo p) {
    final Macros m = p.macrosPer100g;
    return GestureDetector(
      onTap: () => Navigator.pop(context, p),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
              'per 100 g · ${m.calories.round()} cal · '
              '${_fmt(m.proteinG)}p / ${_fmt(m.carbsG)}c / ${_fmt(m.fatG)}f',
              style: TextStyle(fontSize: 12, color: kMuted)),
        ]),
      ),
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
      labelStyle: TextStyle(color: kMuted, fontSize: 13),
      hintStyle: TextStyle(color: kFaint),
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
