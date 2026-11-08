import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yamp/app.dart';
import 'package:yamp/core/core.dart';
import 'package:yamp/core/fake_core.dart';
import 'package:yamp/state/controller.dart';
import 'package:yamp/state/player.dart';
import 'package:yamp/state/models.dart';
import 'package:yamp/state/search.dart';
import 'package:yamp/ui/search_view.dart';

Future<(FakeCore, Controller)> _open(
  WidgetTester tester, {
  String latest = '0.2.1',
  Duration tick = const Duration(milliseconds: 120),
}) async {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final core = FakeCore(latest: latest, tick: tick);
  final controller = Controller(core);
  await tester.pumpWidget(YmdApp(controller: controller));
  await tester.pumpAndSettle();
  return (core, controller);
}

Future<void> _login(WidgetTester tester, String token) async {
  final manual = find.text('Вставить токен вручную');
  if (manual.evaluate().isNotEmpty) {
    await tester.tap(manual);
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byType(TextField), token);
  await tester.pump();
  await tester.tap(find.text('Войти'));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Finder button, String item) async {
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

const _album = 'https://music.yandex.ru/album/9';

class _DeadCore implements Core {
  @override
  Stream<Event> get events => Stream.value({
        'type': 'coreExited',
        'code': 2,
        'stderr': 'panic: boom\n\ngoroutine 1 [running]:\n',
      });

  @override
  void send(Map<String, Object?> command) {}

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('вывод упавшего ядра попадает в журнал', (tester) async {
    final controller = Controller(_DeadCore());
    await tester.pumpWidget(YmdApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Ядро остановилось (код 2).'), findsOneWidget);
    expect(controller.log.value, contains('panic: boom'));
    expect(find.text('Скопировать журнал'), findsOneWidget);
  });

  testWidgets('без входа виден только экран входа', (tester) async {
    final (core, c) = await _open(tester);

    expect(c.ready, isTrue);
    expect(c.version, '0.2.1');
    expect(find.text('Войти через Яндекс'), findsOneWidget);
    expect(find.text('Моя волна'), findsNothing);

    await core.close();
  });

  testWidgets('вход по коду: код на экране, копирование и вход после подтверждения', (tester) async {
    final (core, c) = await _open(tester);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add('${(call.arguments as Map)['text']}');
      return null;
    });

    await tester.tap(find.text('Войти через Яндекс'));
    await tester.pump();
    expect(find.text('Получаю код…'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('abcd 1234'), findsOneWidget);
    expect(find.text('Открыть ya.ru/device'), findsOneWidget);
    expect(find.textContaining('Жду подтверждения, код действует 4:5'), findsOneWidget);

    await tester.tap(find.text('Скопировать код'));
    await tester.pump();
    expect(copied, ['abcd1234']);
    expect(find.text('Код скопирован'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2600));
    expect(find.text('Проверяю подписку…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(c.canDownload, isTrue);
    expect(find.text('Моя волна'), findsOneWidget);

    await core.close();
  });

  testWidgets('вход по коду можно отменить и войти по токену', (tester) async {
    final (core, c) = await _open(tester);

    await tester.tap(find.text('Войти через Яндекс'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Отмена'));
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Войти через Яндекс'), findsOneWidget);
    expect(c.canDownload, isFalse);

    await tester.tap(find.text('Вставить токен вручную'));
    await tester.pumpAndSettle();
    expect(find.text('Вход по токену'), findsOneWidget);
    await tester.tap(find.text('Войти по коду'));
    await tester.pumpAndSettle();
    expect(find.text('Войти через Яндекс'), findsOneWidget);

    await core.close();
  });

  testWidgets('без Плюса скачивание недоступно', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'noplus');

    expect(c.account.status, AccountStatus.noplus);
    expect(c.canDownload, isFalse);
    expect(find.text('Оформить Плюс'), findsOneWidget);
    expect(find.text('Моя волна'), findsNothing);

    await core.close();
  });

  testWidgets('неверный токен показывает ошибку', (tester) async {
    final (core, _) = await _open(tester);
    await _login(tester, 'bad');

    expect(find.textContaining('недействителен'), findsOneWidget);
    expect(find.text('Войти'), findsOneWidget);

    await core.close();
  });

  testWidgets('проверка подписки не уводит с главного экрана', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await tester.tap(find.text('Иван Петров'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Проверить подписку'));
    await tester.pump();
    expect(find.text('Моя волна'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(c.canDownload, isTrue);
    expect(find.text('Моя волна'), findsOneWidget);
    expect(find.text('Подписка Плюс активна'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await core.close();
  });

  testWidgets('в настройках можно проверить обновления', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Качество звука'), findsOneWidget);
    await tester.tap(find.text('О программе'));
    await tester.pumpAndSettle();
    expect(find.text('Версия 0.2.1'), findsOneWidget);

    await tester.tap(find.text('Проверить'));
    await tester.pump();
    expect(find.text('Проверяю обновления…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(c.update?.available, isFalse);
    expect(find.text('Это последняя версия'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await core.close();
  });

  testWidgets('настройки: авто-качество и ручной выбор', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi и кабель'), findsOneWidget);
    expect(find.text('Мобильный интернет'), findsOneWidget);
    await tester.tap(find.text('Эконом').last);
    await tester.pumpAndSettle();
    expect(core.playQuality.last, {'cmd': 'playQuality', 'mobile': 'low'});
    expect(c.playMobile, PlayQuality.low);

    await tester.tap(find.text('Вручную'));
    await tester.pumpAndSettle();
    expect(core.playQuality.last, containsPair('auto', false));
    expect(find.text('Всегда'), findsOneWidget);
    expect(find.text('Wi-Fi и кабель'), findsNothing);
    await tester.tap(find.text('MP3 320'));
    await tester.pumpAndSettle();
    expect(core.playQuality.last, {'cmd': 'playQuality', 'auto': false, 'quality': 'mp3'});

    await tester.tap(find.text('Загрузки'));
    await tester.pumpAndSettle();
    expect(find.text('Одновременных загрузок'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Одновременных загрузок'), findsNothing);
    await core.close();
  });

  testWidgets('настройки: плавные переходы включены, длительность меняется, можно выключить', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');
    expect(c.player.crossfade, const Duration(seconds: 6));

    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Slider));
    await tester.pumpAndSettle();
    expect(find.text('6 с'), findsOneWidget);
    await tester.drag(find.byType(Slider), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(c.fade, 12);
    expect(c.player.crossfade, const Duration(seconds: 12));
    expect(find.text('12 с'), findsOneWidget);

    await tester.tap(find.text('Плавные переходы'));
    await tester.pumpAndSettle();
    expect(c.crossfade, isFalse);
    expect(c.player.crossfade, Duration.zero);
    expect(find.byType(Slider), findsNothing);

    await tester.tap(find.text('Плавные переходы'));
    await tester.pumpAndSettle();
    expect(c.player.crossfade, const Duration(seconds: 12));
    await core.close();
  });

  testWidgets('настройки на телефоне: список разделов и назад', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');
    tester.view.physicalSize = const Size(360, 760);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Меню'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Прослушивание'), findsOneWidget);
    expect(find.text('Авто: Wi-Fi FLAC, мобильный MP3 320'), findsOneWidget);
    await tester.tap(find.text('Оформление'));
    await tester.pumpAndSettle();
    expect(find.text('Светлая'), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('О программе'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('О программе'), findsNothing);
    await core.close();
  });

  testWidgets('новая версия предлагается при запуске', (tester) async {
    final (core, c) = await _open(tester, latest: '2.3.0');

    expect(find.text('Доступна версия 2.3.0'), findsNothing);
    await _login(tester, 'good-token');
    expect(find.text('Доступна версия 2.3.0'), findsOneWidget);
    expect(find.text('Самообновление из релизов GitHub.'), findsOneWidget);

    await tester.tap(find.text('Обновить'));
    await tester.pump();
    expect(c.updating, isTrue);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(c.updateProgress.value, 1.0);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await core.close();
  });

  testWidgets('поиск: раздел целиком, догрузка и исправление опечатки', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await tester.enterText(find.byType(TextField), 'кина');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('«кино»'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Треки'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(c.search.filter, ReleaseKind.track);
    expect(c.search.results?[ReleaseKind.track]?.hits, hasLength(10));

    await tester.scrollUntilVisible(find.text('Показать ещё'), 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Показать ещё'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(c.search.results?[ReleaseKind.track]?.hits, hasLength(20));

    await tester.tap(find.widgetWithText(ChoiceChip, 'Всё'));
    await tester.pumpAndSettle();
    expect(find.text('Лучший результат'), findsOneWidget);

    await tester.tap(find.text('«кино»'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(c.search.query, 'кино');
    expect(find.text('«кино»'), findsNothing);

    Focus.of(tester.element(find.descendant(of: find.byType(ChoiceChip), matching: find.text('Треки')))).requestFocus();
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(c.search.open, isFalse);
    expect(find.text('Моя волна'), findsOneWidget);

    await core.close();
  });

  testWidgets('ссылка на альбом открывает страницу, «Скачать» качает в выбранном качестве', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');
    expect(find.text('Плюс'), findsOneWidget);

    await _enter(tester, '$_album https://music.yandex.ru/album/10');
    expect(c.player.browse.value, _album);
    expect(c.search.open, isFalse);
    expect(find.text('Открыл первую ссылку из вставленных'), findsOneWidget);
    expect(find.text('Группа крови'), findsWidgets);

    await _choose(tester, find.byTooltip('Скачать'), 'Скачать MP3 320');
    expect(core.lastDownload, {'cmd': 'download', 'link': _album, 'quality': 'mp3'});
    expect(find.text('Скачиваю «Группа крови» в MP3 320'), findsOneWidget);
    expect(c.jobs, hasLength(1));
    expect(c.downloadsOpen.value, isFalse);

    await tester.tap(find.widgetWithText(SnackBarAction, 'Загрузки'));
    await tester.pumpAndSettle();
    expect(c.downloadsOpen.value, isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(c.jobs.first.status, JobStatus.done);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(c.downloadsOpen.value, isFalse);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await core.close();
  });

  testWidgets('ссылка на трек сразу включает его', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await _enter(tester, '$_album/track/2');
    expect(c.player.track?.id, '2');
    expect(c.search.open, isFalse);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await core.close();
  });

  testWidgets('«Мне нравится» и отдельный трек качаются из меню', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');
    await tester.tap(find.text('Мне нравится'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await _choose(tester, find.byTooltip('Скачать'), 'Скачать FLAC');
    expect(core.lastDownload, {'cmd': 'download', 'link': 'liked', 'quality': 'lossless'});
    expect(find.text('Скачиваю «Мне нравится» в FLAC'), findsOneWidget);

    await _choose(tester, find.byTooltip('Ещё').first, 'Скачать MP3 320');
    expect(core.lastDownload, {'cmd': 'download', 'link': '$_album/track/1', 'quality': 'mp3'});
    expect(c.jobs, hasLength(2));

    await tester.pumpAndSettle(const Duration(seconds: 10));
    await core.close();
  });

  testWidgets('у исполнителя качается вся дискография', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    const artist = 'https://music.yandex.ru/artist/1';
    await _enter(tester, artist);
    expect(find.text('Альбомы'), findsOneWidget);

    await _choose(tester, find.byTooltip('Скачать дискографию'), 'Скачать FLAC');
    expect(core.lastDownload?['link'], artist);
    expect(c.jobs.single.tracks, hasLength(12));

    await tester.pumpAndSettle(const Duration(seconds: 10));
    await core.close();
  });

  testWidgets('выход во время загрузки нужно подтвердить', (tester) async {
    final (core, c) = await _open(tester, tick: const Duration(seconds: 30));
    await _login(tester, 'good-token');
    c.download(_album, Quality.lossless);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    Future<void> logout() async {
      await tester.tap(find.text('Иван Петров'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Выйти'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.running, 1);
      expect(find.text('Выйти из аккаунта?'), findsOneWidget);
    }

    await logout();
    await tester.tap(find.text('Отмена'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.canDownload, isTrue);

    await logout();
    await tester.tap(find.widgetWithText(FilledButton, 'Выйти'));
    await tester.pumpAndSettle();
    expect(c.canDownload, isFalse);
    expect(find.text('Войти через Яндекс'), findsOneWidget);

    await core.close();
  });

  testWidgets('поиск по названию: живые результаты, слушать и скачать', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await tester.enterText(find.byType(TextField), 'кино');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(c.search.open, isTrue);
    expect(c.section.value, Section.search);
    expect(find.text('Моя волна'), findsNothing);
    expect(find.text('Лучший результат'), findsOneWidget);
    expect(find.text('Война'), findsOneWidget);

    await _choose(
      tester,
      find.descendant(of: find.byType(BestCard), matching: find.byTooltip('Скачать')),
      'Скачать FLAC',
    );
    expect(core.lastDownload, {'cmd': 'download', 'link': 'https://music.yandex.ru/artist/1', 'quality': 'lossless'});

    await _choose(
      tester,
      find.descendant(of: find.byType(HitRow).first, matching: find.byTooltip('Скачать')),
      'Скачать MP3 320',
    );
    expect(core.lastDownload?['quality'], 'mp3');
    expect(c.jobs, hasLength(2));

    await tester.tap(find.byType(HitCard).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(c.section.value, Section.home);
    expect(c.search.open, isTrue);
    expect(find.text('Лучший результат'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(c.section.value, Section.search);
    expect(find.text('Лучший результат'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть поиск'));
    await tester.pumpAndSettle();
    expect(c.search.open, isFalse);
    expect(find.text('Моя волна'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 10));
    await core.close();
  });

  testWidgets('поиск: пусто, ошибка и ссылка в том же поле', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');

    await _enter(tester, 'пусто');
    expect(find.text('Ничего не нашлось'), findsOneWidget);

    await _enter(tester, 'ошибка');
    expect(find.text('Поиск не удался'), findsOneWidget);
    expect(c.search.results?.status, SearchStatus.error);

    await _enter(tester, _album);
    expect(c.search.open, isFalse);
    expect(c.player.browse.value, _album);

    await core.close();
  });
  testWidgets('главная: подборки, история, чарт и новинки', (tester) async {
    final (core, c) = await _open(tester);
    await _login(tester, 'good-token');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(c.player.browse.value, 'home');
    for (final title in ['Для вас', 'Вы недавно слушали', 'Чарт']) {
      expect(find.text(title), findsOneWidget);
    }
    expect(find.text('Плейлист дня'), findsOneWidget);
    expect(find.text('Хит 1'), findsOneWidget);
    final feed = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;
    await tester.scrollUntilVisible(find.text('Новые плейлисты'), 200, scrollable: feed);
    expect(find.text('Новые релизы'), findsOneWidget);
    expect(find.text('Новинка 1'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Хит 2'), -200, scrollable: feed);

    await tester.tap(find.text('Хит 2'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(c.player.track?.id, 'c2');
    expect(c.player.source?.kind, 'chart');

    await tester.scrollUntilVisible(find.text('Весь чарт'), -200, scrollable: feed);
    await tester.tap(find.text('Весь чарт'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(c.player.browse.value, 'chart');
    expect(find.text('ЧАРТ'), findsOneWidget);
    await _choose(tester, find.byTooltip('Скачать'), 'Скачать MP3 320');
    expect(core.lastDownload, {'cmd': 'download', 'link': 'chart', 'quality': 'mp3'});

    await tester.tap(find.text('Назад'));
    await tester.pumpAndSettle();
    expect(c.player.browse.value, 'home');

    await tester.scrollUntilVisible(find.text('Ночь'), -200, scrollable: feed);
    await tester.tap(find.text('Ночь'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(c.player.browse.value, 'https://music.yandex.ru/album/77');
    await tester.tap(find.text('Главная'));
    await tester.pumpAndSettle();
    expect(c.player.browse.value, 'home');
    expect(find.text('Ночь'), findsOneWidget);

    await tester.pumpAndSettle(const Duration(seconds: 5));
    await core.close();
  });
}
