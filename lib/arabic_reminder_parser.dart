class ParsedReminder {
  final String task;
  final DateTime? dateTime;
  final String originalText;

  /// true إذا لم يُذكر وقت واضح فافترضنا الساعة 9 صباحاً
  final bool timeAssumed;
  const ParsedReminder({
    required this.task,
    required this.dateTime,
    required this.originalText,
    this.timeAssumed = false,
  });
}

class ArabicReminderParser {
  // ---------- أدوات ----------
  /// يطابق كلمة كاملة (لأن \b لا تعمل مع العربية)
  static RegExp _w(String p) => RegExp('(?<![ء-ي])(?:$p)(?![ء-ي])');

  static const Map<String, int> _hours = {
    'الحاديه عشره': 11,
    'الحاديه عشر': 11,
    'الثانيه عشره': 12,
    'الثانيه عشر': 12,
    'الواحده': 1,
    'واحده': 1,
    'الاولي': 1,
    'الثانيه': 2,
    'الثالثه': 3,
    'الرابعه': 4,
    'الخامسه': 5,
    'السادسه': 6,
    'السابعه': 7,
    'الثامنه': 8,
    'التاسعه': 9,
    'العاشره': 10,
  };

  static final String _hourWords =
      (_hours.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join(
        '|',
      );

  static const Map<String, int> _weekdays = {
    'الاثنين': DateTime.monday,
    'الثلاثاء': DateTime.tuesday,
    'الاربعاء': DateTime.wednesday,
    'الخميس': DateTime.thursday,
    'الجمعه': DateTime.friday,
    'السبت': DateTime.saturday,
    'الاحد': DateTime.sunday,
  };

  /// تطبيع يحافظ على طول النص (حرف مقابل حرف) ليبقى مكان الكلمات ثابتاً
  static String _normalize(String s) {
    final out = StringBuffer();
    for (final c in s.codeUnits) {
      if (c == 0x0623 || c == 0x0625 || c == 0x0622 || c == 0x0671) {
        out.writeCharCode(0x0627); // أ إ آ ٱ -> ا
      } else if (c == 0x0649) {
        out.writeCharCode(0x064A); // ى -> ي
      } else if (c == 0x0629) {
        out.writeCharCode(0x0647); // ة -> ه
      } else if (c >= 0x0660 && c <= 0x0669) {
        out.writeCharCode(0x30 + c - 0x0660); // أرقام عربية -> لاتينية
      } else if (c >= 0x06F0 && c <= 0x06F9) {
        out.writeCharCode(0x30 + c - 0x06F0);
      } else {
        out.writeCharCode(c);
      }
    }
    return out.toString();
  }

  // ---------- تصحيح تقريبي مقيَّد بالسياق ----------
  static const _units = [
    'ساعتين',
    'دقيقتين',
    'يومين',
    'اسبوعين',
    'ساعات',
    'ساعه',
    'دقائق',
    'دقايق',
    'دقيقه',
    'ايام',
    'يوم',
    'اسبوع',
    'اسابيع',
    'ثواني',
    'ثانيه',
  ];
  static const _longDays = ['الاثنين', 'الثلاثاء', 'الاربعاء'];

  static int _lev(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        final v = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
        cur[j] = v;
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// أقرب كلمة من القاموس بمسافة <= maxDist، أو null إن كانت مطابقة تماماً/بعيدة
  static String? _nearest(String tok, List<String> dict, int maxDist) {
    String? best;
    var bestD = maxDist + 1;
    for (final w in dict) {
      if (w == tok) return null;
      final d = _lev(tok, w);
      if (d < bestD) {
        bestD = d;
        best = w;
      }
    }
    return bestD <= maxDist ? best : null;
  }

  static bool _numberLike(String t) =>
      RegExp(r'^\d+$').hasMatch(t) ||
      RegExp(r'^(?:ثلاث|اربع|خمس|ست|سبع|ثمان|تسع|عشر)[هي]{0,2}$').hasMatch(t);

  /// نص مطبَّع ونص نظيف بنفس الطول؛ نبدّل الكلمة في الاثنين معاً
  /// فيبقى التوافق في المواضع. التصحيح فقط في سياقات قوية:
  /// وحدة بعد "بعد" (أو بعد "بعد + رقم")، وأيام الأسبوع الطويلة.
  static List<String> _fuzzyFix(String n, String clean) {
    final toks = RegExp(r'\S+').allMatches(n).toList();
    final nb = StringBuffer();
    final cb = StringBuffer();
    var pos = 0;

    for (var i = 0; i < toks.length; i++) {
      final m = toks[i];
      nb.write(n.substring(pos, m.start));
      cb.write(clean.substring(pos, m.start));
      pos = m.end;

      final tok = m.group(0)!;
      String? fix;

      final prev = i > 0 ? toks[i - 1].group(0)! : '';
      final prev2 = i > 1 ? toks[i - 2].group(0)! : '';
      final afterBaad = prev == 'بعد' || (prev2 == 'بعد' && _numberLike(prev));

      if (afterBaad && tok.length >= 3 && !_numberLike(tok)) {
        fix = _nearest(tok, _units, tok.length >= 4 ? 2 : 1);
      } else if (tok.length >= 7) {
        fix = _nearest(tok, _longDays, 1);
      }

      nb.write(fix ?? tok);
      cb.write(fix ?? clean.substring(m.start, m.end));
    }
    nb.write(n.substring(pos));
    cb.write(clean.substring(pos));
    return [nb.toString(), cb.toString()];
  }

  static int _wordNumber(String w) {
    const m = {
      'ثلاث': 3,
      'اربع': 4,
      'خمس': 5,
      'ست': 6,
      'سبع': 7,
      'ثمان': 8,
      'تسع': 9,
      'عشر': 10,
    };
    for (final e in m.entries) {
      if (w.startsWith(e.key)) return e.value;
    }
    return 1;
  }

  static int _amount(String s) {
    if (s == 'نصف') return 30;
    if (s == 'ربع') return 15;
    if (s == 'ثلث') return 20;
    return int.tryParse(s) ?? 0;
  }

  // ---------- التحليل ----------
  ParsedReminder parse(String input, {DateTime? now}) {
    final ref = now ?? DateTime.now();

    // نص نظيف (بدون تشكيل) + نسخة مطبّعة بنفس الطول للمطابقة
    var clean = input
        .replaceAll(RegExp('[\u064B-\u065F\u0670\u0640]'), '')
        .replaceAll(RegExp(r'[،,.!؟?؛;]'), ' ');
    var n = _normalize(clean);

    // تصحيح تقريبي لكلمات الوقت المشوّهة قليلاً (مثل: دقيك، ساعتيين)
    final fx = _fuzzyFix(n, clean);
    n = fx[0];
    clean = fx[1];

    final remove = List<bool>.filled(n.length, false);
    void cut(int s, int e) {
      for (var i = s; i < e && i < remove.length; i++) {
        remove[i] = true;
      }
    }

    Match? take(RegExp r, {int from = 0, int? to}) {
      final end = to ?? n.length;
      final m = r.firstMatch(n.substring(from, end));
      if (m == null) return null;
      cut(from + m.start, from + m.end);
      return m;
    }

    ParsedReminder build(DateTime? dt, {bool assumed = false}) {
      // نحذف أوامر مثل "ذكرني"
      take(
        _w(
          r'[ذد]كرني|[ذد]كريني|نبهني|نبهيني|لا\s+تنسى|لا\s+تنسي|اريد\s+ان|اريد',
        ),
      );
      final buf = StringBuffer();
      for (var i = 0; i < clean.length; i++) {
        buf.write(remove[i] ? ' ' : clean[i]);
      }
      var task = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      task = task
          .replaceAll(RegExp(r'^(?:(?:في|عند|على|ان|و|من|ما)\s+)+'), '')
          .replaceAll(RegExp(r'(?:\s+(?:في|عند|على|و|من|ما))+$'), '')
          .trim();
      return ParsedReminder(
        task: task.isEmpty ? input.trim() : task,
        dateTime: dt,
        originalText: input,
        timeAssumed: assumed,
      );
    }

    // 1) مدة نسبية: بعد ساعتين / بعد 10 دقائق / بعد ثلاث ساعات / بعد نصف ساعة
    final rel = take(
      _w(
        r'بعد\s+(?:(\d+|(?:ثلاث|اربع|خمس|ست|سبع|ثمان|تسع|عشر)[هي]{0,2})\s+)?'
        r'(ساعتين|دقيقتين|يومين|اسبوعين|نصف\s+ساعه|ساعات|ساعه|ساع|دقائق|دقايق|دقيقه|دقيق|'
        r'ايام|يوم|ثواني|ثانيه|اسابيع|اسبوع)(?:\s+واحد[هة]?)?',
      ),
    );
    if (rel != null) {
      final numText = rel.group(1);
      final unit = rel.group(2)!.replaceAll(RegExp(r'\s+'), ' ');
      final count = numText == null
          ? 1
          : (int.tryParse(numText) ?? _wordNumber(numText));
      Duration d;
      if (unit == 'نصف ساعه') {
        d = const Duration(minutes: 30);
      } else if (unit == 'ساعتين') {
        d = const Duration(hours: 2);
      } else if (unit == 'دقيقتين') {
        d = const Duration(minutes: 2);
      } else if (unit == 'يومين') {
        d = const Duration(days: 2);
      } else if (unit == 'اسبوعين') {
        d = const Duration(days: 14);
      } else if (unit.startsWith('ساع')) {
        d = Duration(hours: count);
      } else if (unit.startsWith('دق')) {
        d = Duration(minutes: count);
      } else if (unit.startsWith('ثا') || unit.startsWith('ثو')) {
        d = Duration(seconds: count);
      } else if (unit.startsWith('اسب')) {
        d = Duration(days: 7 * count);
      } else {
        d = Duration(days: count);
      }
      return build(ref.add(d));
    }

    // 2) اليوم
    final todayDate = DateTime(ref.year, ref.month, ref.day);
    var day = todayDate;
    var hasDay = false, isToday = false, explicitWeekday = false, night = false;

    DateTime plus(int k) =>
        DateTime(todayDate.year, todayDate.month, todayDate.day + k);

    if (take(_w(r'بعد\s+(?:بكره|غدا|غد)')) != null) {
      day = plus(2);
      hasDay = true;
    } else if (take(_w(r'بكره|غدا|غد|باجر|باچر')) != null) {
      day = plus(1);
      hasDay = true;
    } else if (take(_w('اليوم')) != null) {
      isToday = true;
      hasDay = true;
    } else if (take(_w('الليله')) != null) {
      isToday = true;
      hasDay = true;
      night = true;
    } else {
      final wm = take(
        _w(
          r'(?:يوم\s+)?(الاثنين|الثلاثاء|الاربعاء|الخميس|الجمعه|السبت|الاحد)'
          r'(?:\s+(?:الجاي|الجايه|القادم|القادمه))?',
        ),
      );
      if (wm != null) {
        final wd = _weekdays[wm.group(1)!]!;
        day = plus((wd - ref.weekday + 7) % 7);
        hasDay = true;
        explicitWeekday = true;
      }
    }

    // 3) الساعة
    final timeRe = _w(
      'الساعه\\s*(?:(\\d{1,2})(?::(\\d{2}))?|($_hourWords))'
      '(?:\\s+و\\s*(?:ال)?(نصف|ربع|ثلث|\\d{1,2})(?:\\s+(?:دقيقه|دقائق|دقايق))?'
      '|\\s+الا\\s+(?:ال)?(نصف|ربع|ثلث|\\d{1,2}))?',
    );
    var tm = take(timeRe);
    int? h;
    var mi = 0;

    if (tm != null) {
      h = tm.group(1) != null ? int.parse(tm.group(1)!) : _hours[tm.group(3)!]!;
      if (tm.group(2) != null) mi = int.parse(tm.group(2)!);
      if (tm.group(4) != null) mi = _amount(tm.group(4)!);
      if (tm.group(5) != null) {
        h = h - 1;
        if (h < 1) h = 12;
        mi = 60 - _amount(tm.group(5)!);
      }
    } else {
      tm = take(RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?!\d)'));
      if (tm != null) {
        h = int.parse(tm.group(1)!);
        mi = int.parse(tm.group(2)!);
      }
    }

    if (h == null) {
      // لا ساعة: إن ذُكر يوم قادم نفترض 9 صباحاً
      if (hasDay && !isToday) {
        return build(DateTime(day.year, day.month, day.day, 9), assumed: true);
      }
      return build(null);
    }

    // الفترة (صباحاً/مساءً...) بالقرب من الساعة فقط
    final lo = tm!.start - 14 < 0 ? 0 : tm.start - 14;
    final hi = tm.end + 14 > n.length ? n.length : tm.end + 14;
    final pmM = take(
      _w('(?:ال)?(?:مساء|مساءا|عصرا|عصر|ظهرا|ظهر|مغرب|عشاء)'),
      from: lo,
      to: hi,
    );
    final niM = take(_w('(?:ال)?(?:ليلا|ليل)'), from: lo, to: hi);
    final amM = take(
      _w('(?:ال)?(?:صباحا|صباح|صبح|فجرا|فجر)'),
      from: lo,
      to: hi,
    );
    if (niM != null) night = true;

    int hh;
    if (h > 12 || h == 0) {
      hh = h;
    } else if (amM != null) {
      hh = h == 12 ? 0 : h;
    } else if (night) {
      hh = h == 12 ? 0 : (h >= 6 ? h + 12 : h);
    } else if (pmM != null) {
      hh = h < 12 ? h + 12 : 12;
    } else {
      final futureDay = hasDay && !isToday && day.isAfter(todayDate);
      if (futureDay) {
        hh = (h >= 1 && h <= 6) ? h + 12 : h;
      } else {
        final cands = h == 12 ? [0, 12] : [h, h + 12];
        hh = cands.firstWhere(
          (c) => DateTime(day.year, day.month, day.day, c, mi).isAfter(ref),
          orElse: () => cands.first,
        );
      }
    }

    var result = DateTime(day.year, day.month, day.day, hh, mi);
    if (!result.isAfter(ref)) {
      if (explicitWeekday) {
        result = result.add(const Duration(days: 7));
      } else if (!hasDay) {
        result = result.add(const Duration(days: 1));
      } else {
        return build(null); // "اليوم" والوقت قد مضى
      }
    }
    return build(result);
  }

  List<ParsedReminder> parseMultiple(String input, {DateTime? now}) {
    final parts = input
        .split(
          RegExp(
            r'[،,؛;\n]+|\s+(?:ثم|وبعدها|بعدها|وبعدين)\s+|\s+و(?=(?:اتصل|أتصل|اراجع|أراجع|راجع|اشرب|أشرب|اذهب|أذهب|اروح|أروح|اشتري|أشتري|اقرأ|أقرأ|ادرس|أدرس|ارسل|أرسل|احضر|أحضر|اتناول|أتناول|تناول|قابل|أقابل|زور|أزور)(?:\s|$))',
          ),
        )
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.isEmpty) {
      return [];
    }

    final results = <ParsedReminder>[];

    for (final part in parts) {
      final cleaned = part.replaceFirst(RegExp(r'^و(?=[ء-ي])'), '').trim();

      if (cleaned.isEmpty) continue;

      results.add(parse(cleaned, now: now));
    }

    return results;
  }
}
