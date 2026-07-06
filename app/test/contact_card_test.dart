// SPDX-License-Identifier: AGPL-3.0-or-later
// Contact cards: the codec round-trips (like the invite/mnemonic codecs), and
// accepting a card drives the real DM-bootstrap wiring (add contact + openDm)
// through the app widget tree — the live rendezvous is gated off in tests, so
// this covers everything up to the point a relay would take over.
import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';
import 'package:hearth/contact_card.dart';
import 'package:hearth/group_channel.dart';
import 'package:hearth/main.dart';

final warnings = <String>{};
const testPubkeyHex =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const testRendezvousHex = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void _drain(WidgetTester tester) {
  for (
    Object? e = tester.takeException();
    e != null;
    e = tester.takeException()
  ) {
    warnings.add(e.toString().split('\n').first);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  _drain(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  _drain(tester);
  expect(warnings, isEmpty, reason: 'unexpected framework warnings: $warnings');
}

void main() {
  setUp(warnings.clear);

  group('codec', () {
    test('round-trips all fields', () {
      final card = ContactCard(
        pubkey: testPubkeyHex,
        rendezvous: testRendezvousHex,
        name: 'Sam',
        relayUrl: 'https://relay.example',
      );
      final back = ContactCard.decode(card.encode())!;
      expect(back.pubkey, testPubkeyHex);
      expect(back.rendezvous, testRendezvousHex);
      expect(back.name, 'Sam');
      expect(back.relayUrl, 'https://relay.example');
    });

    test('round-trips with only the required fields', () {
      final back = ContactCard.decode(
        ContactCard(
          pubkey: testPubkeyHex,
          rendezvous: testRendezvousHex,
        ).encode(),
      )!;
      expect(back.pubkey, testPubkeyHex);
      expect(back.rendezvous, testRendezvousHex);
      expect(back.name, isNull);
      expect(back.relayUrl, isNull);
    });

    test('encodes under the hearth-contact: scheme', () {
      expect(
        ContactCard(
          pubkey: testPubkeyHex,
          rendezvous: testRendezvousHex,
        ).encode(),
        startsWith('hearth-contact:'),
      );
    });

    test('newRendezvousId is 16 bytes of hex and unguessably unique', () {
      final a = ContactCard.newRendezvousId();
      final b = ContactCard.newRendezvousId();
      expect(a, hasLength(32));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });

    test('rejects a channel invite, empty, and junk', () {
      final invite = GroupChannel.create(
        'games',
      ).invite(inviterPubkeyHex: testPubkeyHex);
      expect(ContactCard.decode(invite), isNull); // not our scheme
      expect(
        GroupChannel.fromInvite(invite),
        isNotNull,
      ); // still a valid invite
      expect(ContactCard.decode(''), isNull);
      expect(ContactCard.decode('hearth-contact:not-base64!!'), isNull);
      expect(ContactCard.decode('hearth-contact:'), isNull);
    });

    test('rejects a card missing pubkey or rendezvous', () {
      // Hand-craft a card body with an empty rendezvous.
      final bad = ContactCard(pubkey: testPubkeyHex, rendezvous: '').encode();
      // Empty rv is dropped from JSON, so it must fail to parse.
      expect(ContactCard.decode(bad), isNull);
    });

    test('rejects malformed pubkey and rendezvous capabilities', () {
      expect(
        ContactCard.decode(
          ContactCard(
            pubkey: 'not-hex',
            rendezvous: testRendezvousHex,
          ).encode(),
        ),
        isNull,
      );
      expect(
        ContactCard.decode(
          ContactCard(pubkey: testPubkeyHex, rendezvous: 'too-short').encode(),
        ),
        isNull,
      );
    });
  });

  testWidgets('accepting a card adds the contact and opens a DM', (
    tester,
  ) async {
    final api = HearthTestApi();
    await tester.pumpWidget(
      HearthApp(keyStore: InMemoryKeyStore(), autoPoll: false, testApi: api),
    );
    await _settle(tester);

    // A card from a second identity (someone we share no group with).
    final peer = await Identity.loadOrCreate(InMemoryKeyStore());
    final card = ContactCard(
      pubkey: peer.publicKeyHex,
      rendezvous: ContactCard.newRendezvousId(),
      name: 'Pat',
    ).encode();

    final ok = await api.acceptCard(card);
    expect(ok, isTrue, reason: 'a valid card is accepted');
    await _settle(tester);

    // A DM session for that peer now exists (the derived DM channel is active)
    // — a person we shared no group with is now reachable purely from the card.
    final dm = api.activeChannel();
    expect(dm, isNotNull);
    expect(dm!.isDm, isTrue);
    expect(dm.peerPubkey, peer.publicKey);

    await _finish(tester);
  });

  test('block closes a DM and openDm refuses a blocked peer', () async {
    // Tested at the ChannelManager level (no widget tree) — the block→close-DM
    // mechanism: openDm opens when clear, leave closes it, and once blocked
    // openDm refuses so no session (hence no ingestion/storage) exists.
    final me = await Identity.generate();
    final peer = await Identity.generate();
    final blocked = <String>{};
    final cm = ChannelManager(
      identity: me,
      relayUrl: Uri.parse('http://localhost:8787'),
      live: false, // in-memory, no mesh
      onUpdate: () {},
      isBlocked: blocked.contains,
    );

    await cm.openDm(peer.publicKey);
    expect(cm.active?.peerPubkey, peer.publicKey, reason: 'opens when clear');

    // Block + close, as _blockPeer does.
    blocked.add(peer.publicKeyHex);
    await cm.leave(await dmChannelId(me.publicKeyHex, peer.publicKeyHex));
    expect(
      cm.sessions.where((s) => s.isDm),
      isEmpty,
      reason: 'the blocked peer\'s DM session is closed',
    );

    // Reopen is refused while blocked → still no DM session.
    await cm.openDm(peer.publicKey);
    expect(
      cm.sessions.where((s) => s.isDm),
      isEmpty,
      reason: 'openDm refuses a blocked peer',
    );
    await cm.close();
  });

  testWidgets('accepting your own card is refused', (tester) async {
    final api = HearthTestApi();
    final store = InMemoryKeyStore();
    await tester.pumpWidget(
      HearthApp(keyStore: store, autoPoll: false, testApi: api),
    );
    await _settle(tester);

    // Create a channel to expose the active session (which reveals the identity).
    await tester.tap(find.widgetWithText(FilledButton, 'Create a channel'));
    await _settle(tester);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'test',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await _settle(tester);

    // Get the identity from a sent message's author.
    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await _settle(tester);
    final session = api.activeChannel()!;
    final myHex = hex.encode(session.repository.ordered().last.author);

    final ownCard = ContactCard(
      pubkey: myHex,
      rendezvous: ContactCard.newRendezvousId(),
    ).encode();
    await api.acceptCard(ownCard);
    await _settle(tester);

    // Still on the group channel, no DM opened to yourself.
    expect(api.activeChannel()?.isDm ?? false, isFalse);
    await _finish(tester);
  });
}
