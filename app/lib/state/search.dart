import 'dart:async';

import 'package:flutter/widgets.dart';

import 'models.dart';

int _int(Object? v) => v is num ? v.toInt() : 0;
String _str(Object? v) => v == null ? '' : '$v';

final _linkToken = RegExp(r'yandex\.|://');

bool looksLikeLinks(String text) => _linkToken.hasMatch(text);

final _separators = RegExp(r'[\s,;]+');

List<String> splitLinks(String text) => {
  for (final t in text.split(_separators))
    if (t.contains('yandex.') || t.contains('://')) t,
}.toList();

class SearchHit {
  SearchHit.fromJson(Map<String, dynamic> j)
    : kind = ReleaseKind.parse(j['kind']),
      id = _str(j['id']),
      title = _str(j['title']),
      artist = _str(j['artist']),
      album = _str(j['album']),
      year = _int(j['year']),
      cover = _str(j['cover']),
      count = _int(j['count']),
      type = _str(j['type']),
      duration = _int(j['duration']),
      explicit = j['explicit'] == true,
      link = _str(j['link']);

  final ReleaseKind kind;
  final String id, title, artist, album, cover, type, link;
  final int year, count, duration;
  final bool explicit;
}

class SearchSection {
  SearchSection.fromJson(Map<String, dynamic> j)
    : total = _int(j['total']),
      more = j['more'] == true,
      hits = [
        for (final h in (j['hits'] as List? ?? const []))
          if (h is Map<String, dynamic>) SearchHit.fromJson(h),
      ];

  final int total;
  bool more;
  final List<SearchHit> hits;
}

enum SearchStatus { loading, ok, error }

class SearchResults {
  var status = SearchStatus.loading;
  var message = '';
  var corrected = '';
  var page = 0;
  var loadingMore = false;
  SearchHit? best;
  var sections = <ReleaseKind, SearchSection>{};

  SearchSection? operator [](ReleaseKind k) => sections[k];

  bool get empty => best == null && sections.values.every((s) => s.hits.isEmpty);
}

const searchKinds = [ReleaseKind.track, ReleaseKind.album, ReleaseKind.artist, ReleaseKind.playlist];

class SearchState extends ChangeNotifier {
  SearchState(this._send, {this.delay = const Duration(milliseconds: 400)}) {
    input.addListener(_typed);
  }

  final void Function(Map<String, Object?>) _send;
  final Duration delay;
  final input = TextEditingController();

  var open = false;
  var query = '';
  ReleaseKind? filter;
  final _views = <ReleaseKind?, SearchResults>{};
  var _seq = 0;
  ({ReleaseKind? kind, int page})? _pending;
  Timer? _debounce;
  var _lastText = '';

  SearchResults? get results => _views[filter];

  SearchResults? get all => _views[null];

  void _typed() {
    final text = input.text;
    if (text == _lastText) return;
    _lastText = text;
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) {
      close();
      return;
    }
    if (looksLikeLinks(q) || q.length < 2 || q == query) return;
    _debounce = Timer(delay, () => run(q));
  }

  void run(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q.isEmpty) return;
    if (q == query && open && results?.status != SearchStatus.error) return;
    query = q;
    open = true;
    filter = null;
    _views.clear();
    _request(null, 0);
  }

  void retry() {
    if (query.isEmpty) return;
    _request(filter, results?.page ?? 0);
  }

  void setFilter(ReleaseKind? k) {
    if (filter == k) return;
    filter = k;
    final v = _views[k];
    if (v == null || v.status == SearchStatus.error) {
      _request(k, 0);
    } else {
      notifyListeners();
    }
  }

  void more() {
    final k = filter, v = results;
    if (k == null || v == null || v.loadingMore || !(v[k]?.more ?? false)) return;
    _request(k, v.page + 1);
  }

  void _request(ReleaseKind? kind, int page) {
    _seq++;
    _pending = (kind: kind, page: page);
    if (page == 0) {
      _views[kind] = SearchResults();
    } else {
      _views[kind]?.loadingMore = true;
    }
    _send({'cmd': 'search', 'seq': _seq, 'query': query, 'kind': kind?.name ?? '', 'page': page});
    notifyListeners();
  }

  void close() {
    _debounce?.cancel();
    final was = open;
    open = false;
    query = '';
    filter = null;
    _views.clear();
    _pending = null;
    _seq++;
    if (input.text.isNotEmpty && !looksLikeLinks(input.text)) input.clear();
    if (was) notifyListeners();
  }

  void receive(Map<String, dynamic> ev) {
    final p = _pending;
    if (p == null || ev['seq'] != _seq) return;
    _pending = null;
    final v = _views[p.kind];
    if (v == null) return;
    v.loadingMore = false;
    if (ev['status'] != 'ok') {
      if (p.page == 0) {
        v.status = SearchStatus.error;
        v.message = _str(ev['message']);
      }
      notifyListeners();
      return;
    }
    final sections = <ReleaseKind, SearchSection>{
      for (final MapEntry(:key, :value) in (ev['sections'] as Map? ?? const {}).entries)
        if (value is Map<String, dynamic>) ReleaseKind.parse(key): SearchSection.fromJson(value),
    };
    if (p.page == 0) {
      v.status = SearchStatus.ok;
      v.corrected = _str(ev['corrected']);
      final best = ev['best'];
      v.best = best is Map<String, dynamic> ? SearchHit.fromJson(best) : null;
      v.sections = sections;
    } else {
      final k = p.kind!;
      final add = sections[k];
      final have = v.sections[k];
      if (add != null && have != null) {
        final seen = {for (final h in have.hits) h.link};
        have.hits.addAll(add.hits.where((h) => seen.add(h.link)));
        have.more = add.more && add.hits.isNotEmpty;
      }
      v.page = p.page;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    input.removeListener(_typed);
    input.dispose();
    super.dispose();
  }
}
