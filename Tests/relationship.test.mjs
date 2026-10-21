import test from 'node:test';
import assert from 'node:assert/strict';
import { createRelationship, friendshipLevel } from '../Wallpaper/companion/relationship.js';

test('friendship levels', () => {
  assert.equal(friendshipLevel(0), 0);
  assert.equal(friendshipLevel(24.9), 0);
  assert.equal(friendshipLevel(25), 1);
  assert.equal(friendshipLevel(60), 2);
  assert.equal(friendshipLevel(90), 3);
});

test('touching her chest upsets her whatever the friendship, and twice is worse', () => {
  for (const friendship of [10, 40, 95]) {
    const relationship = createRelationship({ friendship });
    const first = relationship.noteBoundary();
    assert.equal(relationship.offended, true);
    assert.notEqual(first.style, 'again');
    assert.equal(first.style, friendship >= 50 ? 'hurt' : 'angry');
    assert.ok(relationship.friendship < friendship);
    assert.equal(relationship.noteBoundary().style, 'again');
    assert.equal(relationship.strikesToday, 2);
  }
});

test('while upset she brushes off affection until the app says she has forgiven you', () => {
  const relationship = createRelationship({ friendship: 80 });
  relationship.noteBoundary();
  assert.equal(relationship.snubs('headPat'), true);
  assert.equal(relationship.phraseKey('handHold'), 'snub');
  const before = relationship.friendship;
  relationship.noteTouch('headPat');
  assert.equal(relationship.friendship, before, 'no friendship gained while she is upset');
  assert.deepEqual(relationship.set({ friendship: before, offended: true }), { forgiven: false });
  assert.deepEqual(relationship.set({ friendship: before + 2, offended: false }), { forgiven: true });
  assert.equal(relationship.snubs('headPat'), false);
  assert.equal(relationship.phraseKey('handHold'), 'handHold');
});

test('phrases follow how close you are', () => {
  const stranger = createRelationship({ friendship: 10 });
  assert.equal(stranger.phraseKey('handHold'), 'handHoldDistant');
  assert.equal(stranger.phraseKey('headStroke', { teased: true }), 'headStrokeDistant');
  const friend = createRelationship({ friendship: 35 });
  assert.equal(friend.phraseKey('headStroke', { teased: true }), 'headStroke');
  const close = createRelationship({ friendship: 70 });
  assert.equal(close.phraseKey('headStroke', { teased: true }), 'teased');
});

test('bad payloads are ignored', () => {
  const relationship = createRelationship();
  relationship.set(null);
  relationship.set({ friendship: 'lots', offended: 'yes' });
  assert.equal(relationship.offended, false);
  assert.equal(relationship.friendship, 30);
  relationship.set({ friendship: 500 });
  assert.equal(relationship.friendship, 100);
});
