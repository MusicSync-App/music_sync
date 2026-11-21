import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/youtube/playlist_save_logic.dart';

void main() {
  group('parseNowPlaying', () {
    test('splits artist and title', () {
      expect(parseNowPlaying('Tarkan - Şımarık'), const SongQuery(artist: 'Tarkan', title: 'Şımarık'));
      expect(parseNowPlaying("StreamTitle='Sezen Aksu – Gidiyorum';"),
          const SongQuery(artist: 'Sezen Aksu', title: 'Gidiyorum'));
      expect(parseNowPlaying('Νίκος Βέρτης - Θέλω να σε δω  '),
          const SongQuery(artist: 'Νίκος Βέρτης', title: 'Θέλω να σε δω'));
    });

    test('keeps dashes inside the title', () {
      expect(parseNowPlaying('Goran Bregović - Kalashnikov - Live'),
          const SongQuery(artist: 'Goran Bregović', title: 'Kalashnikov - Live'));
    });

    test('ignores empty text, station name and ads', () {
      expect(parseNowPlaying(null), isNull);
      expect(parseNowPlaying('   '), isNull);
      expect(parseNowPlaying('Radio Galaxy', stationName: 'Radio Galaxy'), isNull);
      expect(parseNowPlaying('Reclame'), isNull);
      expect(parseNowPlaying('Advertisement'), isNull);
    });

    test('no separator -> whole text as title', () {
      expect(parseNowPlaying('Misirlou'), const SongQuery(artist: '', title: 'Misirlou'));
    });
  });

  group('rankCandidates', () {
    const q = SongQuery(artist: 'Tarkan', title: 'Şımarık');

    test('prefers the official track over covers, live, long mixes', () {
      final results = [
        const VideoCandidate(id: 'cover', title: 'Şımarık cover by someone', author: 'Guitar Guy', duration: Duration(minutes: 3)),
        const VideoCandidate(id: 'mix', title: 'Tarkan Şımarık 1 hour loop', author: 'Loops', duration: Duration(hours: 1)),
        const VideoCandidate(id: 'live', title: 'Tarkan - Şımarık (Live)', author: 'Fan', duration: Duration(minutes: 4)),
        const VideoCandidate(id: 'topic', title: 'Şımarık', author: 'Tarkan - Topic', duration: Duration(minutes: 3, seconds: 54)),
        const VideoCandidate(id: 'other', title: 'Completely different song', author: 'Somebody', duration: Duration(minutes: 3)),
        const VideoCandidate(id: 'official', title: 'Tarkan - Şımarık (Official Video)', author: 'TarkanVEVO', duration: Duration(minutes: 4)),
      ];
      final ranked = rankCandidates(q, results, take: 3);
      expect(ranked.length, 3);
      expect(ranked.map((c) => c.id).take(2).toSet(), {'official', 'topic'});
      expect(ranked.any((c) => c.id == 'other' || c.id == 'mix'), isFalse);
    });

    test('a "live" query keeps live versions', () {
      const liveQuery = SongQuery(artist: 'Tarkan', title: 'Şımarık live');
      final live = const VideoCandidate(id: 'l', title: 'Tarkan - Şımarık (Live)', author: 'x', duration: Duration(minutes: 4));
      final studio = const VideoCandidate(id: 's', title: 'Tarkan - Şımarık', author: 'x', duration: Duration(minutes: 4));
      expect(scoreCandidate(liveQuery, live), greaterThan(scoreCandidate(liveQuery, studio)));
    });

    test('de-duplicates by id and is stable', () {
      final a = const VideoCandidate(id: 'a', title: 'Tarkan Şımarık', author: 'x');
      final ranked = rankCandidates(q, [a, a, const VideoCandidate(id: 'b', title: 'Tarkan Şımarık', author: 'x')]);
      expect(ranked.map((c) => c.id), ['a', 'b']);
    });
  });

  group('orderTargets (playlist target selection)', () {
    const own1 = PlaylistTarget(id: 'P1', title: 'Greek', itemCount: 10);
    const own2 = PlaylistTarget(id: 'P2', title: 'Turkish', itemCount: 5);
    const collab = PlaylistTarget(id: 'C1', title: 'Shared', owned: false);

    test('owned first, keeps Downloader order', () {
      expect(orderTargets([collab, own1, own2]).map((t) => t.id), ['P1', 'P2', 'C1']);
    });

    test('last used comes first', () {
      expect(orderTargets([collab, own1, own2], lastUsedId: 'P2').map((t) => t.id), ['P2', 'P1', 'C1']);
      expect(orderTargets([collab, own1, own2], lastUsedId: 'C1').first.id, 'C1');
    });

    test('dedupes, preferring the owned variant', () {
      final out = orderTargets([
        const PlaylistTarget(id: 'P1', title: 'Greek (link)', owned: false),
        own1,
        const PlaylistTarget(id: '', title: 'broken'),
      ]);
      expect(out.length, 1);
      expect(out.single.owned, isTrue);
    });

    test('cache JSON round-trip and corrupt input', () {
      final decoded = decodeTargets(encodeTargets([own1, collab]));
      expect(decoded.map((t) => [t.id, t.title, t.itemCount, t.owned]), [
        ['P1', 'Greek', 10, true],
        ['C1', 'Shared', 0, false],
      ]);
      expect(decodeTargets('not json'), isEmpty);
      expect(decodeTargets(null), isEmpty);
    });
  });

  test('write scope detection', () {
    expect(hasYoutubeWriteScope(parseScopeString('$kYoutubeReadonlyScope https://www.googleapis.com/auth/userinfo.email')), isFalse);
    expect(hasYoutubeWriteScope(parseScopeString('$kYoutubeReadonlyScope $kYoutubeScope')), isTrue);
    expect(hasYoutubeWriteScope({kYoutubeForceSslScope}), isTrue);
    expect(parseScopeString(null), isEmpty);
  });

  test('cleanPlaylistName', () {
    expect(cleanPlaylistName('   '), isNull);
    expect(cleanPlaylistName('  Radio   finds <3 '), 'Radio finds 3');
    expect(cleanPlaylistName('x' * 200)!.length, 150);
  });
}
